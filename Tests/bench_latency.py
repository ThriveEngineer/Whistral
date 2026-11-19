#!/usr/bin/env python3
"""One-off latency benchmark for the whistral_engine sidecar.

Drives the engine exactly like Tests/test_engine_e2e.py does (framed
stdin/stdout protocol, float32 16 kHz mono audio) and characterizes
end-to-end streaming latency over N streaming sessions:

  per session (token=i, real-time-paced 4 s of speech-like audio):
    - ttf_partial  : first audio offered -> first 'partial' event
    - ttf_segment  : first audio offered -> first 'segment' event
                     (only fires when the model emits an end-of-segment
                     token mid-stream; often n/a for synthetic audio)
    - e2e          : first audio offered -> 'final' event (wall clock)
    - finalize     : 'stop' sent -> 'final' event
  process metrics:
    - boot         : spawn -> first 'ready' event (imports, MLX init)
    - load cold    : first load cmd in a fresh process -> modelState(ready)
                     (weights not in the process; HF snapshot + file cache)
    - load cached  : same in a second process, after process 1 fully loaded
                     the model once (OS page cache warm)

Note on module reuse: this would normally `import test_engine_e2e` for the
framing helpers, but that script runs its whole baseline test at import time
(spawns its own engine at module scope, no if-__name__ guard), so the tiny
protocol helpers are duplicated here on purpose. test_engine_e2e.py is left
untouched.

Writes Tests/perf-report.md. Read-only with respect to engine/app code.
"""
import json
import math
import os
import statistics
import struct
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
VENVPY = os.path.expanduser("~/Library/Application Support/Whistral/venv/bin/python")
ENGINE = os.path.join(os.path.dirname(HERE), "Whistral", "Resources", "Engine", "whistral_engine.py")
REPORT = os.path.join(HERE, "perf-report.md")

N_SESSIONS = 10
SESSION_SECONDS = 4
CHUNK = 1024            # samples per offered chunk (64 ms @ 16 kHz)
BATCH = 2               # chunks offered per pacing tick
SR = 16000
FINAL_TIMEOUT = 90.0    # per-session watchdog for the 'final' event


class EngineProc:
    """One sidecar process with a timestamped event reader."""

    def __init__(self):
        self.events = []          # [(t_monotonic, event_dict)]
        self.t0 = time.monotonic()
        self.proc = subprocess.Popen(
            [VENVPY, ENGINE],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            bufsize=0,
        )
        self.reader_done = threading.Event()
        t = threading.Thread(target=self._reader, daemon=True)
        t.start()

    def _reader(self):
        for line in self.proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except Exception:
                ev = {"type": "unparsed", "raw": line[:200]}
            self.events.append((time.monotonic(), ev))
        self.reader_done.set()

    # ---- protocol (mirrors SidecarEngineClient.writeFrame / send_*) ----

    def send_frame(self, ftype, payload):
        # frame length includes the 1-byte type
        self.proc.stdin.write(struct.pack("<I", len(payload) + 1) + bytes([ftype]) + payload)
        self.proc.stdin.flush()

    def send_cmd(self, obj):
        self.send_frame(0x01, json.dumps(obj).encode())

    # ---- event helpers ----

    def wait_event(self, pred, timeout):
        """Returns (arrival_time, event) of the first event matching pred,
        or (None, None) on timeout."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for t, ev in self.events:
                if pred(ev):
                    return t, ev
            time.sleep(0.01)
        return None, None

    def quit(self):
        try:
            self.send_cmd({"cmd": "quit"})
            self.proc.wait(timeout=10)
        except Exception:
            self.proc.kill()


def speech_like_chunk(t_start_idx, n=CHUNK):
    """Deterministic pseudo-speech: syllable-rate amplitude envelope on a
    small harmonic stack with a gentle floor (voiced-pause cadence)."""
    out = []
    for j in range(n):
        ts = (t_start_idx + j) / SR
        env = 0.5 + 0.5 * math.sin(2 * math.pi * 3.3 * ts)          # ~3.3 Hz syllables
        env = env ** 1.5
        basis = (math.sin(2 * math.pi * 220 * ts) * 0.45
                 + math.sin(2 * math.pi * 440 * ts) * 0.30
                 + math.sin(2 * math.pi * 880 * ts) * 0.15)
        out.append(0.55 * env * basis + 0.02 * math.sin(2 * math.pi * 97 * ts))
    return out


def boot_and_load(label_load):
    """Spawns the engine; returns (ep, boot_time, load_time, boot_events_ok)."""
    ep = EngineProc()
    t_ready, _ = ep.wait_event(lambda e: e.get("type") == "ready", 120)
    boot = (t_ready - ep.t0) if t_ready else None
    ep.send_cmd({"cmd": "load"})
    t_send = time.monotonic()
    t_state, ev = ep.wait_event(
        lambda e: e.get("type") == "modelState" and e.get("state") in ("ready", "error"),
        300)
    if ev is None or ev.get("state") == "error":
        print("FATAL: %s failed: %s" % (label_load, ev), flush=True)
        return ep, boot, None, False
    return ep, boot, time.monotonic() - t_send, True


def run_session(ep, token, out_rows, anomalies):
    """One real-time-paced streaming session; appends a metrics row."""
    t_start = time.monotonic()
    partial_t = segment_t = None
    ep.send_cmd({"cmd": "start", "delayMs": 480, "token": token})

    t_first_audio = None
    chunk_idx = 0
    paced = 0
    while chunk_idx < SESSION_SECONDS * SR // CHUNK:
        # offer-audio-style pacing: BATCH chunks per real-time tick of
        # BATCH*CHUNK/SR seconds, tracking an absolute schedule
        for _ in range(BATCH):
            if chunk_idx >= SESSION_SECONDS * SR // CHUNK:
                break
            samples = speech_like_chunk(chunk_idx)
            ep.send_frame(0x02, struct.pack("<%df" % len(samples), *samples))
            if t_first_audio is None:
                t_first_audio = time.monotonic()
            chunk_idx += 1
        paced += BATCH
        next_due = t_start + paced * CHUNK / SR
        time.sleep(max(0.0, next_due - time.monotonic()))

    t_stop_sent = time.monotonic()
    ep.send_cmd({"cmd": "stop"})

    # stream events as they arrive up to the final.
    # Partial tracking: first partial after this session's first offer; the
    # scheduled offer times make cross-session bleed-through impossible
    # (sessions are serialized — we awaited the previous final).
    t_final = None
    deadline = time.monotonic() + FINAL_TIMEOUT
    while time.monotonic() < deadline:
        for t, ev in ep.events:
            ts = ev.get("type")
            if ts == "partial" and partial_t is None and t_first_audio is not None and t >= t_first_audio:
                partial_t = t
            if ts == "segment" and ev.get("token") == token and segment_t is None:
                segment_t = t
            if ts == "final" and ev.get("token") == token:
                t_final = t
        if t_final:
            break
        time.sleep(0.05)

    if t_final is None:
        anomalies.append("session token=%d: no final within %.0fs" % (token, FINAL_TIMEOUT))
        dump = [json.dumps(e)[:120] for _, e in ep.events[-30:]]
        anomalies.append("  last events: %s" % " | ".join(dump))
        ep.send_cmd({"cmd": "cancel"})  # recover; keep going
        time.sleep(2.0)
        return

    out_rows.append({
        "token": token,
        "e2e": t_final - (t_first_audio or t_start),
        "finalize": t_final - t_stop_sent,
        "ttf_partial": (partial_t - t_first_audio) if (partial_t and t_first_audio) else None,
        "ttf_segment": (segment_t - t_first_audio) if (segment_t and t_first_audio) else None,
        "had_segment": segment_t is not None,
    })


def fmt_stat(vals, fmt="{:.3f}"):
    vals = [v for v in vals if v is not None]
    if not vals:
        return "—"
    return " / ".join(fmt.format(v) for v in
                      (min(vals), statistics.median(vals), max(vals)))


def main():
    anomalies = []
    t_all0 = time.monotonic()

    # ---- process 1: boot, cold load, 10 sessions -------------------------
    ep1, boot1, load_cold, ok1 = boot_and_load("cold load")
    if not ok1:
        ep1.quit()
        return 1
    print("boot: %.2fs  cold load: %.2fs" % (boot1, load_cold), flush=True)

    rows = []
    for i in range(1, N_SESSIONS + 1):
        run_session(ep1, i, rows, anomalies)
        r = rows[-1] if rows else {}
        print("session %2d: e2e=%.2fs finalize=%.2fs ttf_partial=%s ttf_segment=%s"
              % (i, r.get("e2e", -1), r.get("finalize", -1),
                 ("%.2fs" % r["ttf_partial"]) if r.get("ttf_partial") is not None else "—",
                 ("%.2fs" % r["ttf_segment"]) if r.get("ttf_segment") is not None else
                 ("(no segment)" if not r.get("had_segment", False) else "?")),
              flush=True)

    # ---- process 2: cached-load comparison --------------------------------
    # A same-process repeat load early-returns WITHOUT emitting any event, so
    # its latency is unobservable; measure a fresh process instead (the HF
    # snapshot and OS page cache are warm after process 1's full load).
    # Quit process 1 FIRST so it releases the ~4 GB model from unified memory
    # and can't skew the warm-run numbers via memory pressure.
    ep1.quit()

    # Two fresh warm processes: page cache + HF snapshot are hot. Report
    # min/p50/max of those instead of a single n=1 sample.
    boot_warm = []
    load_cached = []
    for _ in range(2):
        ep2, boot2, load2, ok2 = boot_and_load("cached load")
        ep2.quit()
        if not ok2:
            return 1
        boot_warm.append(boot2)
        load_cached.append(load2)
        print("warm boot: %.2fs  warm load: %.2fs" % (boot2, load2), flush=True)

    # ---- report ------------------------------------------------------------
    e2e = [r["e2e"] for r in rows]
    fin = [r["finalize"] for r in rows]
    ttfp = [r["ttf_partial"] for r in rows]
    ttfs = [r["ttf_segment"] for r in rows]
    seg_rate = sum(1 for r in rows if r["had_segment"])

    completed = len(rows)
    lines = [
        "# Whistral — End-to-End Streaming Latency (benchmark)",
        "",
        "Machine: Apple M5, 16 GB, macOS 27.2. Model: Voxtral Mini 4B Realtime — 6-bit",
        "(mlx-community/Voxtral-Mini-4B-Realtime-6bit). Engine: single MLX worker thread.",
        "",
        "Method: %d streaming sessions; each offers %d s of real-time-paced synthetic"
        % (N_SESSIONS, SESSION_SECONDS),
        "speech-like audio (16 kHz mono Float32 in %d-sample (%.0f ms) chunks, %d per"
        % (CHUNK, 1000.0 * CHUNK / SR, BATCH),
        "pacing tick), then stops and waits for `final`. Timestamps are wall-clock at",
        "protocol-event arrival. Re-runnable via `python3 Tests/bench_latency.py`.",
        "",
        "All latencies in seconds, reported min / p50 / max.",
        "",
        "| Metric (min / p50 / max, s) | Value |",
        "|---|---|",
        "| Model load, cold (fresh process, first load; n=1) | %.2f |" % load_cold,
        "| Model load, cached (fresh process, page cache warm; n=2) | %s |" % fmt_stat(load_cached, "{:.2f}"),
        "| Engine boot (spawn → `ready`, cold; n=1) | %.2f |" % boot1,
        "| Engine boot (spawn → `ready`, warm; n=2) | %s |" % fmt_stat(boot_warm, "{:.2f}"),
        "| First audio → first `partial` | %s |" % fmt_stat(ttfp),
        "| First audio → first `segment` | %s |" % (
            fmt_stat(ttfs) if seg_rate else "n/a (no mid-stream eos with synthetic audio)"),
        "| First audio → `final` (end-to-end, 4 s utterance) | %s |" % fmt_stat(e2e),
        "| stop → `final` (finalize) | %s |" % fmt_stat(fin),
        "",
        "Sessions completed: %d/%d." % (completed, N_SESSIONS),
    ]
    if seg_rate:
        lines.append("`segment` events occurred in %d/%d sessions." % (seg_rate, N_SESSIONS))
    else:
        lines.append(
            "No `segment` events occurred: synthetic tone-like audio never produced a "
            "mid-utterance end-of-segment token, so first-`segment` is marked n/a; "
            "first-`partial` is the streaming-responsiveness proxy.")
    if anomalies:
        lines += ["", "Anomalies observed (not fixed — engine code untouched):", ""]
        lines += ["- " + a for a in anomalies]
    lines += ["",
              "Notes:",
              "- *cold* load = first load in a fresh process (model not in process memory;",
              "  weights read from the HF snapshot on disk). The true first-ever download",
              "  (~3.9 GB) is not measured here.",
              "- A same-process repeat `load` early-returns in the engine without emitting",
              "  any event, so that path's latency is unobservable from the protocol.",
              "- Synthetic audio yields empty transcript text by design; latency is the",
              "  measurement target, not transcription quality."]
    with open(REPORT, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    print("\nwrote %s\n----\n%s" % (REPORT, "\n".join(lines)), flush=True)
    print("\ntotal wall time: %.1fs" % (time.monotonic() - t_all0), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())

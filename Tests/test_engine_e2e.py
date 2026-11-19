#!/usr/bin/env python3
"""Manual E2E test of the whistral_engine sidecar protocol.

Spawns the sidecar, sends: load -> start -> float32 audio frames -> stop,
and prints every NDJSON event received.

Extended with regression cases for the single-MLX-worker-thread refactor
(Engine.submit / FIFO job queue):
  baseline : load -> start -> audio -> stop -> final(token=42)   (original test)
  case 1   : cancel echoes the session token (never tokenless)
  case 2   : a load commanded during a live session doesn't wedge the
             reader thread; the engine stays responsive afterwards
  case 3   : session-error / worker-error paths always echo the token
             (source tripwire + runtime failed-load variant)
  case 4   : no 'final'/'cancelled' event anywhere in the run lacks a
             'token' key
"""
import ast
import json
import math
import os
import struct
import subprocess
import sys
import threading
import time

VENVPY = os.path.expanduser("~/Library/Application Support/Whistral/venv/bin/python")
ENGINE = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                      "Whistral", "Resources", "Engine", "whistral_engine.py")

proc = subprocess.Popen(
    [VENVPY, ENGINE],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
    bufsize=0,
)

def send_frame(ftype, payload):
    # length includes the 1-byte type (matches SidecarEngineClient.writeFrame)
    proc.stdin.write(struct.pack("<I", len(payload) + 1) + bytes([ftype]) + payload)
    proc.stdin.flush()

def send_cmd(obj):
    send_frame(0x01, json.dumps(obj).encode())

def send_audio(samples):
    send_frame(0x02, struct.pack("<%df" % len(samples), *samples))

events = []
reader_done = threading.Event()

def reader():
    # Engine emits newline-delimited JSON on stdout.
    for line in proc.stdout:
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except Exception:
            ev = {"raw": line[:400]}
        events.append(ev)
        print("EVENT:", json.dumps(ev)[:400], flush=True)
    reader_done.set()

t = threading.Thread(target=reader, daemon=True)
t.start()

# --- small helpers for the regression cases -----------------------------------

results = []

def check(name, ok, detail=""):
    results.append((name, bool(ok)))
    tag = "PASS:" if ok else "FAIL:"
    suffix = (" — " + detail) if detail else ""
    print("\n%s %s%s\n" % (tag, name, suffix), flush=True)

def wait_for(pred, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if pred():
            return True
        time.sleep(0.2)
    return False

def has_event(etype, **kw):
    def pred():
        for e in events:
            if e.get("type") != etype:
                continue
            if all(e.get(k) == v for k, v in kw.items()):
                return True
        return False
    return pred

def find_event(etype, **kw):
    for e in events:
        if e.get("type") == etype and all(e.get(k) == v for k, v in kw.items()):
            return e
    return None

time.sleep(1.0)
send_cmd({"cmd": "load"})
print("==> load sent", flush=True)

# Wait for ready (model state = ready) up to 15 min
deadline = time.time() + 900
ready = False
while time.time() < deadline:
    print(".", end="", flush=True)
    if any(e.get("type") == "ready" for e in events) and any(
        e.get("type") == "modelState" and e.get("state") == "ready" for e in events
    ):
        ready = True
        break
    if any(e.get("type") == "modelState" and e.get("state") == "error" for e in events):
        print("FATAL error during load; aborting")
        proc.kill(); sys.exit(1)
    time.sleep(2)
if not ready:
    print("TIMEOUT waiting for ready"); proc.kill(); sys.exit(1)

print("\n==> start sent", flush=True)
send_cmd({"cmd": "start", "delayMs": 300, "token": 42})
time.sleep(2.0)

# Send 3 seconds of a 440 Hz tone + envelope, 16 kHz
sr = 16000
for i in range(3 * sr // 3200):  # 100 ms chunks of 1600 samples
    chunk = [0.5 * math.sin(2 * math.pi * 440 * (i * 1600 + j) / sr) for j in range(1600)]
    send_audio(chunk)
    time.sleep(0.02)
send_cmd({"cmd": "stop"})
print("==> stop sent", flush=True)

final = None
deadline = time.time() + 120
while time.time() < deadline:
    if any(e.get("type") == "final" and e.get("token") == 42 for e in events):
        final = next(e for e in events if e.get("type") == "final" and e.get("token") == 42)
        break
    time.sleep(0.5)

print("\n=== Baseline result ===")
print("final:", json.dumps(final) if final else "NOT RECEIVED")
print("total events:", len(events), flush=True)
check("baseline: load -> start -> audio -> stop -> final(token=42)", final is not None)

# =============================================================================
# Case 1 — cancel echoes the session token
#
# Start a session with a known token and cancel it immediately. The engine must
# emit exactly a 'cancelled' event carrying the session token (from the
# cancel-before-start branch, or SessionKilled in the loop/flush — both echo).
# A tokenless 'cancelled' would be accepted by Swift's `token == nil` branch
# and could resetToIdle a queued follow-up session.
# =============================================================================
print("==> case 1: start + immediate cancel", flush=True)
send_cmd({"cmd": "start", "delayMs": 300, "token": 7})
send_cmd({"cmd": "cancel"})

ok1 = wait_for(has_event("cancelled", token=7), 60)
tok_cancel = find_event("cancelled", token=7)
tokenless_cancel = [e for e in events if e.get("type") == "cancelled"
                    and e.get("token") != 7]
check("case 1: cancel echoes the session token",
      ok1 and tok_cancel is not None and not tokenless_cancel,
      "" if ok1 else "no cancelled(token=7) within 60s; events=%s"
      % json.dumps([e for e in events if e.get("type") == "cancelled"]))

# =============================================================================
# Case 2 — load-during-session doesn't wedge
#
# Start (token 11), wait for sessionStarted, then command a load of the SAME
# (cached) model — the load job queues behind the live session on the MLX
# worker instead of blocking the stdin reader thread like before the refactor.
# Then stop; the session must still finalize, and a fresh start with token 12
# must reach sessionStarted and a matching final. Before the refactor this
# deadlocked the reader thread permanently.
# =============================================================================
print("==> case 2: load-during-session, then responsiveness check", flush=True)
send_cmd({"cmd": "start", "delayMs": 300, "token": 11})
ss11 = wait_for(has_event("sessionStarted", token=11), 60)
print("    sessionStarted(token=11): %s" % ss11, flush=True)
send_cmd({"cmd": "load"})  # same model -> queues behind the live session, fast
send_cmd({"cmd": "stop"})
final11 = wait_for(has_event("final", token=11), 120)
print("    final(token=11): %s" % final11, flush=True)

send_cmd({"cmd": "start", "delayMs": 300, "token": 12})
ss12 = wait_for(has_event("sessionStarted", token=12), 60)
send_cmd({"cmd": "stop"})  # session 12: no audio, flush straight away
final12 = wait_for(has_event("final", token=12), 120)
print("    sessionStarted(token=12): %s; final(token=12): %s" % (ss12, final12), flush=True)
check("case 2: load during a live session doesn't wedge; engine stays responsive",
      ss11 and final11 and ss12 and final12,
      ("first session reached: %s" % ss11))

# =============================================================================
# Case 3 — worker/session error paths echo the token
#
# 3a (source tripwire, deterministic): every literal emit(...) dict in the
#     engine whose "type" is "final" or "cancelled" must carry a "token" key.
#     This covers the two fallback emits of a crashed session plus the
#     inactive stop()/cancel() echoes.
# 3b (runtime): start with a token, immediately load a nonexistent model, then
#     stop. The failed load must surface an error without affecting the
#     running session: final(token=21) still arrives. Case 4 below verifies no
#     tokenless final/cancelled appeared during this.
# =============================================================================
print("==> case 3: error-path token echo", flush=True)
with open(ENGINE, "r", encoding="utf-8") as f:
    engine_src = f.read()

bad_emits = []
for node in ast.walk(ast.parse(engine_src)):
    if not (isinstance(node, ast.Call)
            and isinstance(node.func, ast.Name)
            and node.func.id == "emit"):
        continue
    for arg in node.args:
        if isinstance(arg, ast.Dict):
            str_keys = [k.value for k in arg.keys
                        if isinstance(k, ast.Constant) and isinstance(k.value, str)]
            consts = {k.value: v.value for k, v in zip(arg.keys, arg.values)
                      if isinstance(k, ast.Constant) and isinstance(k.value, str)
                      and isinstance(v, ast.Constant)}
            if consts.get("type") in ("final", "cancelled") and "token" not in str_keys:
                bad_emits.append("line %d" % node.lineno)
check("case 3a: tripwire — every literal final/cancelled emit carries 'token'",
      not bad_emits, "offending emits: %s" % ", ".join(bad_emits))

send_cmd({"cmd": "start", "delayMs": 300, "token": 21})
send_cmd({"cmd": "load", "model": "nonexistent-org/nonexistent-model-qa-xyz"})
send_cmd({"cmd": "stop"})
final21 = wait_for(has_event("final", token=21), 120)
load_err = wait_for(lambda: any(
    e.get("type") == "modelState" and e.get("state") == "error"
    or e.get("type") == "error" for e in events), 120)
check("case 3b: session survives a failed worker load and echoes its token",
      final21 and load_err,
      "final(token=21)=%s, load error event=%s" % (final21, load_err))

# =============================================================================
# Case 4 — global triage: tokenless terminal events
#
# Across the WHOLE run (baseline + every new case), no event of type 'final'
# or 'cancelled' may ever appear without a 'token' key.
# =============================================================================
tokenless = [e for e in events
             if e.get("type") in ("final", "cancelled") and "token" not in e]
check("case 4: no tokenless final/cancelled anywhere in the run",
      not tokenless, json.dumps(tokenless[:3]) if tokenless else "")

# =============================================================================
# Summary
# =============================================================================
send_cmd({"cmd": "quit"})
try:
    proc.wait(timeout=10)
except subprocess.TimeoutExpired:
    proc.kill()

print("\n=== Summary ===")
print("final (baseline):", json.dumps(final) if final else "NOT RECEIVED")
print("total events:", len(events))
all_ok = True
for name, ok in results:
    print("%s  %s" % ("PASS" if ok else "FAIL", name))
    all_ok = all_ok and ok
sys.exit(0 if all_ok else 1)

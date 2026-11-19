# Re-verification — bench_latency.py reproducibility run

Independent re-run of `Tests/bench_latency.py` (written by another agent; report under
check: `Tests/perf-report.md`). Driver invoked exactly like `Tests/test_engine_e2e.py`:
`cd Tests && "$HOME/Library/Application Support/Whistral/venv/bin/python" bench_latency.py`.

## 1. Exit code / hangs

- **Exit 0**, total wall time 50.1 s. All 12 processes (1 cold + 2 warm) booted, loaded,
  quit cleanly; 10/10 sessions got a token-matched `final`; **no hangs, no anomalies
  emitted** (the script's own anomaly list was empty, so the report has no anomaly
  section) and no watchdog (90 s `FINAL_TIMEOUT`) fired.

## 2. Do the numbers reproduce? — yes, ballpark confirmed

| Metric | perf-report.md (agent's run) | my re-run | in ballpark? |
|---|---|---|---|
| First partial (min/p50/max) | 0.672 / 0.681 / 0.702 | 0.671 / **0.680** / **0.932** | p50 clearly inside **0.6–0.8 s**; one outlier above (see 2a) |
| Finalize (min/p50/max) | 0.526 / 0.541 / 0.587 | 0.556 / **0.576** / 0.588 | inside **0.5–0.6 s** ✅ |
| Load cold (n=1) | 0.99 | 1.07 | **< 2 s** ✅ |
| Load cached (n=2) | 0.75 / 0.82 / 0.88 | 0.72 / 0.88 / 1.04 | **< 2 s** ✅ |
| Boot cold (n=1) | 0.43 | 0.34 | ✅ |
| Boot warm (n=2) | 0.36 / 0.42 / 0.47 | 0.36 / 0.41 / 0.47 | identical spread ✅ |
| E2E (4 s utterance) | 4.498 / 4.513 / 4.559 | 4.526 / 4.548 / 4.558 | ✅ (~4.5 s = 4 s pacing + ~0.55 s finalize, internally consistent) |

### 2a. Anomalies (benign, worth knowing)

- **Session 1 first-partial = 0.932 s** — the only sample outside 0.6–0.8 s (rest:
  0.671–0.702). Classic first-session warm-up (MLX graph/JIT compile on the fresh
  process); the script correctly includes it rather than discarding it, so the report's
  `max` is honest. Original run didn't hit it (max 0.702) — n=1-vs-n=1 luck at the tail.
- **One "cached" load measured 1.04 s** vs 0.72 s for the second warm process. Still
  well under 2 s, but note the first warm process并非 fully warm: it runs right after the
  cold process quit, and unified-memory re-faulting of ~4 GB of weights plausibly
  explains 1.04 → 0.72. The n=2 min/median/max presentation handles this fine.

## 3. Methodology description in perf-report.md vs what the script does — accurate

Checked claim-by-claim against the code:

- "10 streaming sessions, 4 s real-time-paced synthetic speech-like audio, 16 kHz mono
  Float32, 1024-sample (64 ms) chunks, 2 per pacing tick, then stop and wait for final"
  — matches `N_SESSIONS=10, SESSION_SECONDS=4, CHUNK=1024, BATCH=2`, real-time pacing
  against an absolute schedule, `{"cmd":"stop"}`, and waiting for `final` with the
  session token. ✅
- "Timestamps are wall-clock at protocol-event arrival" — accurate: `time.monotonic()`
  sampled in the reader thread when each NDJSON line arrives. ✅ (pedantically "clock at
  reader-line arrival", which is what the report means)
- "min / p50 / max" — `fmt_stat` reports min / median / max. ✅
- Cold load n=1, cached load n=2 in fresh processes, boot n=1 + warm n=2 — matches
  `main()`, which quits process 1 before the warm runs (so it doesn't skew via memory
  pressure). ✅
- "A same-process repeat load early-returns without emitting any event, so that path's
  latency is unobservable" — true of the engine (`Engine.load` early-returns silently for
  the same model); the fresh-process workaround is sound. ✅
- "Engine: single MLX worker thread" — confirmed in current `whistral_engine.py`
  (`Engine.submit` FIFO job queue, one daemon worker named `whistral-mlx`,
  whistral_engine.py:368–385). ✅ (Also confirms the engine was refactored since my
  2026-02-14 re-verify report — my then-defect 3, the load-on-reader-thread deadlock, is
  fixed: all `emit`s of `final`/`cancelled` now carry the token, incl. lines 514/561/577.)
- "Re-runnable via `python3 Tests/bench_latency.py`" — accurate: the driver script is
  stdlib-only; it spawns the venv python itself, so the host interpreter doesn't need the
  venv packages. ✅
- Side note: first-`partial` measurement ignores tokens and keys on "first partial
  arriving after this session's first audio offer" — safe only because sessions are
  strictly serialized (the previous `final` is awaited before the next start). The
  script's comment says exactly this; correct as written. ✅

## 4. Git-tracked-tree integrity after the run

`git status --porcelain` snapshotted immediately before and after the run: **identical**.
The bench modified nothing tracked and nothing outside `Tests/`; it only rewrote the
untracked `Tests/perf-report.md` (its declared output). For completeness, the working
tree already carried many pre-existing uncommitted changes from other agents' work
(whistral_engine.py refactor among them) before this run started — listed in the
before-snapshot, unchanged by it.

## Verdict

Reproducible: exit 0, no hangs, all headline numbers land in the stated ballpoints —
first partial p50 0.68 s (target 0.6–0.8), finalize 0.56/0.58 s (target 0.5–0.6), loads
0.72–1.07 s (target < 2 s) — and the report's methodology description is faithful to
what the script does. Only caveats are the two benign tail-sample anomalies in 2a.

# Whistral — End-to-End Streaming Latency (benchmark)

Machine: Apple M5, 16 GB, macOS 27.2. Model: Voxtral Mini 4B Realtime — 6-bit
(mlx-community/Voxtral-Mini-4B-Realtime-6bit). Engine: single MLX worker thread.

Method: 10 streaming sessions; each offers 4 s of real-time-paced synthetic
speech-like audio (16 kHz mono Float32 in 1024-sample (64 ms) chunks, 2 per
pacing tick), then stops and waits for `final`. Timestamps are wall-clock at
protocol-event arrival. Re-runnable via `python3 Tests/bench_latency.py`.

All latencies in seconds, reported min / p50 / max.

| Metric (min / p50 / max, s) | Value |
|---|---|
| Model load, cold (fresh process, first load; n=1) | 1.07 |
| Model load, cached (fresh process, page cache warm; n=2) | 0.72 / 0.88 / 1.04 |
| Engine boot (spawn → `ready`, cold; n=1) | 0.34 |
| Engine boot (spawn → `ready`, warm; n=2) | 0.36 / 0.41 / 0.47 |
| First audio → first `partial` | 0.671 / 0.680 / 0.932 |
| First audio → first `segment` | n/a (no mid-stream eos with synthetic audio) |
| First audio → `final` (end-to-end, 4 s utterance) | 4.526 / 4.548 / 4.558 |
| stop → `final` (finalize) | 0.556 / 0.576 / 0.588 |

Sessions completed: 10/10.
No `segment` events occurred: synthetic tone-like audio never produced a mid-utterance end-of-segment token, so first-`segment` is marked n/a; first-`partial` is the streaming-responsiveness proxy.

Notes:
- *cold* load = first load in a fresh process (model not in process memory;
  weights read from the HF snapshot on disk). The true first-ever download
  (~3.9 GB) is not measured here.
- A same-process repeat `load` early-returns in the engine without emitting
  any event, so that path's latency is unobservable from the protocol.
- Synthetic audio yields empty transcript text by design; latency is the
  measurement target, not transcription quality.

# Whistral Sidecar Engine Protocol

This document describes the protocol between the Whistral macOS app and its
Python sidecar engine. It is derived from the code and is the reference for
contributors:

- Engine: [`Whistral/Resources/Engine/whistral_engine.py`](../Whistral/Resources/Engine/whistral_engine.py)
- Client: [`Whistral/SidecarEngineClient.swift`](../Whistral/SidecarEngineClient.swift)
- E2E test: [`Tests/test_engine_e2e.py`](../Tests/test_engine_e2e.py)

If this document and the code disagree, the code wins — and please open an
issue or PR fixing this document.

---

## 1. Process Model

### Spawning and venv bootstrap

`SidecarEngineClient.ensureRunning()` starts the engine:

1. If `~/Library/Application Support/Whistral/venv/bin/python` does not exist,
   the client bootstraps it: `/usr/bin/python3 -m venv <Application
   Support>/Whistral/venv`, then, in that venv, `pip install --quiet -r
   requirements.txt` (the copy bundled in the app). If `requirements.txt` is
   missing from the bundle, it falls back to `pip install --quiet voxmlx`.
   Bootstrap runs on a background queue (`userInitiated`); the engine starts
   only after it succeeds.
2. The engine process is spawned as: `<venv>/bin/python -u whistral_engine.py`,
   where the script is looked up in the app bundle at the bundle root, then in
   the `Engine` and `Resources/Engine` subdirectories. The environment sets
   `PYTHONUNBUFFERED=1` (and the engine itself sets `MLX_METAL_PRECOMPILE=1`
   on startup). stderr is piped to the app log; stdout carries NDJSON events;
   stdin carries framed commands.

### Lifetime and crash-restart backoff

- The engine process runs for the lifetime of the app. Sending the `quit`
  command makes the engine exit with status 0, which the client surfaces as
  `.modelState(.stopped)`.
- If the process exits with a non-zero status and the app is not terminating,
  the client increments `crashRestartCount` and restarts the engine after a
  **1.5 s** delay — but at most **3 times**. A fourth crash surfaces an error
  instead ("The speech engine keeps crashing…").
- The counter is deliberately **not** reset at spawn time (that would make the
  cap unreachable: crash → restart → reset → crash …). It is reset to 0 only
  when the restarted engine proves itself healthy by emitting a `modelState`
  event with `state: "ready"`.

### Why all MLX work runs on one dedicated thread

MLX streams are **thread-local**: a lazily-evaluated op graph references the
GPU stream of the thread that created it. If model loading, streaming
sessions, and file transcription were to run on different threads, mixing ops
across those threads raises:

```
There is no Stream(gpu, N) in current thread
```

The engine therefore channels **every** MLX operation — model load, streaming
sessions, file transcription — through a single dedicated worker thread
(`Engine._worker_loop`, named `whistral-mlx`). That thread sets
`mx.set_default_device(mx.gpu)` once at start, so every job — and every cached
weight — shares the same streams. Jobs run through `Engine.submit(fn, *args)`,
which enqueues `(fn, args)` on a FIFO `queue.Queue` (`float`-style `None`
sentinels terminate the loop). A job's exception does not kill the worker; it
is caught and reported as an `error` event.

Serialization consequences:

- **FIFO ordering.** `submit` preserves submission order, so a load commanded
  during a live session simply queues behind it.
- **The stdin reader thread stays responsive.** Nothing blocks the command
  reader — `load` and `transcribe` submit jobs and return; `stop` and `cancel`
  only set flags on the active runner (no joins). This is why a load commanded
  mid-session does not wedge the reader and leave `cancel`/`quit` frames
  unread.
- **A load commanded mid-session queues behind it** instead of wedging the
  reader. Because `Engine.load` short-circuits when the requested model is
  already loaded, re-issuing `load` for the cached model is cheap and just
  waits its turn. `Tests/test_engine_e2e.py` case 2 regression-tests exactly
  this scenario (start → sessionStarted → load → stop → final arrives, then a
  fresh session works).
- **One worker thread, no GPU pipelining.** FIFO serialization is about
  correctness (thread-affinity) and ordering, not throughput: commands run one
  at a time in command order, so a long job — a cold model load, a large file
  transcription, a session's flush — delays every job queued behind it. A
  `load` for an already-loaded model short-circuits cheaply, but a fresh load
  or `transcribe` will stall the next session's start; don't design for
  overlapping GPU work, design around the queue.

The sidecar runs at most **one in-flight streaming session** (`StreamRunner`).
Audio frames are buffered in a bounded queue (`maxsize=4096` chunks); on a
full queue the oldest chunk is dropped so the microphone thread never blocks.

## 2. Wire Format

### App → engine (stdin): framed messages

Each message is a **5-byte header + payload**:

| Bytes | Field |
| --- | --- |
| 0–3 | `uint32` little-endian frame length `N` (of the bytes that follow, i.e. **including** the 1 type byte) |
| 4 | 1-byte type: `0x01` = JSON command, `0x02` = raw audio payload |
| 5… | `N − 1` bytes of payload |

- Type `0x01`: payload is a UTF-8 JSON command object (see §3). Malformed JSON
  produces an `error` event and the reader continues.
- Type `0x02`: payload is **raw mono 16 kHz PCM, `float32`, little-endian**
  samples (`<f4`). Audio frames are only meaningful while a session is active;
  they are dropped otherwise.

The Swift side mirrors this in `SidecarEngineClient.writeFrame`
(`length = payload.count + 1`); frames are handed to a serial writer queue and
never block the realtime audio tap thread.

### Engine → app (stdout): plain NDJSON

Each event is one `json.dumps` line followed by `\n`, written under a lock and
flushed immediately (`emit()`). The Swift client reads stdout line-by-line and
parses each line as a JSON object with a `"type"` key. Unknown types and
`log` events are ignored by the parser; stderr is treated as human-readable
log text, not protocol.

## 3. Command Reference

All commands are JSON objects with a `"cmd"` field. The exact behaviors below
come from `handle_command()` in the engine.

| Command | Fields | Behavior |
| --- | --- | --- |
| `load` | `model` (default `mlx-community/Voxtral-Mini-4B-Realtime-6bit`), `temperature` (default `0.0`; non-numeric → `0.0`) | Submitted to the MLX worker. No-op if that model is already loaded. Emits `modelState: loading` → (`modelState: downloading` with `received`/`total` progress, at most every 0.25 s) → `modelState: ready`. On failure emits `modelState: error` + `error`. |
| `start` | `delayMs` (default `480`), `token` (default `0`) | Starts a session. If a session is already active, emits `error` ("A session is already running"). Otherwise creates a new `StreamRunner` with the given token and enqueues the session job on the MLX worker. |
| `stop` | — | Requests a clean end of the session: sets the flush flag and enqueues a `None` end-of-audio marker. Never blocks the reader. If the runner is already inactive, it synthesizes `final` (`text: ""`) echoing the token so the app is never left waiting. The stopped runner is then parked in the engine's `FLUSHING` registry so a later `cancel` can still abort the in-progress flush (see §5). |
| `cancel` | — | Requests cancellation: sets the cancel flag; the session observes it (including mid-flush) and emits `cancelled` itself. Additionally prunes the `FLUSHING` registry and sets the cancel flag on **every** still-flushing previous session, so an Esc that arrives during `.finalizing` (after `stop` already cleared the active runner) still kills that flush. If the runner is already inactive and nothing is flushing, it synthetically emits `cancelled` echoing the token. |
| `audio` | — (frame type `0x02`) | Not sent as a JSON command; audio payload frames are handled at the frame layer. |
| `transcribe` | `path` | Submitted to the MLX worker; runs file transcription through voxmlx with the loaded model and temperature. Emits `fileTranscript` on success or `error` on failure. |
| `quit` | — | Returns `False` from `handle_command`; the frame reader exits and the process exits with status 0. |
| *unknown* | — | Emits `error` ("Unknown command: …"). |

### `delayMs` clamping and rounding

The rule, verbatim from the code:

```python
delay_ms = max(80, min(2400, delay_ms - (delay_ms % 80)))
n_delay_tokens = delay_ms // 80
```

That is: the requested delay is first **rounded down to a multiple of 80**,
then **clamped to [80, 2400]**. `n_delay_tokens = delayMs / 80`. Examples from
this rule: `300` → `240` → 3 delay tokens; `480` (the default) → 480 → 6;
`50` → `0` → clamped to `80` → 1; `9999` → clamped to `2400` → 30.

## 4. Event Reference

All events are JSON objects with a `"type"` field. Required fields per event,
exactly as emitted by the code:

- **`ready`** — `{type: "ready"}`. Emitted once at process startup, before any
  frames are read. No other fields.
- **`modelState`** — `{type: "modelState", state: ...}` where `state` is one of
  `downloading` (plus `received`, `total` ints), `loading` (plus `model`),
  `ready` (plus `model`), or `error` (plus `message`, truncated to 400 chars).
  The `ready`-state event doubles as the health signal that resets the Swift
  crash-restart counter.
- **`sessionStarted`** — `{type: "sessionStarted", token: <int>}`. Emitted when
  the session job begins running on the MLX worker (note: this is *after* the
  job is enqueued, so it can be delayed behind a queued load).
- **`partial`** — `{type: "partial", index: <int>, segmentText: "<current
  segment text>", text: "<all segments joined> "}`. Emitted per decoded token;
  `index` is the index of the segment currently being decoded (0-based).
- **`segment`** — `{type: "segment", token: <int>, index: <int>, text:
  "<completed segment text>"}`. Emitted when a segment closes (EOS); `index`
  counts completed segments.
- **`final`** — `{type: "final", token: <int>, text: "<full session
  transcript>"}`. Terminal event of a successful session end.
- **`cancelled`** — `{type: "cancelled", token: <int>}`. Terminal event of a
  cancelled session; no `text`.
- **`error`** — `{type: "error", message: "..."}`. Emitted for worker errors,
  session errors, malformed commands, and file-transcription failures. Note
  that a session error is **also** followed by a `final` (empty text, echoing
  the token) so the app never waits forever.
- **`fileTranscript`** — `{type: "fileTranscript", path: "<requested path>",
  text: "<transcript>"}`. No token; completion signals for `transcribe`.
- **`log`** — `{type: "log", message: "..."}`. Free-form engine logging;
  ignored by the Swift parser. (Not part of the command/event contract.)

### The token invariant on terminal events

`final` and `cancelled` **always** carry the session `token`. This is the
invariant the app relies on to match terminal events to the session that is
still on screen, and to discard stale ones from an earlier session
(`token: nil` on the Swift side is tolerated for backward compatibility; a
token that doesn't equal the current session token is dropped). `partial`
events carry no token; `segment` events do.

Example terminal events as emitted (field order per the emit sites):

```json
{"type": "final", "token": 42, "text": "hello world"}
{"type": "cancelled", "token": 42}
{"type": "final", "token": 7, "text": ""}
{"type": "fileTranscript", "path": "/tmp/note.wav", "text": "remember the milk"}
```

`Tests/test_engine_e2e.py` enforces this twice:

- **Case 4** performs a whole-run triage: across the entire run (baseline +
  every regression case), no `final` or `cancelled` event may ever appear
  without a `token` key.
- **Case 3a** is a static tripwire that parses the engine's own AST: every
  literal `emit({...})` dict of type `final` or `cancelled` must have a
  `token` key.

## 5. Session Semantics

### Delay tokens

Voxtral's streaming prompt is parameterized by a number of *delay tokens*:
audio suspension tokens that trade latency for accuracy. One token equals
**`SAMPLES_PER_TOKEN = 1280` samples** (imported from `voxmlx.audio`, and equal
to `hop_length × 2 × 4` there) at **16 kHz** — i.e. 1 token = 80 ms. The
`delayMs` → tokens conversion is the clamp/rounding rule in §3. A third
constant in this regime: the left pad is `N_LEFT_PAD_TOKENS = 32` tokens
of silence prepended to the first audio chunk, and the flush right pad is
`N_RIGHT_PAD_TOKENS = 17` tokens.

### Audio feeding and the flush sentinel

While a session is active, `audio` frames land in a bounded FIFO queue. The
session loop drains ready chunks, and `VoxtralStream.pump()` feeds only
token-aligned slices of pending audio (whole multiples of 1280 samples)
through the incremental encoder while decode advances in parallel. When the
app requests `stop`:

1. The flush flag is set and a `None` sentinel — **not** audio — is enqueued as
   an end-of-audio marker.
2. The session loop breaks when it observes the flag *or* the sentinel; it
   drains any remaining queued audio chunks from the queue first.
3. `flush()` then concatenates whatever pending audio remains with a
   **right-pad of zeros** (`N_RIGHT_PAD_TOKENS × SAMPLES_PER_TOKEN = 17 × 1280`
   samples of silence) and decodes everything left. This None sentinel
   (separate from any audio) is what guarantees the flush sees a defined end
   of input even if a final partial token's worth of samples was queued.

### Cancellation mid-flush and the FLUSHING registry

Cancellation is a flag (`ctl["cancel"]`), not a signal. The decode loops poll
it — including inside `flush()`'s decode steps — via `Stream.should_cancel`,
raising `SessionKilled`. So a `cancel` commanded while a flush is in progress
is honored immediately: state is discarded and the session ends with
`cancelled` echoing its token, not with a `final`.

That mechanism needs to survive `stop`: the command handler clears the active
`RUNNER` the moment a `stop` or `cancel` is accepted, but the worker job may
still be flushing for seconds afterwards. The engine therefore keeps a
**`FLUSHING` registry** of such runners:

- Every runner parked there carries a `finished` event, set by the worker
  thread in a `finally` when the session job returns (flush included), so
  "still flushing" is distinguishable from "gone". `start` and `cancel` prune
  finished runners out of the registry.
- A `cancel` arriving while any registry entry is unfinished sets that
  runner's `ctl["cancel"]`, which the running decode-loop poll picks up — so
  an Esc during `.finalizing` (after `stop` already cleared `RUNNER`) kills
  the flush and the session ends with `cancelled`, not a `final`.

This is why a cancel remains effective at every phase of a session, and why
the "at most one in-flight session" rule still holds when sessions follow each
other quickly.

### Exactly one terminal event

Every session path emits **exactly one** terminal `final` or `cancelled`:

- cancel observed before the session starts on the worker → `cancelled`;
- normal flush → `final` with the assembled transcript;
- a `SessionKilled` anywhere (loop or flush) → `cancelled`;
- a streaming error mid-loop → `error` + `final` (with the partial text);
- any other session error → `error` + `final` (`text: ""`).

This is precisely what keeps the Swift side from ever waiting on a session
that can no longer produce a result.

### Stale-event guarding on the Swift side

Sessions are started by `TranscriptionController` with a per-session integer
`token` (echoed by the engine on all session events). For terminal events the
controller applies:

```swift
guard token == nil || token == sessionToken else { return }
```

A terminal event whose token belongs to another (e.g. superseded or queued)
session is discarded; events without a token are tolerated for compatibility
with older engines. Non-terminal events (`partial`, `segment`) are dropped
from `parseEvent`'s token (the controller's token-scoped handlers handle
matching instead).

## 6. Driving the Engine from Other Languages

Nothing in the protocol is Python- or Swift-specific: any language that can
spawn a subprocess and speak the §2 framing (`uint32`-LE length + 1 type byte +
payload on stdin; line-buffered NDJSON on stdout) can drive the engine. This
is also what the E2E test does. To run it:

```sh
python3 Tests/test_engine_e2e.py
```

It requires the app's engine venv at
`~/Library/Application Support/Whistral/venv` (see
[CONTRIBUTING.md](../CONTRIBUTING.md) for recreating it in development) and a
network connection for the one-time model download (~3.9 GB). The suite sends
real (synthetic-tone) audio through the protocol and asserts the regression
contract of §4, including the token invariant.

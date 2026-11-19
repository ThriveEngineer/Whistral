# Whistral — Code Review Findings

Reviewed: all Swift sources under `Whistral/` plus `Whistral/Resources/Engine/whistral_engine.py`.
Scope:HUD/panel lifecycle, hotkey semantics, sidecar process lifecycle & protocol, audio
tap/converter, clipboard insertion, session state machine, engine threading.

Severity: **blocker** (app does not function / hangs) · **major** (broken flow in realistic
use) · **minor** (degraded behavior, racy edge) · **nit** (cosmetic/dead code).

---

## Blockers

### 1. `stdinHandle` is always `nil` — nothing is ever sent to the engine
**SidecarEngineClient.swift:178, 205 — blocker**

```swift
proc.standardInput = Pipe()          // line 178
...
stdinHandle = proc.standardInput as? FileHandle   // line 205
```

`Process.standardInput` returns the object that was assigned — an `NSPipe`. The
conditional downcast `as? FileHandle` therefore **always fails** and `stdinHandle` is
`nil`. `writeFrame` (line 265) silently returns, so every command (`load`, `start`,
`stop`, `cancel`, `quit`) and every audio chunk is silently dropped. `sendAudio`,
`writeCommand`, and `quit()` should all be no-ops at runtime — the app can never
transcribe, and every session ends permanently stuck in `.finalizing` after
`stopSession` (nothing ever replies). This is also why the failure is invisible:
everything is guarded with silent `return`s.

**Fix:** `stdinHandle = (proc.standardInput as? Pipe)?.fileHandleForWriting`. Also log or
emit an error when `writeFrame` drops a frame due to `stdinHandle == nil` so this class of
bug cannot hide again.

### 2. The model is never loaded after app relaunch
**SidecarEngineClient.swift:164–212, AppModel.swift:138–147, whistral_engine.py:390–403 — blocker**

The engine only loads a model when it receives a `load` command. The only senders of
`load` are (a) `AppModel.wireEngineClient`'s `settings.$modelID` sink, which uses
`.dropFirst()` so the persisted value is never sent on launch (AppModel.swift:138), and
(b) `OnboardingView.advance()`/`finish()`, which run exactly once ever (OnboardingView.swift:205,
369). `startEngine()` (SidecarEngineClient.swift:164) sends nothing, and `whistral_engine.main()`
does not auto-load either. Additionally, `AppModel` ignores the engine's `{"type":"ready"}`
event (AppModel.swift:207), so `engineState` remains `.stopped` (or `.error` after a crash)
forever.

Consequence: on every relaunch the sidecar is alive with `model == None`, the menu says
"Engine not running", and `startSession` hits the `.notInstalled, .stopped` branch which
only calls `ensureRunning()` (a no-op, see finding 5) — dictation silently does nothing
until the user happens to change the model in Settings.

**Fix:** in `startEngine()` (or on receipt of the engine's `ready` event) send
`load(modelID: settings.modelID, temperature:)`. Treat the Python `ready` event as
"process alive" and only flip to `.ready` on `modelState: ready`.

---

## Major

### 3. Engine error/crash during a pending start leaves the HUD and phase stuck at `.starting` forever
**TranscriptionController.swift:109–113, 209–211, 240–243**

When `startSession` queues `pendingStart = true; phase = .starting` and shows the HUD with
"Preparing the speech engine…", the only exit is `maybeStartPendingSession()`, which fires
on **any** `.modelState` event with `pendingStart && engineState == .ready`. If the model
load fails (`modelState: error`), the process crashes (`terminationHandler` →
`modelState(.error("exited unexpectedly…"))`), or the user presses Esc (cancel does
call `resetToIdle`, but see below), nothing clears the queue — actually `resetToIdle`
does clear `pendingStart`, but a load **error** emits `.modelState` which reaches
`case .modelState: maybeStartPendingSession()` (line 209), does nothing (state not
`.ready`), and there is no timeout anywhere. The HUD stays on screen showing
"Preparing the speech engine…" indefinitely and `phase` is pinned at `.starting`
(further hotkey presses in hold mode do `stopSession` → `resetToIdle`, recovering only by
accident).

**Fix:** in `maybeStartPendingSession`, handle non-`.ready` terminal states
(`.error`) explicitly: reset to idle and surface the error; add a generous timeout
(e.g. 30 s) on `pendingStart` as a backstop.

### 4. `startSession` `.notInstalled/.stopped` branch: invisible session — no HUD, no `pendingStart`
**TranscriptionController.swift:122–124**

```swift
case .notInstalled, .stopped:
    AppModel.shared.ensureEngineRunning()
    phase = .starting
```

Unlike the `.loading/...` branch, this shows **no HUD** and does **not** set
`pendingStart`. So when the engine was stopped/crashed: `phase = .starting` with no UI at
all; when the engine later becomes `.ready`, the `modelState(.ready)` event reaches
`maybeStartPendingSession()`, which returns immediately because `pendingStart` is
`false` — the session is never started. The user's hotkey press is swallowed, the phase
sits in `.starting` until they release the key, and bootstrap (a full pip install on first
run) happens with zero indication.

**Fix:** mirror the `.loading` branch: `pendingStart = true; hud.showListening();
hud.update(text:"Preparing the speech engine…")`.

### 5. Engine `.error` path exits to idle without stopping audio capture
**TranscriptionController.swift:212–218, 166–169; AudioCaptureEngine.swift:60–65**

`handleEngineEvent(.error)` schedules `resetToIdle()` after 3 s, and `resetToIdle()` only
sets `phase`/`pendingStart`/hides the HUD — it never calls `audio.stop()`. Any error that
arrives while `phase == .recording` (engine streaming failure, `whistral_engine.py:421–426`
or 438) therefore leaves the AVAudioEngine tap installed and the mic indicator lit
indefinitely, with every captured buffer dropped by the `case .recording` guard in
`onAudio` (TranscriptionController.swift:57). Same after `cancel()`'s companion flows that
go through `resetToIdle` directly in `.starting` bail-outs.

**Fix:** make `resetToIdle()` (or the error/timeout path) call `audio.stop()` — it is
idempotent (`guard isCapturing`).

### 6. Cancel during `.finalizing` is ineffective; `flush()` is uninterruptible and blocks the command thread up to 60 s
**whistral_engine.py:293–328 (flush), 478–489 (stop), 491–500 (cancel); TranscriptionController.swift:152–155, 159–163**

- `VoxtralStream.flush()` (line 293) never checks `self._killed` — the whole final decode
  runs to completion regardless of cancellation, and `decode_steps`/`pump` never poll
  `_killed` either, so the `_killed` event (set by `cancel()`/`close()`, lines 333/336)
  is dead weight.
- `Engine` serializes commands on the stdin reader thread: for `stop`, `handle_command`
  calls `RUNNER.stop()` which **blocks in `thread.join(timeout=60)`** (line 488).
  A `cancel` or `quit` frame sent while the flush is in progress sits unread in the pipe
  until the flush finishes (or 60 s elapse). Esc pressed during finalizing is therefore
  a no-op, and quitting the app hangs on the same pipe.

**Fix:** check `ctl["cancel"]` (or `_killed`) inside `decode_steps`'s per-token loop and
in `flush()`; run `thread.join` for stop/cancel on a helper thread (or join with a short
timeout and abandon the thread) so the stdin reader stays responsive.

### 7. Python `stop()`/`cancel()` join timeouts leave a zombie session — next session shares the model object concurrently
**whistral_engine.py:478–500, 455–462**

If `thread.join(timeout)` expires (stop: 60 s; cancel: 15 s), the old session thread keeps
running while `handle_command` discards the runner and a later `start` builds a new one.
Two `_stream_session` threads then drive the **same** `Engine.model` with interleaved MLX
ops and `RotatingKVCache` churn — undefined GPU behavior, likely corrupted output or a
hard crash. Nothing errors out to Swift either, so it just looks like garbage transcripts.

**Fix:** on join timeout, mark the thread as abandoned and refuse `start` (emit an error
event) until it exits; or make sessions strictly serialized under `ENGINE.lock` — note the
lock exists but `_stream_session` never takes it.

### 8. Python error paths emit `error` but never `final` — Swift can idle in `.finalizing`
**whistral_engine.py:421–426, 435–439; TranscriptionController.swift:152–155, 212–218**

`_stream_session`'s exception handlers (mid-loop `pump` failure at 421–426 and the outer
catch at 435–439) return after emitting `{"type":"error"}` only. When this happens during
a flush — i.e. Swift already called `stop()` and set `phase = .finalizing` — Swift's only
recovery is the 3 s timer in the `.error` case (TranscriptionController.swift:212–218),
which works *only if* the error event is delivered. If the process dies instead
(stdin/stdout closed, no event), Swift has no finalize timeout at all: `phase` stays
`.finalizing` and the HUD stays up forever.

**Fix:** emit `final` (possibly with empty text) after every error path that ends a
session, and add a finalize watchdog on the Swift side (e.g. 30–60 s after `stopSession`
forces `resetToIdle`).

### 9. Microphone-permission callback starts an orphan session after the key was released
**TranscriptionController.swift:94–98, 172–186**

`startSession` sets `phase = .starting` before the async permission prompt. If the user
releases the hotkey while the system dialog is up, `hotkeyUp → stopSession → resetToIdle`
runs; when the grant callback later fires it does `self.phase = .idle; self.startSession()`
unconditionally — a fresh session starts although no key is held (hold mode), leaving a
"recording" session that can only be stopped with Esc or another hotkey press. The
`.notDetermined` case is by far the most common for the very first dictation.

**Fix:** track the pending start with `pendingStart` instead of `phase`, and in the
callback make the grant path go through the normal `startSession` only if the user's press
is still current (e.g. `guard pendingStart else { phase = .idle; return }`).

### 10. No engine restart on crash and no retry path from `.error`
**SidecarEngineClient.swift:207–218; TranscriptionController.swift:117–120; AppDelegate.swift:102**

The audit brief asked for restart-on-crash: there is none. `terminationHandler` flips
`engineState` to `.stopped` (clean exit) or `.error("exited unexpectedly…")` and that's
it. `startSession`'s `.error` branch only displays the message for 2.5 s — it never calls
`ensureEngineRunning()`, which would never succeed while the delegate believes `.error`
anyway since `engineState` is never reset to `.stopped` by `ensureRunning`. Only a
`.stopped` state would restart, and that only happens if the process exits with status 0.
Net effect: one engine crash permanently bricks dictation until app relaunch. The menu
aggravates this: `dictation.isEnabled = isEngineReady || !isIdle` (AppDelegate.swift:102)
disables "Start Dictation" whenever engineState is `.error`.

**Fix:** on unexpected termination, set state to `.stopped` (optionally after a short
cooldown/backoff) and have `startSession` call `ensureEngineRunning()` for
`.notInstalled/.stopped`, per finding 4. Reset `isEngineAlive` before the delegate event
so `ensureRunning` can actually relaunch.

### 11. Blocking pipe write on the realtime audio thread (deadlock surface)
**AudioCaptureEngine.swift:71 → TranscriptionController.swift:57 → SidecarEngineClient.swift:265–273**

`onAudio` runs on the AVAudioEngine tap (realtime) thread and calls `sendAudio →
writeFrame → FileHandle.write` under `NSLock`. If the Python side momentarily stops
reading stdin — which happens for the entire duration of `handle_command("stop")`
(finding 6) or during a model `load`, including the snapshot download — the stdin pipe
(64 KB ≈ 0.5 s of 16 kHz float32) fills and `handle.write` **blocks indefinitely on the
system's realtime audio thread**, stalling the audio render and spiking the audio server.
Also, `stdinHandle` is read unsynchronized while `terminate()` nils it on the main thread.

**Fix:** route frames through a serial `DispatchQueue` (you already have `stdoutQueue`;
mirror it with a writer queue) or write on a worker thread and drop frames when backlogged;
never write from the tap thread.

---

## Minor

### 12. HUD hide/show race: a fast new session gets orderOut'd mid-flight
**HUDController.swift:49–59, 90–110**

`hide()` fades the panel out and its completion handler calls `panel.orderOut(nil)` —
guarded by nothing. If a new session starts within the 0.15 s window (hotkey stop + press,
or toggle double-tap), `presentPanel()` sees `panel.isVisible == true`, skips the fade-in
and the pending completion handler then hides the **new** session's HUD. The user is left
dictating with no HUD.

**Fix:** guard `hide()`'s completion with a generation counter or check
`phase == .hidden` before `orderOut`, and reset `alphaValue` in `showListening()`.

### 13. HUD repositions to the current mouse location on every partial text
**HUDController.swift:90–110, 117–133**

`update(text:)` calls `presentPanel()` on each partial, which recomputes
`anchorPoint` from `NSEvent.mouseLocation` and calls both `setContentSize` and
`setFrameOrigin` unconditionally — even when the size is unchanged. While dictating the
user typically has their hand on the pointer (scrolling, selecting, moving), so the HUD
visibly chases the mouse and is re-framed dozens of times per session. The width clamp
(240…460) is also moot since `HUDView` pins width to exactly 380
(HUDView.swift: `.frame(width: 380…)`), so only the height ever changes.

**Fix:** anchor once per session (or only when the panel becomes visible), and skip
`setContentSize`/`setFrameOrigin` when the computed frame is unchanged. Clamp height only:
`fittingSize.height`.

### 14. No watchdog for a lost hotkey-up in hold mode
**HotkeyController.swift:111–143; TranscriptionController.swift:75–89**

Semantics are otherwise right: `keyboardEventAutorepeat` filters key-repeat double-fires
(line 135), and keyUp always stops. But when the tap is disabled by timeout
(`.tapDisabledByTimeout`, line 115) the re-enable happens on the *next* delivered event —
the in-flight `keyUp` that triggered the timeout was already passed through, so
`hotkeyUp()` never fires: the session records forever until Esc. A focus switch to a Secure
Input field (or the tap being disabled by user input) hits the same hole. This is exactly
the "stuck 'recording' state if key-up is missed" scenario, and there is no safety net.

**Fix:** add a per-session max-duration watchdog in `TranscriptionController` (e.g.
force `stopSession` after 2–5 minutes) — robust regardless of why key-up was lost.

### 15. Pasteboard save/restore race — no `changeCount` guard, non-string data lost
**TextInserter.swift:62–95**

`paste()` snapshots only string-typed values of `pasteboardItems` (lines 66–77), so any
richer previous contents (images, file URLs, promised types) are destroyed and replaced
with a string-less restore; and the restore at +0.35 s runs **unconditionally**, so if the
user (or a clipboard manager) wrote to the pasteboard inside that window, their copy is
clobbered by our stale snapshot. Also, only one 0.35 s attempt is made: for slow target
apps the restore can land before the target app reads the pasteboard, making the paste
yield *old* content.

**Fix:** record `pasteboard.changeCount` before clearing; on restore, skip if the
changeCount changed since our write. Snapshot via `NSPasteboardItem`s/data for non-string
types (or at least refuse to restore anything when non-string types were present). Give
the delay a little more slack (0.5 s) or verify the insertion.

### 16. Silent failure paths of paste: no target activation and no fallback on failure
**TextInserter.swift:98–107; TranscriptionController.swift:227–236**

`sendCommandV` posts Cmd+V at `.cghidEventTap` with no verification. If the frontmost app
changed focus between capture start and insertion (very plausible for a long `finalizing`
flush), or the frontmost app has no focused text view, the keystroke lands nowhere or in
the wrong field and the text is silently lost — `insertFinalText` immediately
`resetToIdle()`s with no retry, no fallback to `keystrokes`, and the text only survives in
the (immediately restored-over) clipboard / Recent Transcripts menu. There is also no
`NSWorkspace.frontmostApplication` re-check or short delay after activation.

**Fix:** before pasting, verify the frontmost bundle ID is still present in a session-time
snapshot; on timeout/verification failure, fall back to `type(_:)` or surface the failure
in the HUD instead of vanishing. Keep a copy in the clipboard as a last resort instead of
restoring at all when the paste could not be verified.

### 17. `insertFinalText` ignores `sessionToken` — stale engine events can clobber a live session
**TranscriptionController.swift:34, 104, 193–204, 207, 227–236**

`sessionToken` is bumped on every start (line 104) and captured at `.final` (line 203), but
then discarded (`_ = token`, line 237). Because engine events are matched only by `phase`,
a late `final` from a previous aborted/slow session inserts the *old* transcript while a
new session is live (its `currentText`/`partialText` are also not token-guarded, line
195), and a late `cancelled` event calls `resetToIdle()` (line 207) which kills the fresh
session while its audio capture is still running — HUD hidden, phase idle, mic hot. This
is reachable given finding 6/7's multi-second joins.

**Fix:** carry `sessionToken` through `start`/`stop` commands and echo it back in engine
events (add a `"token"` field to the protocol), or at minimum compare the token captured at
event time with the current one and drop non-matching `final`/`cancelled`.

### 18. Audio: no handling of input-device/format change mid-session; failed start leaks the tap
**AudioCaptureEngine.swift:28–66, 71–116**

- The converter and tap are created once from `input.outputFormat(forBus: 0)`. If the
  default input device changes (or its hardware rate changes) mid-session, AVFoundation
  reconfigures the input node; the tap's format no longer matches and the captured buffers
  arrive in the *new* device's format, but `converter` was built for the *old* one —
  `AVAudioConverter.convert` on mismatched buffer formats produces garbage or errors.
  There is no observation of the configuration-change notification and no
  re-setup path.
- If `try engine.start()` throws, the tap stays installed (line 51 runs before line 56)
  and `isCapturing` stays `false`, so the guard in `stop()` (line 61) skips removal —
  the tap stays registered on a stopped engine for the lifetime of the `AVAudioEngine`
  instance, and a subsequent `start()` re-installs blindly.

**Fix:** observe the engine configuration-change notification during a session and
restart the tap + converter (or end the session gracefully with an error). In `start()`,
walk the tap back (`engine.inputNode.removeTap(onBus: 0)`) if `engine.start()` throws, or
install the tap only after a successful `engine.start()` — `AVAudioEngine` allows starting
first and tapping while running (or use `prepare()` before install and start after).

### 19. Bootstrap is not re-entrancy-safe, and its completion runs off-main
**SidecarEngineClient.swift:74–88, 96–156**

`ensureRunning()` guards on `isEngineAlive` only. Nothing prevents two concurrent
invocations of `bootstrap()` (there is no `isBootstrapping` flag): e.g. onboarding's
`advance()` (OnboardingView.swift:200) firing while another caller raced in via
`startSession` between `.notInstalled` state reads — both would `python -m venv` and pip
install into the same directory concurrently, corrupting the venv. Also, since the venv
directory pops into existence before pip finishes, a second `ensureRunning` during
bootstrap takes the `fileExists` branch and calls `startEngine()` immediately (line 88)
with an incomplete venv. Finally, `bootstrap`'s completion runs on
`DispatchQueue.global(qos: .userInitiated)` (line 102), so `startEngine()` and
`delegate?.engineClient(...)` execute **off the main thread** — `SidecarEngineClient`
state (`process`, `stdinHandle`, `isEngineAlive`) is mutated concurrently and
`AppModel` (a `@MainActor` class) has its delegate methods invoked from a background
queue; under Swift 6 that's a compile error, under Swift 5 it's silently racy.

**Fix:** add an `isBootstrapping` flag (idempotent bootstrap, completion coalescing),
treat "bootstrap in flight" as distinct from "venv missing" in `ensureRunning`, and hop
the completion to the main queue (`DispatchQueue.main.async`).

---

## Nits

### 20. `stdoutBuffer` is dead state
**SidecarEngineClient.swift:62** — declared, never used (the read loop keeps its own local
`buffer`). Remove it.

### 21. Transcribing "shimmer" dots don't animate
**HUDView.swift:66–73** — `transcribingDotOpacity` evaluates `Date()` once per render and
nothing animates the view, so the three dots are static (or flicker only when partial
text re-renders). Use `TimelineView(.periodic(...))` or an explicit `.animation` on
opacity driven by `phase`.

### 22. `handle_command`'s `runner` parameter is unused
**whistral_engine.py:503** — the function takes `runner` but relies on the module-global
`RUNNER` throughout (including reassigning it). Either use the parameter or drop it; as
written it invites confusion (a caller holding a stale reference vs. the global).

### 23. Level meter samples only channel 0
**AudioCaptureEngine.swift:83** — `for ch in 0..<min(1, channelCount)` computes RMS on
the first channel only despite the comment saying "mono average". Iterate all channels or
document the intentional choice.

### 24. Hotkey-up can leak through when modifiers are released first
**HotkeyController.swift:126–142** — if the user releases the modifier key before the main
key (or the keyUp event's flags differ), the keyUp fails the `flags == hotkey.modifiers`
match and passes through to the focused app while the corresponding keyDown was consumed.
Effect is cosmetically odd (a phantom keyUp) rather than functional; matching on keycode
plus "modifiers ⊇ active modifiers at keyDown" would be tighter.

---

## Verified as OK (traced, no issue)

- **Partial-line stdout parsing** (SidecarEngineClient.swift:220–241): buffer + newline
  split handles partial reads and multi-byte UTF-8 split across reads correctly; malformed
  lines are skipped, not fatal.
- **Key-repeat double-fire**: `keyboardEventAutorepeat` guard (HotkeyController.swift:135)
  prevents repeated `hotkeyDown` in hold mode; in toggle mode repeated downs are also
  filtered (and `.finalizing` presses are ignored).
- **Unmanaged return semantics**: `handle(event:type:)` correctly returns
  `Unmanaged.passUnretained(event)` for pass-through, `nil` to consume, and re-enables on
  `.tapDisabledByTimeout/.tapDisabledByUserInput`.
- **Event-tap lifetime**: `passRetained`/`release` pairing in `enable/disable` is balanced
  including the tapCreate-failure path (HotkeyController.swift:73–105).
- **Esc monitors** (AppModel.swift:156–177): correct phase predicates; local monitor
  consumes only when cancelling.
- **16 kHz mono conversion math** (AudioCaptureEngine.swift:94–116): output capacity
  `frames * ratio + 64` suffices; `AVAudioConverter`'s internal remainder buffering is
  leveraged correctly with the standard `haveData`/`noDataNow` input block; per-chunk
  allocation is acceptable at tap rate.
- **Python `emit` thread-safety** (whistral_engine.py:73–77): single `_tty_lock` ensures
  whole-line writes + flush, matching Swift's newline-delimited parser.
- **Python subset of `download` events → Swift `downloadingModel`**: field names/types
  agree; `as? Int` casts are safe for JSON integer values.
- **Stale audio after cancel**: each session gets a fresh `StreamRunner`/queue
  (whistral_engine.py:524–527), so queued-but-undrained audio of a cancelled session is
  discarded with it; the end-of-audio `None` marker is correctly skipped in the flush
  drain (line 434).
- **Menu rebuild** (`menuNeedsUpdate`) and phase-icon mirroring are consistent with the
  `.recording` phase.

---

## Top-5 by impact

1. **#1 `stdinHandle` cast always fails** — nothing ever reaches the engine; app dead on arrival.
2. **#2 Model never loaded after relaunch** — engine runs with no model; `.ready` never reached.
3. **#6/#8 Finalizing hangs** — uninterruptible 60 s flush + no Swift finalize timeout; HUD can stick forever and Esc is dead during finalizing.
4. **#10 No crash-restart and unreachable retry path** — one engine crash bricks dictation until relaunch.
5. **#5/#14 Mic left hot / stuck recording** — error paths never stop capture; lost key-up has no watchdog.

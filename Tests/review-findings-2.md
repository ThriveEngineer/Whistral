# Whistral — Final Review Round (uncommitted changes, diff vs HEAD)

Scope:the changed files per the review brief (worker-thread engine refactor,
SidecarEngineClient restart/pipe rework, HUD generation fix, TextInserter fail-closed,
TranscriptionController guards/watchdogs, AudioCaptureEngine `__installTap`, status-item
recovery, onboarding copy). Focus questions answered explicitly in the "Verified" section
at the end. Line numbers refer to the working tree, not HEAD.

Build check: `xcodebuild -project Whistral.xcodeproj -scheme Whistral build` **succeeds
with zero Swift warnings** (the `error: ()` call form of `__installTap` typechecks).

---

## Findings

### 1. Queue-waiting frame writes can hit a dead pipe → uncatchable ObjC exception / SIGPIPE kills the app
**SidecarEngineClient.swift:226–231, 310–331, 374–381 — major**

`writeFrame` now snapshots `stdinHandle`/`isEngineAlive` on the caller thread and hands the
bytes to `writeQueue`, which later does `self.stdinHandle?.write(frame)` (line 331). The
engine death sequence is: process dies → (up to a small delay) `terminationHandler` runs on
an **arbitrary queue** and nils `stdinHandle` (line 229, off-main). Frames already queued on
`writeQueue` (audio buffers flow in many times per second) still execute with a non-nil
handle against a pipe whose reader is gone. `FileHandle.write` then either dies of SIGPIPE
or raises `NSFileHandleOperationException` — an Objective-C exception that Swift `catch`
cannot intercept — taking the whole app down during a normal engine crash. The rework made
this more likely than the old synchronous main-thread write because (a) writes are now
deferred after the death check, and (b) crash-restart (new in this diff) means engine deaths
happen while sessions may still be streaming.

There is also a plain data race on `stdinHandle`: read on the audio tap thread (line 310),
read+nil-deref on `writeQueue` (331), niled in `terminationHandler` (229, foreign queue) and
in `terminate()` (379, main).

**Fix:** funnel all `stdinHandle` lifecycle through one owner (e.g. invalidate on `writeQueue`
itself: have `terminationHandler` do `writeQueue.async { self.stdinHandle = nil }`), and
replace `FileHandle.write` with a posix `write()` into `fileDescriptor` (with SIGPIPE ignored
via `signal(SIGPIPE, SIG_IGN)`) handling `EPIPE` by marking the engine dead instead of
raising.

### 2. The new mid-flush cancel poll is unreachable: Esc during `.finalizing` still cannot interrupt the engine
**whistral_engine.py:186–187, 451–452, 629–632; TranscriptionController.swift:250–259**

`VoxtralStream.should_cancel` (set at 451–452) allows `decode_steps` to raise
`SessionKilled` "including mid-flush" — but the `cancel` command only sets
`ctl["cancel"]` when `RUNNER is not None` (631), and by the time Swift is in
`.finalizing`, `stopSession` has already sent `stop`, which ran `RUNNER.stop()` and set
`RUNNER = None` (627). A later `Cancel` frame from `TranscriptionController.cancel()`
(valid for `.finalizing` at TranscriptionController.swift:250) is therefore dropped
silently. Practical consequences: (a) the flush monopolizes the single MLX worker to
completion, so a rapid stop→start session's `sessionStarted` and first partials are
deferred by the entire old flush (seconds for a long dictation; Swift shows "Start
speaking…" with no feedback while it records); (b) the contended flush can't be shortened.

**Fix:** keep the finished/cancelled runner's `ctl` alive until the worker retires the job —
e.g. make `cancel` walk a registry of running/queued `StreamRunner`s by token (the token is
already in the `start` command) instead of relying on the single `RUNNER` global.

### 3. Pending-start watchdog (30 s) fires during legitimate long model loads and then permanently drops the queued session
**TranscriptionController.swift:155–170; AppModel.swift:207–221**

With load now queue-deferred on the MLX worker, `startSession`'s `.loading/. downloadingModel`
path can legitimately wait far longer than 30 s: a first-run download of even the lightest
model is ~2.6 GB, and 6-bit/FP16 re-loads push well past 30 s on RAM-starved machines. The
watchdog (line 161) clears `pendingStart` unconditionally — nothing resets it on
`.downloadingModel` progress events (`maybeStartPendingSession` ignores them at line
408–425's `default:`). When the load finally completes, the queued session is never started;
the user must press the hotkey again with no signal that the engine became ready.

**Fix:** restart the 30 s timer on every received `.downloadingModel`/`.loading`
modelState (progress ⇒ alive), or exempt `pendingStart` sessions from the watchdog while a
download is in flight and show download progress on the HUD instead of the timeout message.

### 4. `TextInserter.insert` returns `true` unconditionally — the insertion-failure fallback is nearly dead code
**TextInserter.swift:22–47; TranscriptionController.swift:355–390**

`insert()` only ever returns `false` for empty text; `paste()` and `type()` report no
outcome (dropped synthetic Unicode events in Electron/sandboxed apps, paste into a field
that swallows Cmd+V, pasteboard manager interference — all still count as "success"). So in
`insertFinalText` the `insertionFailed` flag can only be set by the missing-Accessibility
branch (line 365); the new copy-only fallback + HUD message never runs for an actual
insertion failure, exactly the case it was added for.

**Fix:** have `paste()` verify the frontmost app changed focus or a keystroke was
delivered (hard) — minimally, return `false` when `paste()` couldn't post its events, and
document that keystroke delivery is best-effort; alternatively verify post-paste
(pasteboard read-back won't work, so a UI element query via AX would be needed).

### 5. Fail-closed frontmost check still inserts text into the *new* frontmost app
**TextInserter.swift:24–38**

When the frontmost bundle ID differs from the capture-time one (or can't be determined),
the method downgrades paste → synthetic keystrokes. Keystrokes land in whatever is focused
*right now* — the wrong-target mis-insertion the check exists to prevent still happens,
minus the clipboard clobber. Since a full copy-only fallback (HUD message + clipboard) is
already implemented in the controller, the focus-mismatch case is the natural one to route
there instead.

**Fix:** treat bundle-ID mismatch / unverifiable frontmost as an insertion failure (return
`false`) and let `insertFinalText`'s copy-to-clipboard path handle it; keep the
keystrokes downgrade only for users who explicitly chose "Simulate keystrokes".

### 6. Non-string-pasteboard guard runs after the destruction it's meant to prevent
**TextInserter.swift:100–135**

`hasNonStringTypes` is computed during the snapshot, then `pasteboard.clearContents()` +
string write (117–118) **already destroys** the previous items; the restore-time guard
(line 129) then skips restoring them. Net effect for a clipboard holding an image/file is:
previous content lost entirely (worse than before, when at least the string parts were
restored). The check needs to be made before the clobber.

**Fix:** move the decision up-front — if any snapshotted item carries non-string types,
either skip the transient clipboard write entirely (fall back to keystrokes or copy-mode)
or stash the non-string payloads via `item.data(forType:)` so the restore is faithful.

### 7. `keyUp` now consumed on keycode alone, swallowing unmatched releases
**HotkeyController.swift:130–142**

keyUp matching was loosened to keycode-only (correctly, for the released-modifier-first
case), but it now also consumes keyUps for keyDowns that were **passed through** because
their modifier chord didn't match (e.g. hotkey ⌥Space, user presses ⌘⌥Space: keyDown goes
to the app, flags-mismatched; keyUp is eaten here). Apps that track key state never see the
release.

**Fix:** remember the flags of the last consumed keyDown for this keycode and only consume
the keyUp if either a hotkey keyDown was consumed *or* the flags match the hotkey; else
pass it through.

### 8. `quit` with an in-flight job can delay process exit; no cancel on the way out
**whistral_engine.py:651–652, 693–695**

`handle_command("quit")` just returns `False`; the active/queued session job keeps running
on the daemon worker until `sys.exit(0)` tears the interpreter down. If the worker is
inside a long Metal/MLX C call while holding the GIL, interpreter finalization waits for it
— the app's quit path (`terminate()` → engine sees `quit` → exit deferral) can stall for the
remainder of a flush. There's also no final `cancelled` protocol event on this path.

**Fix:** on `quit`, set `ctl["cancel"]` on any live runner and give the worker a short
short-join (≤1 s) before returning `False` from `read_frames`.

### 9. `onInterrupted` assigned after the config observer is live
**AudioCaptureEngine.swift:73–85; TranscriptionController.swift:184–192**

`start()` registers the `.AVAudioEngineConfigurationChange` observer while `isCapturing` is
already `true` (line 73) and returns; the controller only assigns `audio.onInterrupted` a
few lines later (189). A hardware reconfiguration in that window (also mid app-launch, or
while the controller is between `try audio.start()` and the assignment) fires the observer,
calls `stop()`, then finds `onInterrupted == nil` — the session stays `.recording` with a
dead mic until the user releases the key (final comes back empty). Narrow, real.

**Fix:** assign `onInterrupted` (or a "pending interruption" latch) before installing the
tap, and consult the latch after assignment.

### 10. `lastTranscript` clobbered by empty abort finals
**TranscriptionController.swift:353; whistral_engine.py:492, 514**

`AppModel.shared.lastTranscript = text` runs before the `trimmed.isEmpty` check, so a
worker-error session that emits `final(token, "")` (514) overwrites the last good
transcript with `""` (and `recordTranscript` skips empty, so nothing is added). Same class
of value loss the transcript-recording rework (moved into the controller) was meant to fix.

**Fix:** move the `lastTranscript` assignment below `guard !trimmed.isEmpty` (or guard it
the same way).

### 11. Status-item recovery menu item is unreachable by mouse (acknowledged but worth another look)
**AppDelegate.swift:160–175 — minor/nit**

"Show Whistral in Menu Bar" lives inside the status-item menu, which can only be opened via
the (hidden) extra. As the code comment itself notes, recovery for a *persistently hidden*
extra is launch-time `item.isVisible = true` only; the in-menu item can help just the
overflow case via VoiceOver/keyboard. If persistent hiding matters, a second recovery surface
(sibling accessory item kept in reserve, or a `visibleOnAllSpaces` curtain window activated
by a global hotkey while hidden) would be needed. Not a regression — flagging the residual
gap only.

---

## Verified against the focus questions (no finding)

1. **FIFO worker queue vs. control flow (stop/cancel + late enqueue, RUNNER replacement).**
 Traced every ordering: stop→start while the old job still holds the worker (new job waits
 on the queue, tokens differ, old sessions' `final`/`cancelled` echoes carry the old token
 and are dropped by `TranscriptionController`'s token guards at 318–319/324); cancel of a
 queued-but-unstarted session (its job still checks `ctl["cancel"]` at 446 and emits
 `cancelled(token)` without starting); EOF teardown cancels the runner; `RUNNER.active`
 frames-offer guard stays on the reader thread only. No stale-job/kill-session hole except
 the `cancel`-during-`.finalizing` drop in finding 2.

2. **Load/session starvation.** Load and sessions are both `submit()`ed onto the same worker
 thread, so the `Engine.lock` in `load`/`_stream_session` is same-thread re-entrant — no
 deadlock; ordering is queue-based. A `load` commanded mid-session defers until the session
 ends (by design, comment at 600–606). The only starvation-shaped landmine is the UI side
 (finding 3): the engine behaves, the pending-start watchdog doesn't wait long enough.

3. **Double-final.** Enumerated: pump-error path emits exactly one `final` then returns
 (492–495); `stream.flush()` failure → outer catch emits one `final("")` (514); the
 `stop()` echo for `!active` runners (561) is unreachable via `handle_command` (cancel/stop
 immediately null `RUNNER`), and deferensive anyway with token echo; Swift's
 `.finalizing` + token guards drop any second final (`resetToIdle` after the first).
 No double-insertion path found.

4. **Queue-deferred load vs. Swift assumptions.** `AppModel`'s `.ready` → `.loading` +
 `load` relaunch fix is correct and re-entrant (it no-ops when already loading/ready); the
 load failure route reaches `maybeStartPendingSession`'s new `.error` arm and bails out
 visibly. Only the watchdog-vs-download issue (finding 3).

5. **HUD generation check.** Correct: `hide()` bumps `generation` (52–58); the
 during-fade `showListening()` re-entrance goes through `presentPanel(anchorFresh: true)`
 which bumps again (121), restarts the fade-in from alpha 0, and stale `orderOut`
 completions no-op. `showTranscribing`/`update` can't be invoked during a fade (their
 phase guards preclude it since every `hide()` path also exits the recording phases), so
 `anchorFresh: false` never lands in a live fade. The delayed hides in the controller are
 all token+phase-guarded (166–171, 220–224, 296–300, 384–388).

6. **`__installTap` throwing path + `isCapturing`/observer.** Verified: an installation
 throw propagates before `engine.start()`/`isCapturing = true`/observer registration —
 the controller's `beginCapture` catch cleans up; an `engine.start()` throw walks the tap
 back (66–70) before setting `isCapturing`; `stop()` removes the observer exactly once;
 `removeTap` on a never-tapped node is safe. The only seam is finding 9's
 `onInterrupted` assignment ordering. (`error: ()` typechecks against the 27.2 SDK —
 confirmed by a clean build; deprecation notes excluded per brief.)

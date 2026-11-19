# Whistral — Re-verification Report

Re-audit of the fixes from `Tests/review-findings.md` (24 findings). Verified against the
current working tree at `/Users/luis/Swift_Projects/Whistral` (fixes are uncommitted on top
of `a09dd26`; `git diff HEAD~1` shows `0ee63f7 → a09dd26` was housekeeping only — the fix
work is in the working tree, not yet committed).

Note: the concurrent agent's changes to `TranscriptionController` (insertion-failure HUD
messages, transcript recording moved to the token-accepted path) **landed mid-audit and
now appear complete**; they are reviewed as current code in findings 5–6, not as 'in
progress'.

Severity: **blocker** · **major** · **minor** · **nit**.

---

## 1. SidecarEngineClient.swift — fix verified except crash-restart counter

Verified:
- stdin obtained via the pipe: `stdinHandle = (proc.standardInput as? Pipe)?.fileHandleForWriting` (SidecarEngineClient.swift:217), with an explicit error event when nil (219–221). ✅ (old blocker #1 fixed)
- All frames go through the serial `writeQueue` (SidecarEngineClient.swift:66, 319–323); `sendAudio` → `writeFrame` only enqueues, so the realtime tap thread never calls `FileHandle.write`. Drop-when-dead is logged once instead of silently swallowed (273–281; old #1's "invisible failure" concern addressed). ✅ (old #11 fixed)
- Bootstrap re-entrancy: `isBootstrapping` flag guards `ensureRunning` (76) and `bootstrap` (100–101, 82–91 clears it on completion). ✅
- Bootstrap completion hops to the main queue before mutating state / calling the delegate (79–91). ✅ (old #19 fixed)

**Defect 1 — major: the crash-restart backoff cap is unreachable; a crashing engine restarts forever.**
`crashRestartCount = 0` runs inside `startEngine()` immediately after every successful
spawn (SidecarEngineClient.swift:213). The restart path increments the same counter
(241–247). Cycle: crash → count 1 → restart → *spawn succeeds* → count reset to 0 →
crash → count 1 → … The `<= 3` cap at line 242 can never bind, so an engine that dies at
startup (broken venv, missing dependency) is relaunched every ~1.5 s forever, re-emitting
`.modelState(.stopped)` each round. Suggested one-line fix: reset `crashRestartCount` only
after the engine proves healthy (e.g. on `.modelState(.ready)` / after 30 s of uptime),
not at spawn.

Nit: `writeFrame` reads `stdinHandle`/`isEngineAlive` unlocked on the tap thread
(262–275) while `terminate()` mutates them on main (371–374). The re-read inside
`writeQueue` under `writeLock` makes this benign in practice, but it is a formal data
race; snapshot both under `writeLock`.

## 2. AudioCaptureEngine.swift + TranscriptionController — VERIFIED

- Tap removed when `engine.start()` throws (AudioCaptureEngine.swift:61–65). ✅ (old #18b fixed)
- `.AVAudioEngineConfigurationChange` observed on the engine with `.main` queue (AudioCaptureEngine.swift:95–105): calls `stop()` (removes tap, stops engine, removes observer — 112–119) then `onInterrupted` → `handleAudioInterrupt()` (TranscriptionController.swift:221–227) which `stopSession()`s a `.recording` session → `.finalizing`, `audio.stop()`, `engine.stop()` → engine flushes accumulated audio. Nothing is lost; no garbage-converter path. ✅ (old #18a fixed)

Nit: `audio.onInterrupted` is assigned *after* `try audio.start()` succeeds
(TranscriptionController.swift:194–196), so a config change in the first ms calls a nil
closure; negligible.

## 3. TranscriptionController.swift — verified, one minor HUD-timer defect

Verified:
- `queuePendingStart()` used for **both** non-ready branches: `.loading/.bootstrapping/.downloadingModel` (137) and `.notInstalled/.stopped` (149, after `ensureEngineRunning()`); 30 s watchdog with token + `pendingStart` guard (161–174). (.error is terminal and self-bounds after 2.5 s — acceptable.) ✅ (old #3, #4 fixed)
- Finalize watchdog: 45 s in `stopSession`, token-guarded (237–244). ✅ (old #8 fixed)
- `resetToIdle` calls `audio.stop()` (263) — error paths can no longer leave the mic hot. ✅ (old #5 fixed)
- Mic-permission grant path re-checks the phase before restarting (279–282). ✅ (old #9 fixed)
- `.error` kill timer is token-guarded (326–331). ✅
- Bonus: 5-minute max-duration watchdog (210–218) covers old #14's lost-key-up hole. ✅

**Defect 2 — minor: unguarded delayed `hud.hide()` calls can bury a fresh session's HUD.**
- `queuePendingStart`'s 30 s-timeout message is followed by a bare hide 2.5 s later (TranscriptionController.swift:169–171), and the mic-denial path does the same (~286–288). Neither checks `sessionToken`/`phase`, so a session started inside that 2.5 s window has its HUD ordered out mid-dictation (same class as HUDController finding below). Suggested one-line fix: guard both with `sessionToken == token && phase == .idle`, exactly as `insertFinalText`'s delayed hide already does (TranscriptionController.swift:382–384 — copy that pattern).

## 4/5. whistral_engine.py + protocol tokens — verified except two items

Verified:
- `Engine.lock` (`RLock`, whistral_engine.py:359) is held across the whole session with correct acquire/release on all paths: manual `acquire`/`finally: release` in `_stream_session` (407, 471) and `with self.lock` in `load` (379). ✅ (old #7 fixed — sessions strictly serialized)
- `decode_steps` raises `SessionKilled` on both `self._killed` and the external `should_cancel` poll (185–186); `StreamRunner.start` wires `stream.should_cancel = ctl.get` (501–502), so cancel interrupts **mid-flush** too (flush → decode_steps). ✅ (old #6 first half fixed)
- `stop()`/`cancel()` are non-blocking: no `thread.join` anywhere; they set ctl flags and the session thread emits the terminal event itself (517–542, comments at 529–531/539–541). The stdin reader thread stays responsive. ✅ (old #6 second half fixed)
- `handle_command(cmd: dict) -> bool` — stale `runner` parameter gone. ✅ (nit #22 fixed)
- Token echo: engine sends `"token"` with `sessionStarted`, `segment`, `final` and the cancel-before-start `cancelled` (whistral_engine.py:425, 443–447, 452, 467, 416); `StreamRunner.start` passes `session_token` through to `_stream_session` (499–503); Swift parses it (SidecarEngineClient.swift:394, 397) and guards `.final` (TranscriptionController.swift:313–317) and `.cancelled` (318–325). Stale finals/cancels can't clobber a live session. ✅ (old #17 fixed)
- `partial` events carry **no** token and correctly need none: Swift gates them on `phase == .recording || .starting` (TranscriptionController.swift:303) and partials only update HUD text — they never insert anything. ✅ per brief.

**Defect 3 — major: `load` on the reader thread deadlocks against a live session.**
`handle_command("load")` calls `ENGINE.load(...)` synchronously on the stdin reader
thread (whistral_engine.py:552–556). `load()` blocks on `self.lock` (379) — which the
session thread holds for the entire session (407–471). The session only leaves its main
loop when `ctl["flush"]` is set, and only `handle_command("stop")` — read by the *blocked*
thread — sets it. Trigger: user changes the model in Settings (or the model-ID sink
fires, AppModel.swift:159–168) while a dictation is recording. Both threads wedge
permanently (Swift's 45 s watchdog gives up client-side, but the engine is bricked until
killed). Suggested one-line fix: run the load on a worker thread (reader returns
immediately) or refuse `load` while `RUNNER is not None and RUNNER.active` (emit a busy
error, as `start` already does at 566–567).

**Defect 4 — minor: two session-ending emits still lack the token echo.**
`except SessionKilled: emit({"type": "cancelled"})` (whistral_engine.py:472–473) and
`except Exception: … emit({"type": "final", "text": ""})` (474–477) omit the token. A
stale tokenless `cancelled` passes Swift's `token == nil` accept branch
(TranscriptionController.swift:319) and can `resetToIdle` a queue-pending (`.starting`)
follow-up session; a tokenless empty `final` is dropped only by the phase guard. This is
the exact hole the token echo exists to close. Fix (`token` is in scope in both
handlers): `emit({"type": "cancelled", "token": token})` and add `"token": token` to the
fallback final.

Nit: the `transcribe` command runs `vx_transcribe` outside `ENGINE.lock` (584–592) —
concurrent model use if a session is live. Currently unreachable (SidecarEngineClient.swift:357
`transcribeFile` has no callers), so no runtime risk today.

## 6. HUDController.swift — VERIFIED except show-during-fade

Verified:
- `hide()` bumps the generation, captures it, and the completion only `orderOut`s when the generation is unchanged (HUDController.swift:55–65).
- Anchoring once per appearance: `showListening()` → `presentPanel(anchorFresh: true)` (36); later `update`/`showTranscribing` only resize, and only when the size actually changed (97–120, 113–119). Old #13 fixed. ✅

**Defect 5 — major: a show during an in-flight fade-out still loses.**
`presentPanel` bumps the generation / restores the fade-in only when `!panel.isVisible`
(121–129). During the 0.15 s fade-out the panel is **still** `isVisible` (orderOut
hasn't run), so a `showListening()` inside that window takes the `anchorFresh` branch
(113), re-anchors the *old* panel, bumps nothing, and never restarts the fade-in (alpha
left mid-fade near 0). The pending `hide()` completion then finds
`generation == gen` (both unchanged since only `hide` bumped it) and `orderOut`s the new
session's HUD (63–65) — old #12's exact scenario survives for 150 ms after every hide.
Suggested one-line fix: in `presentPanel`, key the "fresh appearance" branch on
`anchorFresh` as well (bump generation + reset alpha + fade in whenever
`anchorFresh || !panel.isVisible`), not on `!panel.isVisible` alone.

## 7. TextInserter.swift — verified, two soundness minors

Verified:
- Restore is `changeCount`-guarded: `changeCountAfterWrite` captured after our write (101), restore skipped if anything else touched the pasteboard (110). Old #15 fixed. ✅
- Non-string payload types set `hasNonStringTypes` (85, 93) and the whole restore is then refused (111) rather than restoring a string-less snapshot that destroys richer contents. ✅
- Focus-changed fallback: paste downgrades to `keystrokes` when the frontmost bundle ID no longer matches the capture-time one (27–32). Old #16 partially fixed (no verification of paste landing, but that was accepted). ✅

**Defect 6 — minor: nil frontmost bypasses the focus check (paste proceeds blind).**
If `NSWorkspace.shared.frontmostApplication` is nil (mid app-switch, login screen,
Spaces transition), the `let frontmost` binding fails at TextInserter.swift:27–28, the
whole `if` falls through and the **paste is sent with no check at all** — the riskiest
case gets the least protection. Fail closed instead:
`guard let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, frontmost == expectedBundleID else { method = .keystrokes }` (same treatment when
`expectedBundleID` itself is nil, i.e. capture began with no frontmost app).

**Defect 7 — minor (new agent change, now complete): the insertion-failure fallback re-pastes.**
The failure branch of `insertFinalText` calls `TextInserter.insert(trimmed, method:
.clipboard)` to "put it on the clipboard" (TranscriptionController.swift:374), but
`.clipboard` routes to `paste()`, which also synthesizes Cmd+V
(TextInserter.swift:115–127) — a second insertion attempt after the first one just
failed. It is only *accidentally* safe today: `insertionFailed` can currently become
true solely via the accessibility-missing branch (TranscriptionController.swift:361–363),
because `TextInserter.insert` returns `false` only for empty text (TextInserter.swift:24)
— precluded by the `!trimmed.isEmpty` guard — and under missing accessibility the OS
drops the synthetic Cmd+V. The moment `insert()` starts returning `false` for real paste
failures (which its new `Bool` return type invites), the fallback double-pastes into the
app that already failed. Suggested one-line fix: add a copy-only variant (write the
pasteboard without `sendCommandV`) and use it at TranscriptionController.swift:374.

## Concurrent agent's other change — VERIFIED (complete)

- Transcript recording moved to the token-accepted path: `AppModel` no longer records on
  `.final` (AppModel.swift:198–203), `recordTranscript` is called only from
  `insertFinalText` after the phase/token guards (TranscriptionController.swift:342–347);
  stale finals are dropped silently. Concurrency-mid-flight states observed during the
  audit were transitional only; final state is coherent and correct.
- `resetToIdle(hideHUD:)` (TranscriptionController.swift:259–267) is used coherently; the
  delayed "Copy ready to paste" hide is correctly token- and phase-guarded (379–385).

---

## Summary

| # | Area | Severity | One-liner |
|---|------|----------|-----------|
| 1 | SidecarEngineClient.swift:213 | major | Crash-restart counter reset at spawn makes the ≤3 cap unreachable → infinite 1.5 s restart loop |
| 2 | TranscriptionController.swift:169–171, ~286–288 | minor | Delayed `hud.hide()` timers unguarded → can bury a fresh session's HUD |
| 3 | whistral_engine.py:552–556 (vs 379, 407–471) | major | `load` on the reader thread blocks on the session lock → permanent deadlock if model changes mid-recording |
| 4 | whistral_engine.py:473, 477 | minor | `cancelled`/fallback `final` emits omit the token echo |
| 5 | HUDController.swift:113–129 (vs 55–65) | major | Show during an in-flight fade-out doesn't bump the generation → new HUD ordered out by the old hide |
| 6 | TextInserter.swift:27–30 | minor | Nil frontmost skips the focus check → blind paste; fail closed to keystrokes |
| 7 | TranscriptionController.swift:374 | minor | Failure fallback re-uses paste() which also sends Cmd+V → double-paste once insert() returns real failures |

Everything else checked in areas 1–7 is **VERIFIED**, including the prior blockers
(stdin pipe cast), the 30 s/45 s/watchdog and pendingStart work, the graceful
config-change session end, engine lock serialization with non-blocking stop/cancel and
mid-flush kill, the token-echo protocol end-to-end (partials correctly ungated), the HUD
generation/anchor scheme for the clear case, and the changeCount-guarded clipboard
restore. No git operations performed; project files untouched apart from this report.

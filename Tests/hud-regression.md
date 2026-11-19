# HUD regression check — post edit-waves

Scope: `HUDController.swift`, `HUDView.swift`, HUD call sites in
`TranscriptionController.swift` (round: after generation-bump-on-anchorFresh,
token-guarded delayed hides, stop-cue gating, TextInserter outcome propagation).
Findings audit. RESOLUTION UPDATE: all four defects fixed and verified (see ✅ RESOLVED notes per finding).

## Confirmed OK

1. **State machine.** start → `showListening()` (waveform immediate) → partials via
   `update` → `stopSession` → `showTranscribing()` (shimmer dots) → `final` →
   `insertFinalText` → success: `resetToIdle()` → fade-out; failure: copy-only
   fallback + persistent "Insertion failed — transcript copied to clipboard.
   Press ⌘V to paste." that survives via `resetToIdle(hideHUD: false)` and a
   3 s guarded hide. Audio-interrupt message ("Audio input changed; finishing…")
   correctly survives the `showTranscribing()` it triggers
   (`stopSession(finalizingMessage:)` order is right). Engine `.error` during
   recording/finalizing updates the HUD text and token-guards its 3 s reset. Coherent.
2. **Delayed hides.** All four delayed hides in TranscriptionController are
   `sessionToken`-guarded (+ `phase == .idle` where both are needed): pending-start
   watchdog, mic-denial, insertion-failure, engine-error reset. `sessionToken`
   increments on every `startSession`, so no delayed hide can bury a newer
   session's HUD. The generation scheme in `presentPanel`/`hide` has no
   double-fade or closure leak: a stale hide's completion sees `generation != gen`
   and no-ops; the later fade-in's animation supersedes the in-flight fade-out on
   the same `alphaValue`; completions are tracked to exactly one animation each.
   Non-fresh resize path untouched — no mouse chasing. ✅
3. **HIG loading/feedback.** Visible feedback is immediate on every start path
   (`showListening()` or "Preparing the speech engine…"); HUD is passive and
   non-activating; Insert/Esc aids are unobtrusive; sounds are subtle, gated, and
   silent on failure/cancel; spinner dots respect Reduce Motion. ✅ except D3.

## Defects

### D1 (major) — unguarded 2.0 s hide in `beginCapture`'s catch (TranscriptionController.swift, `beginCapture`, catch block)

✅ RESOLVED (fixer round 10): token now captured at throw time and the 2.0 s
closure guards with `sessionToken == token && phase == .idle`
(TranscriptionController.swift:221-226).

`audio.start()` throws → message shown → `DispatchQueue.main.asyncAfter(+2.0) {
self?.hud.hide() }` with **no** token/phase guard (the only remaining unguarded
delayed hide). If the user presses the hotkey again inside the 2.0 s window, the
new session starts and ~2 s later this bare `hud.hide()` fades out and orders out
the live session's HUD — dictation continues invisibly (same class as the fixed
findings).

**Minimal fix:** in `beginCapture`, capture the token before the `do` block is
neat but the token is already bumped by `startSession` before `beginCapture`
runs; in the catch closure capture and guard:
```swift
} catch {
    hud.update(text: error.localizedDescription)
    phase = .idle
    let token = sessionToken
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
        guard let self, self.sessionToken == token, self.phase == .idle else { return }
        self.hud.hide()
    }
}
```
(token captured at throw time; any new session bumps past it. The `phase == .idle`
check also makes Esc-then-restart-safe behavior explicit.)

### D2 (minor) — `anchorFresh` on a fully-visible panel blinks (HUDController.swift, `presentPanel`)

✅ RESOLVED (fixer round 10): `isFadingOut` added (HUDController.swift:28);
set in `hide()` (:63), cleared in hide's completion after `orderOut` (:73) and
in presentPanel's fresh branch (:133). Fresh branch always bumps `generation`
+ refreshes content size/anchor, but only resets alpha/orderFront/fade-in when
`!panel.isVisible || isFadingOut` (:117-141). Generation-bump anchorFresh fix
preserved. (The completion's mutation uses `MainActor.assumeIsolated` — the
closure is Sendable, so a bare assignment warned.)

The anchorFresh branch unconditionally does `alphaValue = 0` + fade-in. When the
panel is already fully visible (reachable in the insertion-failure path:
`.finalizing` HUD at alpha 1 → `resetToIdle(hideHUD: false)` → `hud.showListening()`),
the HUD dips to transparent and fades back — a visible blink each time the
failure message appears. The race case (show mid-fade-out) still needs the reset.

**Minimal fix:** track the in-flight fade-out:
```swift
// add: private var isFadingOut = false
```
Set `isFadingOut = true` in `hide()`; in `presentPanel`'s fresh branch always
bump `generation` + size/anchor (unchanged), but only reset alpha / order front /
fade-in when `!panel.isVisible || isFadingOut`; set `isFadingOut = false` both
after starting the fade-in and in `hide()`'s completion after `orderOut`. Keep the
`hide()` generation guard exactly as is.

### D3 (minor, HIG) — modal alert + dead notification on the accessibility-missing path (TranscriptionController.swift, `PermissionHotkeyBridge.postNeedsAccessibility`)

✅ RESOLVED (fixer round 10, dead code removed per rule): the
`Whistral.needsAccessibility` notification post and the `NSAlert.runModal()`
block are gone — `PermissionHotkeyBridge` (its only consumer) deleted entirely.
Replaced by `TranscriptionController.showNeedsAccessibility()`
(:299-316, call site :127): `hud.showListening()` + the System Settings
message + 2.5 s delayed hide guarded by `sessionToken == token && phase == .idle`
(same pattern as mic denial). Settings is no longer auto-opened; the message
carries the path (acceptable: start-path feedback now stays passive/non-blocking,
per the audit's HIG finding).

Start-path feedback is otherwise passive, but this branch pops `NSApp.activate` +
`alert.runModal()` — a blocking modal from the hotkey path (stalls the main run
loop's queuing of engine/audio callbacks and hotkey handling while open; steals
activation). Additionally, the `Whistral.needsAccessibility` notification
posted just above has **no receiver anywhere** (grep: only the post site) — dead code.

**Minimal fix:** replace the alert with the HUD itself, e.g.
```swift
NotificationCenter.default.post(name: Notification.Name("Whistral.needsAccessibility"), object: nil)
hud.showListening()
hud.update(text: "Accessibility access is needed to dictate. Allow it in System Settings > Privacy & Security > Accessibility.")
```
plus either wiring that notification's receiver to open Settings, the same
auto-open used on the mic-denial path style, or a delayed (`phase`-guarded)
hide. If an alert must stay, at minimum drop `runModal()` in favor of a
non-modal presentation. (Also delete or wire up the dead notification.)

### D4 (nit, quick win) — insertion-failure HUD shows a frozen waveform and a dead "Esc to cancel"

✅ RESOLVED (fixer round 10): `hud.micLevel = 0` added right after
`hud.showListening()` in `insertFinalText`'s failure branch
(TranscriptionController.swift:451) — bars now sit flat instead of frozen
mid-height. The optional Esc-hint variant is deliberately NOT done (needs a
published flag on HUDController + HUDView; out of scope — HUDView is another
agent's file).

In the failure branch of `insertFinalText`, `hud.showListening()` puts the HUD
back in `.listening` (title "Listening…", waveform, "Esc to cancel") but the
session is already over: `micLevel` keeps its last value (only `hide()` resets
it; no `reportRawLevel` arrives after `audio.stop()`), so the bars freeze
mid-height, and Esc is a no-op for 3 s (TranscriptionController phase is `.idle`).

**Minimal quick wins (one line each, in `insertFinalText`'s failure branch):**
- `hud.micLevel = 0` right after `hud.showListening()` (flat bars).
- Optional (needs a small published flag on HUDController + HUDView to hide the
  "Esc to cancel" hint for message-only states — more invasive; the ⌘V hint in
  the message already compensates, so the frozen-waveform line alone is the
  cheap 90%).

## Summary

| # | Where | Severity | One-liner |
|---|-------|----------|-----------|
| D1 | TranscriptionController `beginCapture` catch | major | 2.0 s delayed hide unguarded → buries a fresh session's HUD |
| D2 | HUDController `presentPanel` | minor | anchorFresh + already-visible panel → visible alpha blink |
| D3 | TranscriptionController `PermissionHotkeyBridge` | minor | modal `runModal` + dead notification on accessibility path |
| D4 | TranscriptionController `insertFinalText` failure branch | nit | frozen waveform bars / dead "Esc to cancel" in failure message |

No other HUD regressions found; the three previously landed fixes
(anchorFresh generation bump + fade-in rerun, token/phase-guarded delayed hides,
copy-only fallback) hold after the later edit waves.

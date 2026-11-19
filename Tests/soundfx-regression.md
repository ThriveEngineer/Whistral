# Sound-feedback regression check — findings

Scope re-checked after edit waves: TextInserter outcome propagation, watchdog
epochs, delayed-hide guards, engine token echoes. Findings only — no edits.

## Confirmed OK

1. **Cue placement & failed-insertion gating — OK**
   - Start cue: `Whistral/TranscriptionController.swift:211` — inside
     `beginCapture()`'s success path, after `phase = .recording`, guarded by
     `settings.soundFeedback`. Plays exactly once per session; `beginCapture()`
     is the only caller (`engineState == .ready` in `startSession()`).
   - Stop cue: `TranscriptionController.swift:407-408` — still gated on
     `if !insertionFailed` (`insertionFailed` declared at :387). Failed
     insertion *and* accessibility-denied (which sets the flag at :395-397)
     both stay silent; transcript-only-to-clipboard failure path plays nothing.
   - Order invariant held: the stop cue fires after `TextInserter.insert(...)`
     has been kicked off (:391-401), so sound can never delay text.

2. **Settings default & toggle binding — OK**
   - `Whistral/SettingsStore.swift:99` — `@Published var soundFeedback: Bool = true`.
   - `Whistral/SettingsStore.swift:117` — `load()` fallback `... ?? true`.
   - `Whistral/SettingsView.swift:68` — `Toggle("Sound feedback", isOn:
     $settings.soundFeedback)` still rendered in GeneralPane / "Behavior".
   - Sanity: those are the only refs to `soundFeedback` in the target.

3. **No double-cues / no failure cues — OK**
   - Queued-start path (`queuePendingStart` :161 → watchdog `:171`, epoch-rearmed
     at :179 / :444, `maybeStartPendingSession` :434) plays no sound anywhere;
     it funnels into `pendingStart = false` → `phase = .idle` → `startSession()`
     (`:438-440`) → single `beginCapture()` → single start cue. `pendingStart`
     is cleared synchronously before the restart, and `startSession()`'s
     `guard phase == .idle` (:127) makes a second entry a no-op. Watchdog
     later firing is dead (token/epoch guards, :178-180).
   - Failure/reset paths are all silent: engine error (:339-352 →
     `resetToIdle`), pending-start timeout (:181-188), finalizing timeout
     (:262-266), audio-interrupt finalize (`handleAudioInterrupt` :217-222 —
     leads to a *successful* completion → stop cue is correct there), cancel
     (`:270-276`, "Intentionally silent" comment intact), stale
     final/`cancelled` engine events (:326-336 → `resetToIdle`, no cue).

4. **Sound asset references still valid — OK**
   - Cues are `NSSound(named:)` system references (`:57-58`, "Tink" / "Pop");
     `/System/Library/Sounds/Tink.aiff` and `Pop.aiff` both still exist (verified).
   - No bundled sound assets exist or are referenced: `Whistral/Resources/`
     contains only `Engine/`; built app `Contents/Resources/` = `AppIcon.icns`,
     `Assets.car`, `requirements.txt`, `whistral_engine.py`(+`.pyc`) — no
     sound files present or needed, and nothing was collateral-damaged by the
     AppIcon/Assets.xcassets migration (Assets.car contains only the icon).
   - `HUDController.swift` contains no sound/NSSound/audio references — all
     cue logic remains solely in `TranscriptionController.SessionSounds`.

## Defect

**D1 — RESOLVED (2026-11-19).** The start cue used to play while the
microphone was live (`:211` after `try audio.start()`): the blip could leak
into the engine's first audio window, and a playback-driven route/rate change
could collide with the just-opened capture (the event class
`audio.onInterrupted` reacts to). Fixed by hoisting the cue above the capture
start in `beginCapture()`. Verified: incremental Debug build, scheme Whistral,
destination platform=macOS,arch=arm64 → **BUILD SUCCEEDED**, zero compiler
warnings (only the pre-existing informational appintentsmetadataprocessor
note). Backup of the pre-edit file: `/tmp/TranscriptionController.swift.bak-d1`.

**Current code around the change** (`beginCapture()`,
`Whistral/TranscriptionController.swift`, start cue now at :213, capture start
at :214):

```swift
        do {
            // Start cue BEFORE the mic opens so the blip is never captured or
            // collides with capture via a playback-driven route change.
            // Tradeoff, accepted deliberately: if audio.start() throws below,
            // the session fails right after a start blip. The zero-overlap
            // alternative (delaying capture until the cue finishes) is
            // rejected — it would add dictation-start latency.
            SessionSounds.maybePlayStart(enabled: settings.soundFeedback)
            try audio.start()
            engine.start(delayMs: settings.transcriptionDelayMs, sessionToken: sessionToken)
            phase = .recording
            scheduleMaxDurationWatchdog()
```

Accepted tradeoff: an `audio.start()` throw is now preceded by the start
blip (error HUD still shows and no further cues fire). A zero-overlap
alternative (delaying capture start until the cue finishes ≈150 ms) was
rejected as it adds dictation-start latency. Residual overlap: none by
ordering intent — playback begins before the mic opens (NSSound.play() is
async; sub-second overlap with capture-open is possible and matches Apple's
own Dictation start-blip behavior).

— Verified on working tree at commit `a09dd26`; nothing committed, no edits made.

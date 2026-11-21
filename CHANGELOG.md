# Changelog

All notable changes to Whistral are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.2] - 2026-11-21

### Added

- **Fluid bottom-edge activation glow:** When voice detection starts, a subtle,
  water-like ripple in the user's macOS system accent color emerges from the
  bottom edge of the screen (80% opacity at bottom, fading smoothly to 0%
  above), waving gently for 3 seconds before dissolving. Fully non-interactive
  (`ignoresMouseEvents`) so it never blocks clicks or interaction with the Dock.

## [0.3.1] - 2026-11-20

### Changed

- **Dictation HUD redesigned as a compact bottom-centre pill.** The overlay
  now appears at the horizontal centre of the screen, just above the Dock,
  instead of near the mouse cursor. It shows only a waveform (while
  listening) or a spinner + broom icon (while processing) — no text, no
  labels, no Esc hint. The pill auto-sizes to its content via a `Capsule`
  background and `fittingSize` layout.

### Changed

- The App Sandbox is now disabled (project setting) and the hardened-runtime
  build declares the `com.apple.security.device.audio-input` entitlement, so
  the Python sidecar can bootstrap its virtual environment unimpeded and
  macOS actually offers the microphone permission prompt. The app still
  requests only microphone and Accessibility permissions, and all audio and
  text processing stays on-device; what this fixes on top of 0.1.0 is engine
  startup at first launch, which could fail under the sandboxed Python stub.
- The app icon is now built with the Icon Composer pipeline
  (`AppIcon.icon`), replacing the older static `AppIcon.appiconset`, and
  carries author-level appearance variants: a flat seven-bar waveform on a
  dark background shared by light and dark appearance, plus a tinted variant
  that renders the bars as monochrome glyphs.
- Interface copy polish: error messages and action labels were reworked to
  state what happened and what to do next, and the status-item recovery
  action is now reachable as "Show Whistral in Menu Bar" when macOS has
  hidden the icon.
- `MARKETING_VERSION` is aligned to 0.1.0, matching the release branding and
  the CI tagging guard.

### Fixed

- **Engine robustness.** All MLX work — model loads, streaming sessions, and
  file transcription — now runs on a single dedicated worker thread, keeping
  MLX's thread-local GPU streams consistent and the command reader responsive
  (a second `load` during a live session queues behind it instead of wedging
  the engine). Cancellation now also interrupts a flush in progress, and
  every `final`/`cancelled` event echoes its session token so a stale event
  can no longer be mistaken for the current session's result.
- **Microphone prompt never appeared.** Under Hardened Runtime, macOS silently
  suppresses the microphone permission prompt unless the binary declares the
  `com.apple.security.device.audio-input` entitlement — first launch looked
  permanently denied with no prompt and no entry in the Microphone privacy
  pane. The entitlement is now part of the build and the prompt fires on
  first dictation.
- **Hotkey swallowed Space system-wide.** The global-hotkey event tap
  consumed every Space key-up regardless of state, making the Space bar dead
  in other apps and breaking ⌘Space (Spotlight) while Whistral ran. Key-up
  events are now consumed only when the hotkey was actually armed by a
  matched key-down, and a stalled tap recovers itself after one second.
- **The menu bar icon never appeared.** In the SwiftUI app lifecycle the
  app's `delegate` is a SwiftUI proxy, so the status-item installer's cast
  to the app's AppDelegate failed silently and the icon (the app's only
  mouse-accessible surface) was never created. The installer now receives
  the AppDelegate directly instead of digging it out of `NSApp.delegate`.

## [0.3.0] — 2026-11-20

### Added

- **In-App Update Checker:** Background check for new releases via GitHub Releases API, with an update download button appearing in the menu bar and Settings window (banner & About tab).
- **Deepened Multilingual Self-Correction & Cross-Sentence Resolution:** Expanded speech slip recognition across 13 languages (English, German, Spanish, French, Italian, Portuguese, Arabic, Dutch, Korean, Japanese, Russian, Chinese, Turkish) with cross-sentence context resolution (dates, names, reasons).
- **Intent Preservation Safeguards:** Dedicated rules ensuring genuine apologies, additive statements, and intentional contrasts are strictly preserved and never accidentally stripped.

### Changed

- **Apple HIG-Native Dictation HUD:** Redesigned the floating HUD to strictly adhere to Apple's Human Interface Guidelines for transient feedback panels.
- **Borderless Glassmorphism:** Removed the distracting grey outline/border around the HUD, adopting a clean, borderless `.ultraThinMaterial` surface with subtle system shadows.
- **System Components:** Replaced custom decorations and animations with native SF Symbols (`mic.fill`), native indeterminate `ProgressView()`, and `⎋ Esc` keycap indicator.

## [0.2.1] — 2026-11-20

### Fixed

- **Multilingual Smart Correction across all languages.** Smart Correction
  now works seamlessly in German, Spanish, Arabic, French, Italian,
  Portuguese, Dutch, Chinese, Japanese, Russian, and all other languages.
  Language retention is strictly enforced to prevent unexpected translation
  to English.
- **Multilingual self-corrections and fillers.** Added native recognition
  for foreign self-correction cues (e.g. German *"ich meinte"*, *"nein warte"*,
  Spanish *"perdón"*, *"quise decir"*, Arabic *"عفواً"*, *"أقصد"*) and
  conversational filler words (*äh*, *ähm*, *eh*, *este*, *يعني*, etc.).

## [0.2.0] — 2026-11-20

### Added

- **Smart on-device correction via Apple Foundation Models.** Whistral now
  post-processes raw Voxtral speech transcripts using Apple's on-device
  `FoundationModels` framework (Apple Intelligence).
- **Spoken self-correction and filler removal.** Automatically detects and
  resolves speaker self-corrections across sentence boundaries (e.g.
  *"Can we do a meeting tomorrow at 10? Oh, sorry, I meant 11 a.m."* →
  *"Can we do a meeting tomorrow at 11 a.m.?"*), removes spoken filler words
  (*uh*, *um*, *like*, *you know*), and eliminates false starts and repetitions.
- **Speed vs. Quality modes.** Both Smart Correction and Voxtral STT offer
  dedicated presets for low latency or higher accuracy:
  - Smart Correction: `Speed (Fast)` and `Quality (Accurate)`.
  - Voxtral STT: `Speed (Fast)` (240 ms), `Medium` (480 ms, default),
    `Quality (Accurate)` (720 ms), and `Custom`.
- **Background session prewarming.** The Apple Foundation Model session is
  pre-allocated and warmed in the background when dictation begins, minimizing
  turn-around latency when the user stops speaking.
- **Updated welcoming onboarding.** The first-launch experience now introduces
  both Voxtral STT and on-device Smart Correction.

## [0.1.1] — 2026-11-20

### Fixed

- **First-launch onboarding now reliably appears.** The welcome window was
  created but could fail to surface, because Whistral is a menu-bar
  (.accessory) app: showing the window didn't activate the app, so on a
  clean first launch the "Welcome to Whistral" window stayed behind other
  apps' windows (or appeared unactivated). The onboarding and Settings show
  paths now explicitly activate the app and unhide it before bringing the
  window frontmost, so the welcome flow reliably appears on first launch.

## [0.1.0] — first release

_2026-11-19_

Requires an Apple Silicon Mac (M1 or later) on macOS 27.2 or newer, ~4 GB of free disk space for the default model (~9 GB with the BF16 variant), and microphone and Accessibility permissions.

### Added

- **Local streaming dictation.** Hold a global shortcut (default ⌥Space, works
  in any app) to speak and have your words typed at the cursor, with no
  push-to-talk round trip if you prefer toggle mode instead.
- **On-device speech recognition** via Mistral AI's Voxtral Mini 4B Realtime,
  running locally on the MLX stack through the
  [voxmlx](https://github.com/awni/voxmlx) pipeline — 6-bit quantized model by
  default (~3.9 GB, downloaded once), with the BF16 original (~8.6 GB)
  selectable in settings. Automatic recognition across 13 languages: Arabic,
  Chinese, English, French, German, Hindi, Italian, Dutch, Portuguese,
  Japanese, Korean, Russian, and Spanish.
- **Live HUD.** A floating, non-activating panel near your cursor shows a
  responsive waveform and streaming partial text while you speak; Esc cancels,
  and the animation respects Reduce Motion.
- **Text insertion at the cursor.** Transcribed text lands in the focused
  field via a paste that briefly borrows, then restores, your clipboard; a
  synthetic-keystroke mode is available for apps that dislike synthetic
  pastes, and if insertion fails the transcript is copied to the clipboard
  with a clear on-screen message so nothing is lost.
- **Guided onboarding.** A brief first-run flow with an honest pre-permission
  screen (the system alert still makes the actual grant), Accessibility setup,
  engine bootstrap, and a one-time model download that can finish in the
  background — onboarding never traps you on a denied permission.
- **Settings window** with General, Dictation, Engine, and About panes:
  re-recordable global hotkey (modifier + key required), hold-vs-toggle
  trigger, insert-at-cursor toggle, insertion method, streaming delay tokens
  (80 ms–2400 ms), sound feedback, launch at login, and the model picker.
- **Menu bar presence and recent transcripts.** A status item with a live
  state menu (dictation toggle, engine status, recent transcripts ready to
  copy), plus a "Show Whistral in Menu Bar" recovery path and onboarding
  guidance for when macOS hides the icon.
- **GPU worker-thread engine.** A small Python sidecar (voxmlx on MLX) runs on
  a dedicated worker thread and streams transcriptions to the app over a
  length-prefixed protocol; crash restarts are bounded by a capped backoff.
- **Subtle feedback cues**, using standard system sounds when dictation starts
  and finishes (optional, off-able in settings).
- **Release packaging script and continuous integration** for the open-source
  build.
- **Documented performance.** End-to-end latencies measured on Apple M5
  (16 GB unified memory) with the default 6-bit model: first partial text in
  about 0.7 s, dictation finalized about 0.6 s after you stop, model load
  about 1 s cached — see `Tests/perf-report.md` and `Tests/bench_latency.py`.

### Changed

- Default model switched to the voxmlx-native 6-bit community port
  (`mlx-community/Voxtral-Mini-4B-Realtime-6bit`); the earlier 4-bit port has
  an incompatible flat configuration. The BF16 original remains available.
- Entire interface copy audited against Apple's Human Interface Guidelines:
  title-case actions with correct ellipsis usage, consistent "dictation"
  terminology across the menu, HUD, onboarding, and settings, button wording
  that reserves "Allow" for the system permission alert, and error messages
  that always state what happened and what to do next.
- Status item behavior made HIG-compliant and orphan-proof: it is shown
  programmatically on launch, a menu item can restore it if it is hidden, and
  onboarding explains how to get it back.
- The hotkey recorder requires a modifier or function key, so plain typing can
  no longer be swallowed while re-binding the shortcut.

### Fixed

- **Dictation reliability end to end.** A pipe-handling defect meant the
  engine silently received no audio or commands at all; audio and commands now
  flow through a serial write queue with a loud error if a frame is ever
  dropped, and the model auto-loads on launch so dictation works after every
  relaunch instead of only after touching settings.
- **Session hardening.** Dictation sessions are guarded with start (30 s),
  finalization (45 s), and 5-minute maximum-duration watchdogs; a lost hotkey
  release can never leave the microphone recording indefinitely; error paths
  always stop capture; and stale engine events are rejected so a crashed
  session's leftovers can't corrupt the next one.
- **Engine wedges.** Switching models while dictating could deadlock the
  engine's command reader against a live session — model loads now queue on
  the GPU worker thread, and a crashing engine restarts at most three times
  instead of forever.
- **HUD races.** A new dictation session's HUD could be dismissed by a
  fade-out or timer belonging to the previous one; the panel now anchors once
  per appearance and generation-guards all delayed hides.
- **Audio devices.** Changing or disconnecting the input device mid-dictation
  now ends the capture gracefully and flushes what was heard instead of
  dropping the session; failed microphone setup no longer leaves the audio tap
  installed.
- **Clipboard safety.** Paste-based insertion verifies the clipboard before
  restoring it (refusing to clobber richer contents), double-checks which app
  is frontmost — falling back to synthetic keystrokes, fail-closed if focus
  can't be verified — and on failure copies the transcript instead of
  re-pasting it blindly.

### Security

- The app is unsandboxed — the App Sandbox is deliberately disabled so the
  local Python sidecar can bootstrap its engine environment — and requests
  only two permissions, microphone and Accessibility, each with a candid
  purpose string.
- All audio and text processing happens on-device: audio exists only in memory
  while you are dictating and is never written to disk or transmitted, and the
  sole network call is the one-time model download from Hugging Face.
- Session-token guards ensure transcription text can only ever be inserted
  from the session that produced it.
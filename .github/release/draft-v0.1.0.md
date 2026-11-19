# Whistral 0.1.0 — first public release

> Tagline: **Local, streaming voice dictation for macOS. Hold a shortcut, speak, release — your words appear wherever your cursor is, and nothing ever leaves your Mac.**

## Highlights

- **Streaming on-device dictation** — powered by Mistral AI's Voxtral Mini 4B Realtime running locally via MLX; audio is never uploaded, never written to disk, and never leaves your Mac.
- **Hold-or-toggle hotkey** — press ⌥Space (or your own shortcut) system-wide: hold to talk, or press to start and press again to stop. Text is inserted at your cursor; if insertion isn't possible, it's copied to your clipboard with a clear heads-up.
- **Live HUD** — a floating, non-activating panel with a waveform and streaming partial text; it never steals focus and honors Reduce Motion.
- **13 languages, automatically** — no per-language setup; Voxtral handles the language you speak. Accuracy varies by language and accent.
- **6-bit model by default** (~3.9 GB downloaded once on first launch), with the higher-fidelity BF16 original (~8.6 GB) available in Settings.

Polish worth mentioning: a new appearance-adaptive app icon (Icon Composer, with dark and tinted variants), clearer error messages throughout, and a "Show Whistral in Menu Bar" action that recovers the status item if macOS hides it.

## Fixed

- **Engine startup on first launch.** Engine setup could fail when the app was sandboxed (its bundled Python can't bootstrap a virtual environment from inside the sandbox). The App Sandbox is now disabled, so the local engine sets itself up unimpeded — dictation works on a clean first launch.
- **Dropped or mismatched transcripts under load or rapid cancel.** All transcription now runs on the engine's single dedicated worker thread (workflow stays responsive even if you load a model mid-session), canceling interrupts even a flush in progress, and every finished or canceled session reports which session it belongs to — a stale result can no longer be inserted from the wrong dictation.

## Compatibility

Requires an Apple Silicon Mac (M1 or newer, Intel not supported) on macOS 27.2 or later, microphone and Accessibility permissions, and about 4 GB of free disk space for the default model (~9 GB for the BF16 variant). Apache License 2.0; the Voxtral model weights carry their own Apache 2.0 license from Mistral AI.

## Install

**Download:** grab `Whistral-0.1.0.zip` from the release assets below, unzip, move `Whistral.app` to Applications, and launch; onboarding walks you through permissions and the one-time model download. The binary is signed with a development certificate and is **not notarized**, so macOS may warn on first launch: right-click the app and choose **Open**, or allow it in System Settings → Privacy & Security.

**From source:** `git clone https://github.com/ThriveEngineer/Whistral.git`, open `Whistral.xcodeproj` in Xcode 27.2 or newer, set your signing team, and build (`⌘R`).

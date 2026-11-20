# Whistral 0.2.0

Major update introducing **Smart On-Device Correction** via Apple Foundation Models and **Speed vs. Quality Presets** for both speech recognition and text polish.

## Highlights

- **Smart Correction with Apple Foundation Models:** Raw Voxtral transcripts can now be polished directly on-device using macOS's `FoundationModels` framework (Apple Intelligence). Zero audio or text ever leaves your Mac.
- **Spoken Self-Corrections & Filler Removal:** Automatically removes conversational disfluencies (*uh*, *um*, *like*) and detects self-corrections across sentence boundaries (e.g. *"Can we do a meeting tomorrow at 10? Oh, sorry, I meant 11 a.m."* → *"Can we do a meeting tomorrow at 11 a.m.?"*).
- **Speed vs. Quality Modes:**
  - **Smart Correction:** Choose `Speed (Fast)` for rapid turn-around or `Quality (Accurate)` for deeper context analysis.
  - **Voxtral STT Presets:** Choose `Speed (Fast)` (240 ms lookahead), `Medium` (480 ms lookahead, default), `Quality (Accurate)` (720 ms lookahead), or `Custom`.
- **Prewarming:** Apple Foundation Model sessions prewarm in the background while you speak, so the polished text is ready almost instantaneously when you stop.
- **Updated Welcoming Flow:** First-launch onboarding introduces both Voxtral speech recognition and Apple Foundation Model smart correction.

## Compatibility

Requires an Apple Silicon Mac (M1 or newer) running macOS 27.2 or later, microphone and Accessibility permissions, and ~4 GB free disk space for the default 6-bit model (~9 GB for BF16). Apple Foundation Model smart correction requires Apple Intelligence enabled on supported Apple Silicon Macs.

## Install

**Download:** grab `Whistral-0.2.0.zip` from the release assets below, unzip, move `Whistral.app` to Applications, and launch; onboarding walks you through permissions and the one-time model download. The binary is signed with a development certificate and is **not notarized**, so macOS may warn on first launch: right-click the app and choose **Open**, or allow it in System Settings → Privacy & Security.

**From source:** `git clone https://github.com/ThriveEngineer/Whistral.git`, open `Whistral.xcodeproj` in Xcode 27.2 or newer, set your signing team, and build (`⌘R`).

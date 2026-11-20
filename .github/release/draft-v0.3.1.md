# Whistral 0.3.1

## What's new

### Compact bottom-centre dictation HUD

The dictation overlay has been fully redesigned:

- **Position:** now fixed at the horizontal centre of the screen, 24 pt above the Dock — no longer follows the mouse cursor.
- **Shape:** a minimal auto-sizing pill (`Capsule` with `.ultraThinMaterial`) that hugs its content.
- **Content (listening):** animated 5-bar waveform only.
- **Content (processing):** native spinner + `broom.fill` SF Symbol — no sparkles, no stars.
- **No text, no labels, no Esc hint** — purely visual feedback.

## Download

**[Whistral-0.3.1.zip](https://github.com/ThriveEngineer/Whistral/releases/download/v0.3.1/Whistral-0.3.1.zip)**

Unzip, drag `Whistral.app` to `/Applications`, and launch. Grant Accessibility + Microphone when prompted.

## Requirements

- macOS 14 Sonoma or later
- Apple Silicon (arm64)

# Whistral 0.5.0

## Highlights

- **Voz is now a fully integrated speech model — and the new default.** Desert
  Ant Labs' [Voz](https://huggingface.co/desert-ant-labs/voz) (NVIDIA Parakeet
  TDT 0.6B v3) runs **in-process on the Apple Neural Engine via Core ML**
  through the official `desert-ant-core` Swift package — no Python sidecar, no
  4 GB download, just ~337 MB, 25 languages, with live streaming partials.
  Pick it (or keep it) in Settings → Engine → Model.
- **Voxtral remains available.** Mistral's Voxtral Mini 4B Realtime (6-bit and
  BF16) still runs through the MLX sidecar exactly as before; both engines now
  share one `SpeechEngine` protocol, and switching models just works.
- **Onboarding is fixed and scrollable** — the Continue button is always
  visible, and the welcome pages reflect the selectable models.

## Installation

### Via Homebrew Cask
```bash
brew tap ThriveEngineer/whistral https://github.com/ThriveEngineer/Whistral
brew install --cask whistral
```

### Direct Download
Download **[Whistral-0.5.0.zip](https://github.com/ThriveEngineer/Whistral/releases/download/v0.5.0/Whistral-0.5.0.zip)**, unzip it, and move `Whistral.app` to `/Applications`.

Requires an Apple Silicon Mac running macOS 27.2 or newer. Grant Input Monitoring, Accessibility, and Microphone permissions when prompted.

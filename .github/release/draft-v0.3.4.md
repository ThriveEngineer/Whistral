# Whistral 0.3.4

## What's fixed

### Fn Shortcut Detection
- Improved detection of the Fn (Function / Globe) shortcut when macOS reports its modifier-state change with a different key code.
- Unrelated modifier events are passed through, while holding and releasing Fn continue to start and stop dictation in hold mode.

## Installation

### Via Homebrew Cask
```bash
brew tap ThriveEngineer/whistral https://github.com/ThriveEngineer/Whistral
brew install --cask whistral
```

### Direct Download
Download **[Whistral-0.3.4.zip](https://github.com/ThriveEngineer/Whistral/releases/download/v0.3.4/Whistral-0.3.4.zip)**, unzip it, and move `Whistral.app` to `/Applications`.

SHA256: `6d32ad032057ddeb5bda4b355386bfacd3467223099006c41c5572859307d049`

Requires an Apple Silicon Mac running macOS 27.2 or newer. Grant Accessibility and Microphone permissions when prompted.

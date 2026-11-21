# Whistral 0.3.6

## What's fixed

### Global Shortcut Permission
- Explicitly request and monitor macOS Input Monitoring access, required for the global keyboard shortcut.
- Accessibility is reported separately and remains required for inserting text into the active app.
- Onboarding and Settings identify which permission is missing and link to the corresponding System Settings pane.

## Installation

### Via Homebrew Cask
```bash
brew tap ThriveEngineer/whistral https://github.com/ThriveEngineer/Whistral
brew install --cask whistral
```

### Direct Download
Download **[Whistral-0.3.6.zip](https://github.com/ThriveEngineer/Whistral/releases/download/v0.3.6/Whistral-0.3.6.zip)**, unzip it, and move `Whistral.app` to `/Applications`.

SHA256: `653d32d194515a6fa2e83b09ff36bf746d268169f41e9b11b5670a10b3b083c0`

Requires an Apple Silicon Mac running macOS 27.2 or newer. Grant Input Monitoring, Accessibility, and Microphone permissions when prompted.

# Whistral 0.4.0

This release brings together the improvements shipped from v0.3.2 through
v0.3.6.

## Highlights

- **Native Fn shortcut:** Fn (Function / Globe) is the default global dictation
  shortcut, with improved handling of macOS Fn modifier events.
- **Simpler permission setup:** Whistral requests Accessibility and Input
  Monitoring access and explains what each permission is for. Accessibility is
  used for text insertion; Input Monitoring is required to detect the global
  keyboard shortcut. The shortcut is re-armed when access is granted.
- **Activation glow:** A subtle, fluid ripple in your macOS accent color
  appears along the bottom edge when voice detection starts.

## Installation

### Via Homebrew Cask
```bash
brew tap ThriveEngineer/whistral https://github.com/ThriveEngineer/Whistral
brew install --cask whistral
```

### Direct Download
Download **[Whistral-0.4.0.zip](https://github.com/ThriveEngineer/Whistral/releases/download/v0.4.0/Whistral-0.4.0.zip)**, unzip it, and move `Whistral.app` to `/Applications`.

Requires an Apple Silicon Mac running macOS 27.2 or newer. Grant Input Monitoring, Accessibility, and Microphone permissions when prompted.

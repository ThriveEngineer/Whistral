# Whistral 0.3.5

## What's new

### Automatic Accessibility Permission Request
- macOS now displays its Accessibility permission prompt when onboarding reaches the permissions step.
- Returning users without Accessibility access are prompted on app launch.
- The permission explanation now makes clear that Accessibility is required for the global shortcut and text insertion.
- macOS requires the user to approve Whistral in System Settings; the app cannot grant this permission automatically.

## Installation

### Via Homebrew Cask
```bash
brew tap ThriveEngineer/whistral https://github.com/ThriveEngineer/Whistral
brew install --cask whistral
```

### Direct Download
Download **[Whistral-0.3.5.zip](https://github.com/ThriveEngineer/Whistral/releases/download/v0.3.5/Whistral-0.3.5.zip)**, unzip it, and move `Whistral.app` to `/Applications`.

SHA256: `5b142cd6fb14e9b886f363a3ce7849cf8dcfc32aced82cf11cc4a345b578e531`

Requires an Apple Silicon Mac running macOS 27.2 or newer. Grant Accessibility and Microphone permissions when prompted.

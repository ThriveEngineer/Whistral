# Whistral 0.3.3

## What's new

### Default Shortcut is now `Fn` (Function / Globe 🌐 key)
- **Native Dictation Key:** The default global shortcut is now simply **`Fn`**, matching macOS's native dictation feel.
- **Full Modifier & Standalone Support:** The global event tap now listens to `flagsChanged` events to capture `Fn` and modifier-only keypresses with instant responsiveness.
- **Automatic Migration:** Existing installations on the previous default (⌥Space) automatically migrate to `Fn` on launch.

### Fluid Bottom-Edge Activation Glow
- **Visual Cue:** When dictation begins, a subtle, water-like ripple in your macOS System Settings accent color emerges from the bottom edge of your screen, letting you immediately know voice detection is listening.
- **Organic Liquid Motion:** Dual-layer sinusoidal waves with gentle vertical undulation that softly dissolve after 3 seconds.
- **Zero Click Interference:** Runs on an `ignoresMouseEvents` overlay so interaction with the Dock or apps is never obstructed.

### Minimal Bottom-Center Status Pill
- Clean, compact status pill anchored at the bottom-center of the screen.
- Waveform audio meter while speaking, centered spinner while processing, and a broom icon during Apple Intelligence self-correction (no sparkles/stars).

### Apple Notarized
- Signed with an official Apple Developer ID, accepted and stapled by Apple's Notary Service for zero-warning Gatekeeper execution.

---

## Installation Methods

### Option 1: Via Homebrew Cask (Recommended)

Install and receive automatic updates through Homebrew:

```bash
brew tap ThriveEngineer/whistral https://github.com/ThriveEngineer/Whistral
brew install --cask whistral
```

To update in the future:
```bash
brew upgrade --cask whistral
```

### Option 2: Direct Download (Apple Notarized)

Download the pre-built, notarized release archive directly:

1. Download **[Whistral-0.3.3.zip](https://github.com/ThriveEngineer/Whistral/releases/download/v0.3.3/Whistral-0.3.3.zip)**.
2. Unpack the zip archive and drag `Whistral.app` into your `/Applications` folder.
3. Launch Whistral. Grant Accessibility and Microphone permissions when prompted.

**Checksum:**
- SHA256: `27c2f5f8ee4c79c595a371d7fd6ae529865b1d8e68ceeb689193dbe3d24be040`

### Option 3: Build from Source

Build directly from the repository using Xcode:

```bash
git clone https://github.com/ThriveEngineer/Whistral.git
cd Whistral
xcodebuild -project Whistral.xcodeproj -scheme Whistral \
  -configuration Release -destination "platform=macOS,arch=arm64" build
```

The app will be built in `build/DerivedData/Build/Products/Release/Whistral.app`.

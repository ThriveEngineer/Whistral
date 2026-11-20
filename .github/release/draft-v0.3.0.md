# Whistral 0.3.0

Major update featuring an **In-App Update Checker**, **Deepened Multilingual Self-Correction & Cross-Sentence Resolution**, and a redesigned **Apple HIG-Native Dictation HUD**.

## What's New

### 🔄 In-App Update Checker
- Whistral now automatically checks for new releases on GitHub in the background.
- When an update is ready, a **"Download Update"** button seamlessly appears at the top of the menu bar menu and across the Settings window.
- Includes a manual "Check for Updates" trigger with timestamp in Settings > About.

### 🌐 Deepened Multilingual Self-Correction & Cross-Sentence Resolution
- **13 Languages Supported:** English, German, Spanish, French, Italian, Portuguese, Arabic, Dutch, Korean, Japanese, Russian, Chinese, Turkish.
- **Cross-Sentence Resolution:** Accurately resolves spoken corrections across sentence boundaries (e.g. amending dates, times, attendees, or quantities with conversational reasons).
- **Intent Preservation:** Strict safeguards prevent false-positive deletions of real user intent — genuine apologies (*"Sorry for the delay..."*, *"Entschuldigung für die Verspätung..."*), additive remarks (*"Actually, also..."*), and intentional negations are preserved verbatim.

### 🎨 Apple HIG-Native Dictation HUD
- Redesigned to strictly adhere to Apple's Human Interface Guidelines for macOS transient feedback panels.
- **Borderless Glassmorphism:** Removed high-contrast borders for an unobtrusive, floating `.ultraThinMaterial` pill.
- Native system iconography (`mic.fill`), native macOS `ProgressView()`, and `⎋ Esc` key indicator without unnecessary visual clutter.
- Responsive, calm 5-bar audio level meter.

## Compatibility

Requires an Apple Silicon Mac (M1 or newer) on macOS 27.2 or later, microphone and Accessibility permissions, and ~4 GB free disk space for the default model (~9 GB for BF16). Apple Foundation Model smart correction requires Apple Intelligence enabled on supported Apple Silicon Macs.

## Install

**Download:** grab `Whistral-0.3.0.zip` from the release assets below, unzip, move `Whistral.app` to Applications, and launch. On first run, onboarding walks you through permissions and the one-time model download. The binary is signed with a development certificate and is **not notarized**, so macOS may warn on first launch: right-click the app and choose **Open**, or allow it in System Settings → Privacy & Security.

**From source:** `git clone https://github.com/ThriveEngineer/Whistral.git`, open `Whistral.xcodeproj` in Xcode 27.2 or newer, set your signing team, and build (`⌘R`).

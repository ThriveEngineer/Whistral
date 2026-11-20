# Whistral 0.1.1

Bug-fix release on top of 0.1.0. If you already have Whistral running, just replace the app — no settings or model re-download needed.

## Fixed

- **First-launch onboarding now reliably appears.** The "Welcome to Whistral" window was created but could fail to surface, because Whistral is a menu-bar (.accessory) app: showing a window doesn't activate the app, so on a clean first launch the welcome window could stay behind other apps' windows. The onboarding and Settings show paths now explicitly activate the app and unhide it before bringing the window frontmost.

## Compatibility

Requires an Apple Silicon Mac (M1 or newer, Intel not supported) on macOS 27.2 or later, microphone and Accessibility permissions, and about 4 GB of free disk space for the default model (~9 GB for the BF16 variant). Apache License 2.0; the Voxtral model weights carry their own Apache 2.0 license from Mistral AI.

## Install

**Download:** grab `Whistral-0.1.1.zip` from the release assets below, unzip, move `Whistral.app` to Applications, and launch; onboarding walks you through permissions and the one-time model download. The binary is signed with a development certificate and is **not notarized**, so macOS may warn on first launch: right-click the app and choose **Open**, or allow it in System Settings → Privacy & Security.

**From source:** `git clone https://github.com/ThriveEngineer/Whistral.git`, open `Whistral.xcodeproj` in Xcode 27.2 or newer, set your signing team, and build (`⌘R`).

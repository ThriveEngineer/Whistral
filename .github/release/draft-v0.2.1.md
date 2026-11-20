# Whistral 0.2.1

Patch release adding **Full Multilingual Support** to Smart On-Device Correction (German, Spanish, Arabic, French, Italian, Portuguese, Dutch, Chinese, Japanese, Russian, etc.).

## Fixed & Improved

- **Full Multilingual Support:** Smart Correction now reliably processes speech transcripts in any language without translating to English.
- **Multilingual Self-Corrections & Fillers:** Explicit recognition for native correction indicators (German *"ich meinte"*, *"nein warte"*, Spanish *"perdón"*, *"quise decir"*, Arabic *"عفواً"*, *"أقصد"*, French *"je voulais dire"*, etc.) and native filler words (*äh*, *ähm*, *eh*, *este*, *يعني*, etc.).

## Compatibility

Requires an Apple Silicon Mac (M1 or newer) on macOS 27.2 or later, microphone and Accessibility permissions, and ~4 GB free disk space for the default model (~9 GB for BF16). Apple Foundation Model smart correction requires Apple Intelligence enabled on supported Apple Silicon Macs.

## Install

**Download:** grab `Whistral-0.2.1.zip` from the release assets below, unzip, move `Whistral.app` to Applications, and launch; onboarding walks you through permissions and the one-time model download. The binary is signed with a development certificate and is **not notarized**, so macOS may warn on first launch: right-click the app and choose **Open**, or allow it in System Settings → Privacy & Security.

**From source:** `git clone https://github.com/ThriveEngineer/Whistral.git`, open `Whistral.xcodeproj` in Xcode 27.2 or newer, set your signing team, and build (`⌘R`).

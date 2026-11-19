<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/branding/logo-mark-dark-256.png" width="96" alt="Whistral app icon: a white microphone with whistle arcs on a warm bronze sweep, in the system squircle.">
    <img src="docs/branding/logo-mark-256.png" width="96" alt="Whistral app icon: a white microphone with whistle arcs on a warm orange sweep, in the system squircle.">
  </picture>
</p>

# Whistral

An open-source, fully local alternative to Wispr Flow for macOS. Hold a
shortcut, speak, release — your words are typed into whatever app you're
using. Powered by Mistral's [Voxtral Mini 4B Realtime](https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602)
speech model running **on-device** via [MLX](https://github.com/ml-explore/mlx).
No audio, text, or telemetry ever leaves your Mac.

## Features

- **Push-to-talk or toggle dictation** — a global shortcut (default ⌥Space)
  works system-wide, in any app.
- **Completely local** — audio is transcribed on-device with MLX; nothing is
  uploaded anywhere.
- **Live partial results** — a floating HUD near your cursor shows a waveform
  and streaming text while you speak.
- **13 languages** — Voxtral's multilingual ASR automatically handles the
  language you speak.
- **Smart insert** — transcribed text lands in the focused text field via a
  paste that briefly borrows, then restores, your clipboard; a synthetic
  keystroke mode is available for apps that dislike synthetic pastes.
- **Native & unobtrusive** — a menu-bar app that follows Apple's Human
  Interface Guidelines: non-activating panels, passive status feedback,
  proper permissions flow with purpose strings.

## Requirements

- Apple Silicon Mac (M1 or later), macOS 27.2 or newer
- ~3.9 GB free disk space for the model (downloaded once, on your first run)

## Performance

Measured on one Apple M5 machine with 16 GB of unified memory, running the
default 6-bit model; numbers come from a local benchmark, so treat them as a
single data point rather than a promise. The first partial text appears about
0.7 s after speech starts (the first session of a run takes up to about 0.9 s
to warm up), and dictation finalizes about 0.6 s after you stop speaking. The
model loads in about 1 s once cached — a first-ever launch downloads the
~3.9 GB model first. To rerun the benchmark yourself, see
[Tests/perf-report.md](Tests/perf-report.md) and `python3 Tests/bench_latency.py`.

## Install / Build

1. Clone this repository.
2. Open `Whistral.xcodeproj` in Xcode and press **Run**, or build from the
   command line:

   ```sh
   xcodebuild -project Whistral.xcodeproj -scheme Whistral \
     -configuration Debug -destination "platform=macOS,arch=arm64" build
   ```

3. On first launch, Whistral walks you through onboarding:
   microphone permission, Accessibility permission (for the global shortcut
   and text insertion), engine setup, and the model download.

## How it works

- The Swift app captures microphone audio with `AVAudioEngine`, converts it
  to 16 kHz mono, and streams it to a small **Python sidecar**
  (`Whistral/Resources/Engine/whistral_engine.py`) over a length-prefixed
  stdin/stdout protocol.
- The sidecar wraps [voxmlx](https://github.com/awni/voxmlx), an MLX
  implementation of the streaming Voxtral pipeline, and emits NDJSON events
  (`partial`, `segment`, `final`) back to Swift.
- The HUD is a non-activating `NSPanel`, so your keystrokes and focus are
  never stolen. Text insertion is a synthetic ⌘V that saves and restores
  your clipboard.
- The full sidecar protocol (framing, commands, events) is documented in
  [docs/engine-protocol.md](docs/engine-protocol.md).

## Privacy

- Audio is recorded **only** while the shortcut is held (or dictation is
  toggled on) and stays in memory.
- The model weights and the embedded Python engine are stored locally under
  `~/Library/Application Support/Whistral/`.
- No network calls except the one-time model download from
  [Hugging Face](https://huggingface.co/mlx-community/Voxtral-Mini-4B-Realtime-6bit).

## Settings

| Setting | Description |
| --- | --- |
| Dictation shortcut | Re-recordable global hotkey (modifier + key required) |
| Push-to-talk / toggle | Hold the key to talk, or press to start/stop |
| Insert at cursor | Auto-insert the transcription into the focused app (on by default) |
| Insertion method | Paste (fast, restores your clipboard) or synthetic keystrokes |
| Transcription delay | Streaming latency trade-off (80 ms–2400 ms; lower = snappier) |
| Sound feedback | Subtle system sounds when dictation starts and finishes |
| Cancel with Esc | Hardwired: pressing Esc cancels the current dictation |
| Model | Voxtral Mini 4B Realtime — 6-bit (default) or BF16 (original) |
| Launch at login | Register with `SMAppService` |

## Development

- `Tests/test_engine_e2e.py` drives the sidecar protocol end-to-end:
  load → start → feed audio → stop, printing every engine event.
- The UI is built to follow Apple's Human Interface Guidelines — menu bar
  behavior, privacy and permission flow, onboarding, and accessibility —
  per [HIG](https://developer.apple.com/design/human-interface-guidelines/).
- The app icon (also used as the logo mark above) is authored as an
  Icon Composer `.icon` document with light, dark, and tinted variants; the
  rounded **system squircle** silhouette, corner rounding, and drop shadow
  you see are applied by macOS itself — the source layers are full-bleed
  squares.

## License

Apache License 2.0 — see [LICENSE](LICENSE). The model weights carry their
own license from [mistralai](https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602)
(Apache 2.0); the quantized MLX community port follows the same license.

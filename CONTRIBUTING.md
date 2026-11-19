# Contributing to Whistral

Thank you for your interest in improving Whistral, a local dictation app for macOS. All contributions are welcome: bug reports, documentation, and pull requests.

## Building

Build from the project root with:

```sh
xcodebuild build \
  -project Whistral.xcodeproj \
  -scheme Whistral \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64'
```

The app targets Apple Silicon Macs.

## Running the Engine E2E Test

The end-to-end test for the Python transcription engine lives at `Tests/test_engine_e2e.py`. It drives the engine exactly as the app does, so it needs a Python virtual environment set up the same way the app bootstraps it.

In normal use the app creates and manages the venv itself at:

```
~/Library/Application Support/Whistral/venv
```

For development, recreate it manually:

```sh
python3 -m venv ~/Library/Application\ Support/Whistral/venv
~/Library/Application\ Support/Whistral/venv/bin/pip install -r Whistral/Resources/Engine/requirements.txt
```

Then run the test:

```sh
python3 Tests/test_engine_e2e.py
```

If the test fails, verify the venv exists at the path above and that all packages from `requirements.txt` are installed in it.

## Code Style

- **Swift 5.** Keep code compatible with the project's current Swift 5 toolchain.
- **MainActor-default isolation.** The project assumes `@MainActor` isolation by default. Mark anything that is deliberately not main-isolated (background engine work, non-UI helpers) explicitly, and keep UI-facing types implicitly main-actor.
- **HIG alignment.** UI work is expected to follow Apple's Human Interface Guidelines: native AppKit/SwiftUI patterns, standard menu and window behavior, sensible keyboard shortcuts.
- Keep changes focused; prefer small, self-contained PRs.

## Commit Messages

Use short, imperative subjects, for example:

```
Add model variant selector to settings
Fix engine venv bootstrap on first launch
Update requirements.txt for new engine version
```

Guidelines:

- Keep the subject under ~50 characters when reasonable.
- Add a blank line and a body explaining *why* when the change is not self-explanatory.
- Reference issues by number in the body or trailer (`Fixes #12`).

## Pull Requests

- Make sure `xcodebuild` (command above) builds cleanly and, when relevant, `Tests/test_engine_e2e.py` passes.
- **PRs must not record user audio in tests.** Tests must use only synthetic or explicitly bundled sample data. Never capture microphone input or real user speech as part of automated testing.
- Describe what the change does and how you verified it.

## Filing Issues

Please use the provided templates under `.github/ISSUE_TEMPLATE`:

- **Bug report** — tells us your macOS version, your chip, which model variant (6-bit / BF16) you used, and steps to reproduce. Whistral never uploads audio; if your issue involves a specific phrase, describe it in words rather than attaching a recording.
- **Feature request** — a clear description of the problem and the behavior you'd like.

# Whistral — Read-Only Consistency Sweep

**Date:** 2026-11-19 (evening CET) · **Scope:** `Whistral/*.swift`, `Whistral/Resources/Engine/whistral_engine.py`, `README.md`, `CONTRIBUTING.md`, `.github/**`, `Tests/*.py` · **Mode:** report only, no project files edited.

> **Timing note:** the working tree was still being modified while the sweep started (source mtimes 21:00–21:44 CET, e.g. `TranscriptionController.swift` at 21:44:58). All findings below were re-verified against the tree as of 21:46 CET, when no file had changed for ~2 minutes and no other session in the project was active. Every file cited was checked directly on disk.

---

## 1. Model-id / stale-list references

The 6-bit switch is applied consistently in code and docs. One misleading UI reference and one size mismatch remain:

**1.1 — About pane advertises only the BF16 original as "the" model**
- `Whistral/SettingsView.swift:315-317` — `Link("mistralai/Voxtral-Mini-4B-Realtime-2602", destination: URL(string: "https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602")!)`
- The Engine pane's picker reads `AppModel.availableModels` (SettingsView.swift:255-260) and defaults to the 6-bit community port, but the About pane presents the BF16 repo as the single model. Not a stale "4-bit" reference, but inconsistent with what ships.
- **Correction:** link the default `mlx-community/Voxtral-Mini-4B-Realtime-6bit` (or list both variants) in the About pane.

**1.2 — README disk-space claim doesn't match the default model's size**
- `README.md:28` — `- ~3 GB free disk space for the model (downloaded once, on your first run)`
- `AppModel.swift:27` describes the default 6-bit model as `~3.9 GB download`; the BF16 option is `~8.6 GB` (AppModel.swift:28). Plus venv overhead, ~3 GB undersells the real requirement.
- **Correction:** change to "~4 GB (6-bit default) to ~9 GB (BF16) free disk space".

**Clean (verified, no action):**
- `AppModel.swift:20` `defaultModelID = "mlx-community/Voxtral-Mini-4B-Realtime-6bit"`; `AppModel.swift:26-29` `availableModels` lists exactly 6-bit + BF16. The comment at AppModel.swift:22-25 explaining that the `-2602-4bit` port is *excluded* (incompatible flat config) is deliberate documentation, not a stale reference.
- `Whistral/Resources/Engine/whistral_engine.py:548` engine-side fallback `cmd.get("model", "mlx-community/Voxtral-Mini-4B-Realtime-6bit")` matches `defaultModelID`.
- `README.md:5,65,74,88`, `CONTRIBUTING.md:77`, `.github/ISSUE_TEMPLATE/bug_report.md:22-23` (checklist: "6-bit (default)" / "BF16 (original mistralai repo)") — all updated and mutually consistent. No lingering "fp16" text anywhere (grep: 0 hits).
- `Whistral/SettingsView.swift:310` and `OnboardingView.swift:104,271,357` use the generic name "Voxtral Mini 4B Realtime" with no repo id or bit-width.
- `Tests/test_engine_e2e.py:60` sends `{"cmd": "load"}` with no model — relies on the engine-side default above, which is the correct 6-bit repo.
- No other hardcoded model ids exist outside `AppModel.swift:20/26-29` and the engine fallback `whistral_engine.py:548` (repo-wide grep for `Voxtral|mlx-community|mistralai`).

---

## 2. Onboarding copy (`Whistral/OnboardingView.swift`) — no issues found

Checked every user-facing string for stale model names, quantization hints, or download-size claims:

- `OnboardingView.swift:104` — `"On-device dictation with Voxtral Mini 4B Realtime"` — generic, OK.
- `OnboardingView.swift:139` — `"One-time download of the speech model"` — no size claim, OK.
- `OnboardingView.swift:251-269` — welcome bullets ("Everything stays on your Mac", "Choose a shortcut", "Understand speech in 13 languages" + language list) — consistent with README ("13 languages", README.md:17), OK.
- `OnboardingView.swift:357` — `"Downloading Voxtral Mini 4B Realtime"` — generic, with live byte counts, OK.
- `OnboardingView.swift:392` — `"Change the shortcut, transcription delay, or model anytime in Settings (⌘,)."` — matches actual Settings content, OK.

No variant names, no bit-widths, no "2.6 GB"-style claims anywhere in the file or the app (grep for `2\.6 GB` across the repo: only historical hits in `Tests/review-findings.md`).

---

## 3. Status of the 24 code-review findings (Tests/review-findings.md)

**#16 (paste target verification / fallback) — FIXED (with one residual).**
- Session-time snapshot of the frontmost app: `TranscriptionController.swift:179` — `captureFrontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier` (captured in `beginCapture()`), passed at `TranscriptionController.swift:334-338` → `TextInserter.insert(trimmed, method: settings.insertionMethod, expectedBundleID: captureFrontmostBundleID)`.
- Fallback on focus change: `Whistral/TextInserter.swift:22-32` — `if let expectedBundleID, let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, frontmost != expectedBundleID { method = .keystrokes }`.
- Clipboard restore is now guarded: `TextInserter.swift:101,109-112` — `changeCountAfterWrite` snapshot + `guard pasteboard.changeCount == changeCountAfterWrite` and `guard !hasNonStringTypes` before restore (also covers finding #15).
- *Residual:* the paste itself is still post-and-hope — `insert` is `@discardableResult` and returns `Bool` (`TextInserter.swift:21-22,40`) but the call site discards it (`_ =`, TranscriptionController.swift:334), so a paste that silently lands nowhere still has no HUD surfacing. Minor; the focus-change failure mode the finding described is handled.

**#18 (audio device-change handling / failed-start tap leak) — FIXED.**
- Config-change observation: `Whistral/AudioCaptureEngine.swift:71-80` — observer for `.AVAudioEngineConfigurationChange` calls `self.stop()` then `self.onInterrupted?()`; wired mid-session in `TranscriptionController.swift:186-188` → `handleAudioInterrupt()` (TranscriptionController.swift:201-205, "Audio input changed; finishing…", flushes what was heard).
- Failed-start tap leak: `AudioCaptureEngine.swift:62-66` — on `engine.start()` throw, `input.removeTap(onBus: 0)` before rethrowing.

**All other findings, status with evidence:**

| # | Status | Evidence |
|---|--------|----------|
| 1 | Fixed | `SidecarEngineClient.swift:217` — `stdinHandle = (proc.standardInput as? Pipe)?.fileHandleForWriting`; nil path emits an error (line 218-220); dropped frames now log (`sidecar:306-308`, "Engine is not running; dropped a frame.") |
| 2 | Fixed | `AppModel.swift:160-180` — engine `ready` event triggers `engineClient.load(modelID: settings.modelID)`; guards re-entrancy with `.loading/.downloadingModel/.ready` |
| 3 | Fixed | `.error` handled in `maybeStartPendingSession` (`TranscriptionController.swift:355-365`) + 30 s pending-start watchdog (`TranscriptionController.swift:161-173`) |
| 4 | Fixed | `.notInstalled, .stopped` branch calls `ensureEngineRunning()` then `queuePendingStart()` (HUD + `pendingStart`, `TranscriptionController.swift:123-126, 151-160`) |
| 5 | Fixed | `resetToIdle()` calls `audio.stop()` (`TranscriptionController.swift:253` "idempotent; also covers error-driven exits mid-recording") |
| 6 | Fixed | Python: `stop()`/`cancel()` non-blocking, no 60 s join on reader thread (`whistral_engine.py:526-545`); decode loops poll `ctl["cancel"]` incl. mid-flush (`py:174-176, 415-417`); Swift finalize watchdog 45 s (`TranscriptionController.swift:233-237`) |
| 7 | Fixed in design — **but see regression R1 below** | sessions serialize on the Engine lock in `_stream_session` (`whistral_engine.py:402, 466`); abandoned sessions block the *session* thread, not the command reader |
| 8 | Fixed | Python error paths emit `final` (`py:427-431, 471-473`); Swift finalize watchdog (above) covers process death |
| 9 | Fixed | `requestMicrophoneThenStart` grant path guards `self.phase == .starting` before restarting (`TranscriptionController.swift:272-275`) |
| 10 | Fixed | crash restart with 3-retry backoff (`SidecarEngineClient.swift:231-248`, `crashRestartCount`) emits `.stopped` and calls `ensureRunning()`; `.notInstalled/.stopped` start path re-queues. *Residual:* `.error` state still disables menu "Start Dictation" (`AppDelegate.swift:102` `dictation.isEnabled = isEngineReady || !isIdle`) — reachable only after 3+ crashes now; minor. |
| 11 | Fixed | frames written on a serial `writeQueue` (`SidecarEngineClient.swift:66, 296, 319-323`), never on the tap thread |
| 12 | Fixed | hide/show generation counter (`HUDController.swift:24, 56-64, 121-124`) |
| 13 | Fixed (core) | anchor once per appearance (`HUDController.swift:108-119`), resize only on change. *Residual:* the width clamp 240…460 is still moot — `HUDView.swift:47` pins `.frame(width: 380)`, so `HUDController.swift:104` only ever produces 380. Harmless dead code. |
| 14 | Fixed | 5-minute max-duration watchdog (`TranscriptionController.swift:209-216`, armed in `beginCapture` and in the permission path, lines 189, 281) |
| 15 | Fixed | changeCount guard + non-string-type refusal + 0.45 s delay (`TextInserter.swift:84-86, 101, 109-112`) |
| 16 | Fixed | see above |
| 17 | Partially fixed | phase guards added (`.final` accepted only while `.finalizing`, TranscriptionController.swift:296-300; late `.cancelled` only in `.finalizing/.starting`, lines 302-306). **But the token guard is tautological:** `insertFinalText` is called with the *current* `sessionToken` (line 300 → 328 `guard sessionToken == token`), which can never differ from itself — a `final` from a previous session arriving while the new session is `.finalizing` is still accepted. The finding's minimal fix (compare the event-time token against the one captured at start) was not implemented, nor a protocol token. |
| 18 | Fixed | see above |
| 19 | Fixed | `isBootstrapping` flag guards re-entry (`SidecarEngineClient.swift:76, 100-101`); bootstrap completion hops to main queue (`SidecarEngineClient.swift:81-89`) |
| 20 | Fixed | `stdoutBuffer` removed (0 hits in `SidecarEngineClient.swift`) |
| 21 | Fixed | `TimelineView(.animation(minimumInterval: nil, paused: reduceMotion))` drives the dots (`HUDView.swift:65-77, 115-121`) |
| 22 | **UNFIXED (nit)** | `whistral_engine.py:541` — `def handle_command(cmd: dict, runner: StreamRunner) -> bool:` still takes `runner`, and the body still only uses the module global `RUNNER` (e.g. `py:561`, call site `py:615` passes `RUNNER`). |
| 23 | Fixed | RMS averages all channels (`AudioCaptureEngine.swift:108-118`, `for ch in 0..<channelCount`) |
| 24 | Fixed | keyUp matched on keycode only and always consumed (`HotkeyController.swift:140-143`) |

**R1 — NEW REGRESSION (major), introduced by the #7 fix: `Engine._stream_session` references a nonexistent attribute, killing every session.**
- `Whistral/Resources/Engine/whistral_engine.py:402` — `self.engine.lock.acquire()` (and the matching `self.engine.lock.release()` at `py:466`) inside `Engine._stream_session`, but `Engine.__init__` (`py:350-359`) defines `model, sp, config, temperature, model_id, lock, prefix_cache` — there is **no** `self.engine` on `Engine` (`self.engine` exists only on `StreamRunner`, `py:482`, which is a different object).
- Consequence: the first statement of every session thread raises `AttributeError: 'Engine' object has no attribute 'engine'`, is caught by the outer handler (`py:470-473`), and the app receives `error` + `final ""` — no transcript is ever produced at runtime.
- **Correction:** use `self.lock.acquire()` / `self.lock.release()` in `Engine._stream_session` (whistral_engine.py:402, 466).

---

## 4. README "How it works" / Settings table vs. the actual settings

Actual persisted settings (`Whistral/SettingsStore.swift:60-71, 80-119, 133-137`): hotkey, triggerMode, autoInsert, insertionMethod, modelID, transcriptionDelayMs (10 options 80–2400 ms, default 480), launchAtLogin, hasCompletedOnboarding, soundFeedback (default **true**).
UI exposure (`Whistral/SettingsView.swift`): General pane = launch-at-login, insert-at-cursor, sound feedback (`:68-70`); Dictation pane = hotkey recorder, trigger picker, insertion-method picker, insert-at-cursor (`:107-125`); Engine pane = model picker, transcription delay (`:250-275`).

**4.1 — Settings table is missing four real settings**
- `README.md:71-75` lists only: Dictation shortcut · Push-to-talk/toggle · Cancel with Esc · Model · Launch at login.
- Not documented: **Insert transcription at the cursor** (autoInsert, SettingsView.swift:69/118), **Insertion method** — Paste vs. Simulate keystrokes (insertionMethod, SettingsView.swift:112-117), **Transcription delay** (Defaults "Applies to the next dictation", SettingsView.swift:276-293), **Sound feedback** (SettingsView.swift:70).
- **Correction:** add rows for these four settings (defaults: insert-on, Paste, 480 ms, sound on).

**4.2 — "Cancel with Esc" is not a setting**
- `README.md:73` — `| Cancel with Esc | Abort the current dictation and discard the audio |`
- Esc cancel is unconditionally wired (`AppModel.swift:152-180` `observeEscapeKey()` — global + local NSEvent monitors; `TranscriptionController.swift:87-90`); there is no toggle in SettingsStore or SettingsView.
- **Correction:** either drop the row from the settings table (it's fixed behavior, not a setting) or move it to the "How it works" feature description — and note Esc worked during finalizing only *since* the #6 fix, so the row predates the fix's introduction. Simplest fix: remove the row.

**4.3 — "How it works" overgeneralizes text insertion**
- `README.md:55-56` — `Text insertion is a synthetic ⌘V that saves and restores your clipboard.`
- Paste is only one of the two methods (InsertionMethod: clipboard | keystrokes, SettingsStore.swift:31-45); the keystrokes method (`TextInserter.swift:48-60`) never touches the clipboard, and even paste now conditionally refuses restore on non-string or externally-changed pasteboards (TextInserter.swift:109-112).
- **Correction:** e.g. "Text insertion is a paste that briefly borrows and restores your clipboard (with a simulated-keystrokes fallback available in Settings)."

**Consistent, no action:** README "Dictation shortcut" / "Push-to-talk / toggle" / "Model" / "Launch at login" rows (README.md:71-72,74-75) match `TriggerMode` (hold default) and the model picker; README privacy claims (model + venv under `~/Library/Application Support/Whistral/`, README.md:63-65) match `SidecarEngineClient.appSupportURL` (SidecarEngineClient.swift:50-55) and `CONTRIBUTING.md:23-26`; CONTRIBUTING's `requirements.txt` references match the existing file `Whistral/Resources/Engine/requirements.txt`; CI workflow (`.github/workflows/ci.yml`) matches CONTRIBUTING's build command.

---

## Summary of required corrections

| # | File:line | One-line correction |
|---|-----------|---------------------|
| 1.1 | Whistral/SettingsView.swift:315-317 | About-pane "Model" link should point at the default 6-bit repo (or list both variants) |
| 1.2 | README.md:28 | "~3 GB" → "~4 GB (6-bit) to ~9 GB (BF16) free disk space" |
| 3/R1 | whistral_engine.py:402, 466 | `self.engine.lock` → `self.lock` (Engine has no `engine` attribute; every session currently AttributeErrors) |
| 3/#22 | whistral_engine.py:541 | Drop (or use) the unused `runner` parameter on `handle_command` |
| 3/#17 | TranscriptionController.swift:300, 328 | Compare a token captured *at session start* (or add a protocol token) instead of passing the current `sessionToken` back to itself |
| 4.1 | README.md:71-75 | Add table rows for insert-at-cursor, insertion method, transcription delay, sound feedback |
| 4.2 | README.md:73 | Remove "Cancel with Esc" from the settings table (hardwired behavior, not a setting) |
| 4.3 | README.md:55-56 | Reword insertion description to cover both paste and keystrokes methods |

**Bottom line:** the model-id migration to 6-bit is consistent everywhere it should be; onboarding copy is clean; 23 of 24 review findings are fixed (22 fully, #17 only partially — its token guard is a no-op), #22 remains a nit; and one **new runtime blocker** (whistral_engine.py:402) was introduced by the #7 serialization fix and needs immediate correction.

---

# Round 2 — Docs / CI consistency sweep (2026-11-19 ~22:29 CET)

Scope: README.md, CHANGELOG.md, CONTRIBUTING.md, .github/release/draft-v0.1.0.md, docs/engine-protocol.md, .github/workflows/ci.yml, scripts/package_release.sh, issue templates, cross-checked against code (read-only). Note: code/docs were being edited until 22:26 (engine py); all claims below re-verified against the tree at 22:29 CET, stable.

## Findings table

| # | Mismatch | File | Action taken |
|---|----------|------|--------------|
| V1 | **MARKETING_VERSION is `1.0`, not `0.1.0`** — `Whistral.xcodeproj/project.xcproj:52` `"MARKETING_VERSION": "1.0"`. The 0.1.0 assumption appears in exactly three places: `CHANGELOG.md:14` (`## [0.1.0] — first release`), `.github/release/draft-v0.1.0.md` (filename + title `Whistral 0.1.0` + line 24), and `.github/workflows/ci.yml:49` (artifact name `Whistral-${{ github.ref_name }}` → `Whistral-v0.1.0` if tagged `v0.1.0`). **Actual CI zip name:** `scripts/package_release.sh:47` derives it from MARKETING_VERSION, so the artifact `Whistral-v0.1.0` would today contain **`Whistral-1.0.zip`** — not `Whistral-0.1.0.zip`. | project.xcproj, ci.yml | **Flagged, not changed** (both are code/workflow changes, out of scope per instructions): bump `MARKETING_VERSION` to `0.1.0` before tagging, and/or change the artifact name to a fixed value like `whistral-zip` so it doesn't encode the tag. The draft's install paragraph was corrected (D1) to describe the real naming. |
| D1 | Release draft told users the release job "attaches `Whistral-<version>.zip`" without naming the artifact, and asserted the 0.1.0 name as if already true. | .github/release/draft-v0.1.0.md:24 | **Fixed**: now names both — artifact `Whistral-v0.1.0` (tag-based), zip `Whistral-<MARKETING_VERSION>.zip`, explicitly notes MARKETING_VERSION must be bumped from its current `1.0` to `0.1.0` before tagging. |
| T1 | Bug-report template example stale: `e.g. macOS 15.2 (Sequoia)` while the app requires macOS 27.2+ (README.md:28, CHANGELOG.md:18, deployment target `"MACOSX_DEPLOYMENT_TARGET": "27.2"` project.xcproj:119). Also app-version example `1.2.0` vs the 0.1.0 release. | .github/ISSUE_TEMPLATE/bug_report.md:11,30 | **Fixed**: examples updated to macOS 27.2 (with the requirement noted) and 0.1.0. |
| — | Version claims otherwise agree: README.md:28 "macOS 27.2 or newer" = CHANGELOG.md:18 = draft-v0.1.0.md:16 ("macOS 27.2") = deployment target 27.2; draft-v0.1.0.md:21 "Xcode 27.2 or newer" matches the installed toolchain (Xcode 27.2 / build 27B52). CHANGELOG `[0.1.0]` dated 2026-11-19 (today). | README/CHANGELOG/draft/project.xcproj | Verified, no action. |
| — | Model facts agree everywhere: default id `mlx-community/Voxtral-Mini-4B-Realtime-6bit` (AppModel.swift:20, whistral_engine.py:595, protocol doc §3 table); sizes 3.9 GB 6-bit / ~8.6 GB BF16 / "~4 GB (— ~9 GB BF16)" totals (README.md:29, CHANGELOG.md:18,28, draft-v0.1.0.md:12,16,28-29); 13 languages with the same name list (README.md:17, CHANGELOG.md:29-31, draft:11, OnboardingView); latency claims only in docs/engine-protocol.md (1 token = 80 ms, delayMs default 480, clamp [80, 2400], 480 ms → 6 tokens) — all match whistral_engine.py:614-616 and SettingsStore defaults; no latency numbers anywhere else. | multiple | Verified, no action. |
| — | Commands verified by running the cheap ones: `xcodebuild -list -project Whistral.xcodeproj` → scheme `Whistral`, Debug+Release exist, so README.md:38-39 / CONTRIBUTING.md:10-14 build commands resolve; CONTRIBUTING.md:32-33 venv path exists (`~/Library/Application Support/Whistral/venv/bin/python`) and all requirements.txt deps (voxmlx 0.0.2, mistral-common, huggingface-hub, mlx, numpy) are installed in it (pip show OK); the version-extraction grep from package_release.sh:32-35 runs verbatim and returns `1.0`; `/tmp/hig/whistral-hig-checklist.md` referenced by README.md:89 exists right now (ephemeral — regenerate from repo history if needed). Not executed (expensive/already exercised in CI): full Debug build, `./scripts/package_release.sh`, `python3 Tests/test_engine_e2e.py` (downloads the 3.9 GB model). | README/CONTRIBUTING | Verified, no action. |
| D2 | Bug-report "Model variant used" checkboxes and CONTRIBUTING "6-bit / BF16" wording remain correct; labels `[bug]` / `[enhancement]` are standard GitHub labels and no component list exists anywhere to mismatch against. Issue templates fine otherwise. | .github/ISSUE_TEMPLATE | Verified, no action. |
| — | docs/engine-protocol.md (re-read last, 22:25 copy) matches the fresh engine (22:26) and Swift client (22:12) on: framing (u32-LE length *including* type byte — test_engine_e2e.py:41-42 agrees), command table (load model default, start `token` default 0, stop/cancel inactive-runner echoes, unknown-command error, quit → exit 0), delayMs clamp verbatim, crash-restart backoff (1.5 s, ≤3, NOT reset at spawn — SidecarEngineClient.swift:213 confirms the comment, reset only on ready at :280), token invariant on `final`/`cancelled` (py emits token; Swift `parseEvent` reads `token` only for final/cancelled — SidecarEngineClient.swift:418-420), error-then-final semantics, SAMPLES_PER_TOKEN=1280/80 ms, right-pad 17, left-pad 32, 0.25 s download-progress cadence, `PYTHONUNBUFFERED=1`/`MLX_METAL_PRECOMPILE=1`. E2E-test description (§6) matches the file (baseline + 4 cases, synthetic 440 Hz tone, venv path). | docs/engine-protocol.md | Verified, no action. Minor code-side notes only (not touched): whistral_engine.py:30 docstring shows `{"type": "partial", "token": 42, ...}` but the actual `partial` emit (py:203-206) carries **no** `token`, and Swift ignores it there — docstring, not the doc, is wrong. Also `TranscriptionController` token guards no longer tautological: engine echoes tokens (round-1 #17 resolved); CHANGELOG.md:112-113 claim is now true. |
| — | CHANGELOG code-behavior claims spot-checked against the current code and all hold: GPU worker thread + load queueing (whistral_engine.py:363-400, 534, 608), watchdogs 30 s/45 s/300 s (TranscriptionController), fail-closed focus check + copy-on-failure (TextInserter.swift:34-40, 53; TranscriptionController.swift:360-383), App Sandbox `"ENABLE_APP_SANDBOX": "YES"` (project.xcproj:41), crash-restart cap, hotkey recorder modifier requirement. | CHANGELOG.md | Verified, no action. |
| — | CI release job uploads `build/*.zip` (ci.yml:50) with `if-no-files-found: error`; package script writes exactly one zip at `build/Whistral-<MARKETING_VERSION>.zip:22,47` — path pattern matches. `build/` is gitignored. Comments in ci.yml/package_release.sh accurate (scripts header "build/Whistral-<version>.zip" ✓; JSON+pbxproj format support note ✓ — repo uses project.xcproj). | ci.yml, scripts | Verified, no action. |

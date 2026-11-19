# Whistral — HIG Gap Report: App Icons, Menu Bar Extras, Permissions

Second-pass audit against the three HIG pages that were missing or empty in the first fetch.

**Fetch provenance (important — two pages no longer exist as standalone HIG pages):**

| Requested page | Status on developer.apple.com (fetched 2026-06-era content, current site) | Saved as |
|---|---|---|
| `app-icons` | ✅ Live; fetched via `…/tutorials/data/design/human-interface-guidelines/app-icons.json` | `/tmp/hig/app-icons.md` |
| `menu-bar-extras` | ⚠️ **404 — page retired.** Its content now lives in the "Menu bar extras" section of the **The menu bar** page; that full page was fetched | `/tmp/hig/menu-bar-extras.md` |
| `permissions` | ⚠️ **404 — page removed.** Its guidance (purpose strings, requesting permission, pre-alert screens, handling denial) was folded into the **Privacy** page; that full page was fetched | `/tmp/hig/permissions.md` |
| `customizing-your-app-icon` | ⚠️ **404 — merged into App icons.** Saved as a pointer stub | `/tmp/hig/customizing-your-app-icon.md` |

All four previously-empty/HTML-shell files now contain real extracted text. Also refreshed: `privacy.md` (= the current permissions source), `the-menu-bar.json`/`privacy.json` kept as raw JSON. **Nothing below is guessed; every guidance item cites the fetched pages or a project file.** Rank ≥ "Medium" items are actionable; radii/visual details like the correct macOS 26 icon corner curvature are Apple-template territory (Icon Composer) and are flagged, not specified.

---

## 1. Menu bar extras (status item)

**Files:** `Whistral/MenuBarStatusItemController.swift`, `Whistral/AppDelegate.swift`

### Satisfied (guidance → evidence)

| Guidance (fetched page) | Evidence in Whistral |
|---|---|
| "Consider using a symbol to represent your menu bar extra… both interface icons and symbols use black and clear colors to define their shapes; the system can apply other colors… so it looks good on both dark and light menu bars" | `MenuBarStatusItemController.icon(_:)` uses SF Symbols `mic.fill` / `waveform` via `NSImage(systemSymbolName:)`, which renders as a template image — monochrome, system-recolorable in dark/light/selected states. Icon sized 18 pt inside the 24 pt menu bar height. |
| Accessibility of the extra's meaning | `accessibilityDescription:` set on the icon image ("Whistral — dictating" / "Whistral — on-device dictation"). |
| "Display a menu — not a popover — when people click your menu bar extra. Unless the app functionality… is too complex for a menu, avoid presenting it in a popover." | Status item owns a real `NSMenu` (`item.menu = menu`); nothing is presented in a popover. |
| Menu bar Best practices: "If a menu bar item isn't actionable, disable the action instead of hiding it from the menu." | `populateMenu(_:)` always builds the full item set; `dictation.isEnabled = isEngineReady || !isIdle` and the engine-state item is shown disabled ("Speech engine: …") rather than omitted. |
| Menu items carry keyboard shortcuts; Settings… opens app settings | `Settings…` wired to ⌘,; `Quit Whistral` to ⌘Q; `Start/Stop Dictation` shows the configurable hotkey; frequent first item is dictation toggle. |
| "Let people — not your app — decide whether to put your menu bar extra in the menu bar… consider giving people the option of doing so during setup." (spirit of) | The app is menu-bar-first by design (`LSUIElement`, `setActivationPolicy(.accessory)`), and `OnboardingView.FinishStep` explicitly tells people during setup: "Lives in your menu bar — Whistral appears as a small microphone icon." Discoverability of the extra at setup is covered. |
| "Avoid relying on the presence of menu bar extras." (partially) | Core function (hold-shortcut dictation) works via the global hotkey without touching the status item (`HotkeyController`) — see gap 2 below for the residual risk. |

### Gaps (ranked)

1. **[Medium] No fallback access path if the system hides the extra.** Fetched page: "When menu bar space is constrained, the system prioritizes the display of menus… the system may hide some [extras]… we can't be sure which other menu bar extras people have chosen to display." It recommends "Consider exposing app-specific functionality in other ways, too. For example, you can provide a Dock menu… a Dock menu is always available when your app is running." Whistral runs as an accessory app (no Dock icon), so *all* mouse access collapses into the one status item.
   *Suggested fix:* add a Dock menu (requires switching off `.accessory`, or re-activating only for the menu), and/or add a "Show Whistral status menu" item with an editable keyboard shortcut in Settings.
2. **[Low] No About/version entry.** The App-menu table on the fetched page: "About… Displays the About window… includes copyright and version information." An accessory app has no app menu, and the status-item menu has no equivalent — users have no in-app path to the version/copyright.
   *Suggested fix:* add "About Whistral" (with separator before it, per "Include a separator after the About menu item") to the status-item menu.
3. **[Low] Menu rebuild happens on `menuNeedsUpdate` only.** Correct per current implementation (menu is rebuilt on every open, so the state shown is current) — no gap; recorded so a future popover refactor doesn't regress it.

---

## 2. App icons

**Files:** `Whistral/Assets.xcassets/AppIcon.appiconset/` (classic 10-rectangle bitmap set), deployment target macOS 27.x (`project.xcproj: MACOSX_DEPLOYMENT_TARGET = "27.2"`), `ASSETCATALOG_COMPILER_APPICON_NAME = "AppIcon"`.

Design as rendered: white microphone glyph + sound arcs on an orange vertical gradient, **pre-rounded squircle with a baked-in drop shadow and transparent margins**, exported as flat PNGs.

### Satisfied

| Guidance (fetched page) | Evidence |
|---|---|
| "Embrace simplicity… Find a concept… express it in a simple, unique way with a minimal number of shapes." | Single mic glyph + arcs; nothing else. |
| "Prefer a simple background, such as a solid color or gradient, that puts the emphasis on your primary design" | Plain orange gradient background, no imagery. |
| "Include text only when it's essential" / avoid imperative words | No text at all. |
| "Avoid replicating UI components" / no photos / no Apple hardware | None present. |
| "Provide a visually consistent icon design" with the product's identity | Same microphone motif as the status item and onboarding (`waveform`, `mic`) — coherent brand family. |
| Legacy size ladder present | 16–1024 px at 1x/2x all provided and correctly referenced in `Contents.json` (also verified `icon_256x256.png` == `icon_512x512@2x`-duplicate-file pattern is intentional/conservative, not missing). |

### Gaps (ranked)

1. **[High] Pre-masked rounded corners + transparent margins.** Fetched "Icon shape": "For iOS, iPadOS, and macOS icons, provide square layers so the system can apply rounded corners… Providing layers with pre-defined masking negatively impacts specular highlight effects and makes edges look jagged." Whistral's PNGs bake in the squircle mask and leave margins, so on macOS 26+ the system re-masks and the Liquid Glass specular highlight lands on a double-rounded edge.
   *Suggested fix:* re-export with full-bleed, square, registration-edge artwork (the orange gradient to the canvas edges, no corner alpha, no padding).
2. **[High] Baked-in drop shadow.** Fetched "Visual effects": "Let the system handle blurring and other visual effects… there's no need to include specular highlights, drop shadows between layers, beveled edges, blurs, glows… custom effects are static, whereas the system supplies dynamic ones." The current icon has a soft baked shadow → renders as a double shadow under macOS 26+.
   *Suggested fix:* remove the shadow from the artwork; let the system draw it.
3. **[Medium] Bitmap-only legacy format on a macOS 27 target.** Fetched "Icon formats": "Provide your icon in the Icon Composer format for more flexibility and control. If you provide a bitmap image instead, the system attempts to segment your icon…" Whistral ships only flat PNGs, so segmentation and Liquid Glass treatment are guessed by the system instead of authored.
   *Suggested fix:* author in Icon Composer (bundled with Xcode), export a single `.icon` file, delete the classic `AppIcon.appiconset`, and set `ASSETCATALOG_COMPILER_APPICON_NAME` to the new asset.
4. **[Low] No dark / tinted / mono appearance variants.** Fetched "Appearances" (explicitly covers macOS): "You can design app icon variants for every appearance variant, and the system automatically generates variants you don't provide… keep your icon's core visual features the same." White-on-orange actually adapts well automatically (favorable), so this is polish, not breakage.
   *Suggested fix:* when moving to Icon Composer, annotate default/dark/mono in the same pass — no extra artwork design needed.

*(Positive note: the design choices compare well against "Prefer illustrations to photos… avoid extremely thin line weights and sharp corners" — the glyph is thick-stroked and rounds.)*

---

## 3. Permissions

**Files:** `Whistral/Permissions.swift`, `Whistral/OnboardingView.swift`, `Support/Info.plist`, `Whistral.xcodeproj/project.xcproj`

### Satisfied

| Guidance (fetched Privacy page, which now hosts the old Permissions page's content) | Evidence |
|---|---|
| "Write copy that clearly describes how your app uses the ability… Aim for a brief, complete sentence that's straightforward, specific, and easy to use. Use sentence case, avoid passive voice, and include a period at the end." (Purpose string, exemplified by "The app records during the night to detect snoring sounds.") | `Info.plist → NSMicrophoneUsageDescription`: "Whistral records audio only while you hold the dictation shortcut to turn your speech into text on this Mac." — active, specific, complete sentence with a period. Textbook match to the HIG's good example (and `PermissionsStep` reuses the identical sentence, so the pre-alert copy and the system alert agree). |
| "Request access only to data that you actually need… make your permission requests as specific as possible." | Exactly two permissions: microphone + Accessibility, both essential to the single core feature. No notifications/tracking/contacts/etc. anywhere. |
| "Request permission only when your app clearly needs access… Ideally, wait to request permission until people actually use an app feature that requires access." / "Avoid requesting permission at launch unless the data or resource is required for your app to function." | Requests happen inside a dedicated onboarding "Permissions" step, each with an explicit why ("Needed to observe your shortcut and insert the transcription at your cursor. No other use."), and mic+AX are required for the app to function at all — the HIG's sanctioned exception and its "opportunity to show people why your app needs their permission" case. |
| Pre-alert screens: "Include only one button and make it clear that it opens the system alert… Use a term like 'Continue' or 'Next.'" | The custom screen's footer button is a single "Continue" (and never traps: `canContinue` always returns `true` with an explicit "Never trap the user" comment). |
| Handling denial: "If people deny permission, try to continue to provide some functionality that doesn't require the data or resource" (legacy page rule, preserved in the app) + deep link to the relevant Settings pane | `OnboardingView` never blocks on a denial, and each `PermissionRow` swaps to an "Open Settings" button when denied; `Permissions.openPrivacyPane("Privacy_Accessibility")` deep-links to System Settings (a separate `openAccessibilitySettings()` helper also exists with the system `AXIsProcessTrustedWithOptions` prompt). Status refreshes live via `PermissionMonitor` 1 s polling. |
| "Be transparent about how your app collects and uses people's data." | Welcome step states plainly: "Everything stays on your Mac / Audio is transcribed on this device. No recordings are saved and nothing is sent to a server." |
| "Process data on the device where possible." | Entire pipeline is on-device (Voxtral sidecar engine) — the design goal itself. |
| Privacy/Platform considerations → macOS: "Protect people's data with app sandboxing." | `project.xcproj`: `ENABLE_APP_SANDBOX: YES`. |
| Privacy/Platform considerations → macOS: "Sign your app with a valid Developer ID." | `DEVELOPMENT_TEAM: 6M97BCH9GA`, `CODE_SIGN_STYLE: Automatic` — provisionally satisfied; see gap 3 (verification only, no code change). |

### Gaps (ranked)

1. **[Medium] Row button titled "Allow" on the custom screen.** Fetched pre-alert rule: "using a term like 'Allow' to title the custom screen's button… people can be more likely to choose the alert's allow button without meaning to. Use a term like 'Continue'" — `PermissionRow.statusBadge` titles the mic button "Allow" before the system alert appears.
   *Suggested fix:* rename the pre-alert button to "Continue" (or "Enable Microphone…") — leave "Allow" to the system alert only.
2. **[Low-Medium] Two action buttons on one custom screen.** Strict reading of "Include only one button… Don't include additional actions, unless needed": the Permissions step shows both the mic "Allow" button and an unrelated "Open Settings" deep-link button simultaneously. Practically this is the standard macOS pattern for Accessibility (which has no system alert of its own), so the fix is presentational.
   *Suggested fix:* keep mic + AX rows but make "Open Settings" a small footnote-style link (`.controlSize(.small)`/borderless) so the primary "open the system alert" action is visually singular.
3. **[Info — verify at release] Developer ID signing.** Automatic signing with a team ID satisfies the letter of the guidance today, but a notarized Developer ID build should be verified when Whistral ships outside the App Store.
   *Suggested fix:* confirm the archive uses "Developer ID Application" + notarization before distribution (build-settings check, no source change).
4. **[Info] `Permissions.openAccessibilitySettings()` (the `AXIsProcessTrustedWithOptions(prompt: true)` variant) is defined but unused on the onboarding path.** Dead-but-harmless; useful as the system-prompt fallback if the Settings deep link ever breaks.
   *Suggested fix:* none required; optionally wire it into the Settings screen as a secondary entry point.

---

## Bottom line — top actionable gaps

1. **App icon must be re-authored for the current macOS icon pipeline** (biggest user-visible gap): full-bleed square layers, no baked shadow, ideally a single Icon Composer `.icon` with dark/mono variants. Gaps 1–3 in §2, fixable in one Icon Composer pass.
2. **Rename the onboarding mic button from "Allow" to "Continue"** — cheap fix that removes the App Review–sensitive manipulation pattern the HIG explicitly calls out.
3. **Give the app a non-menu-bar fallback path** (Dock menu and/or shortcut to reveal the status menu) so silencing/hiding of the extra can't strand the user.

Nothing in this report was guessed: every HIG item cites the fetched pages now in `/tmp/hig/`, and the two retired page URLs (permissions, menu-bar-extras as standalone slugs) are flagged rather than reconstructed from memory.

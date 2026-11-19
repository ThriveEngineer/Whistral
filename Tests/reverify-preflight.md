# Whistral — Release Preflight (independent verification)

Date: 2026-11-19 · Mode: verification only — **no edits to project files, no commits**.
All checks performed against the *built app* and *executed engine*, per brief.

## Summary table

| Check | Result | Evidence |
|---|---|---|
| 1a. Built app `CFBundleShortVersionString` = 0.1.0 | 🟢 PASS | PlistBuddy: `0.1.0` |
| 1a. Built app `CFBundleVersion` = 0.1.0 | 🔴 **FAIL — reads `1`** | PlistBuddy: `1`; root cause `CURRENT_PROJECT_VERSION: "1"` (project.xcproj:39) |
| 1b. `codesign -dvv` valid **adhoc** signature | 🟡 valid signature, **not adhoc** | dev-signed: "Apple Development: Antje Schröder (KL3A8Q7H55)", TeamID 6M97BCH9GA; `codesign -v --deep --strict` → OK |
| 1c. Entitlements contain NO `com.apple.security.app-sandbox` | 🟢 PASS | entitlements = only `files.user-selected.read-only` + `get-task-allow`; project `ENABLE_APP_SANDBOX: NO` |
| 2a. `python3 -m py_compile whistral_engine.py` | 🟢 PASS | clean, no output (exit 0) |
| 2b. `Tests/test_engine_e2e.py` → 6/6 PASS, exit 0, clean stderr | 🟢 PASS | baseline, case 1, 2, 3a, 3b, 4 all PASS; engine stderr empty throughout |
| 3. Cold-process load ~1 s, no gross regression vs 1.07 s claim | 🟢 PASS | boot 0.42 s, load **1.276 s** → `modelState(ready)`; e2e's own fresh load also ~1 s (2 dots) |
| 4. Untracked list free of scratch debris | 🟢 PASS | every entry is an intentional deliverable (details below) |

## Details

### 1. Built app — one red flag + one spec mismatch

App: `…/DerivedData/Whistral-gifyfkygglfhbnfwvrvjzvhzuiju/Build/Products/Debug/Whistral.app`
(build is current: Info.plist already carries the new marketing version).

- **CFBundleShortVersionString = `0.1.0`** ✅ — matches the MARKETING_VERSION bump at
  `Whistral.xcodeproj/project.xcproj:52` (`"MARKETING_VERSION": "0.1.0"`).
- **CFBundleVersion = `1`** ❌ per the stated requirement ("both must read 0.1.0").
  This is not a stale build: the project file sets `"CURRENT_PROJECT_VERSION": "1"`
  (project.xcproj:39) and `GENERATE_INFOPLIST_FILE: YES` stamps it verbatim. If the
  intent really is 0.1.0/0.1.0, set CURRENT_PROJECT_VERSION to 0.1.0 and rebuild; if 1
  is the intended *build number*, then the preflight requirement itself should say
  0.1.0/1 — either way this needs a decision before commit.
- **Code signature: valid but NOT adhoc.** `codesign -dvv` shows a real development-identity
  signature (Authority `Apple Development: Antje Schröder (KL3A8Q7H55)`, TeamIdentifier
  `6M97BCH9GA`, hardened runtime flag 0x10000, `CodeDirectory flags=0x10000(runtime)`),
  and `codesign -v --deep --strict` passes. So the signature is *stronger* than adhoc and
  unambiguously valid — but it does not match the "adhoc" expectation in the brief
  (CODE_SIGN_STYLE Automatic + DEVELOPMENT_TEAM explains why). Not a functional blocker;
  flagged so the release isn't signed into distribution under the wrong assumption.
- **No sandbox entitlement** ✅. Dump contains only
  `com.apple.security.files.user-selected.read-only` (readonly user-file access) and
  `get-task-allow` (debug builds; expected in Debug). `com.apple.security.app-sandbox` is
  absent, consistent with `ENABLE_APP_SANDBOX: NO`.

### 2. Engine verification

- `python3 -m py_compile Whistral/Resources/Engine/whistral_engine.py` → exit 0, no
  diagnostics. (`__pycache__` output is covered by .gitignore — no hygiene impact.)
- `Tests/test_engine_e2e.py` (run from `Tests/` with
  `~/Library/Application Support/Whistral/venv/bin/python`): **6/6 PASS, exit 0**:
  1. baseline load→start→audio→stop→final(token=42)
  2. case 1: cancel echoes session token
  3. case 2: load-during-session doesn't wedge the reader; engine stays responsive
  4. case 3a: AST tripwire — every literal final/cancelled emit carries `token`
  5. case 3b: session survives a failed worker load, echoes its token
  6. case 4: no tokenless final/cancelled anywhere in the run
- stderr (app + engine) empty on every failure-capable path; nothing to capture.
- Note (informational, not a failure): the "cached" load emitted two
  `modelState: downloading` events (received 1→4, total 4). Engine stderr shows this is
  huggingface_hub metadata **revalidation** ("Fetching 4 files … 4372 it/s", cached, ~0 ms),
  not a re-download.

### 3. Cold-process model load

Fresh engine process (dedicated timing run, not the bench — perf-report.md untouched):
boot (spawn → `ready`) **0.42 s**; load cmd → `modelState(ready)` **1.276 s**. Consistent
with the 1.07 s claim in `Tests/perf-report.md` and with the e2e run's fresh load (~1 s).
**No gross regression**; spread across today's three cold loads: 0.99–1.28 s. Caveat worth
a release note: the cached load performs a network metadata check against HF and surfaces
transient `downloading` events on a warm install; fully offline behavior of that check
is untested.

### 4. Repo hygiene — untracked inventory (nothing deleted, nothing looks like debris)

| Entry | Verdict |
|---|---|
| `.github/release/draft-v0.1.0.md` | intentional (this release's draft notes) |
| `CHANGELOG.md` | intentional |
| `Tests/bench_latency.py`, `Tests/perf-report.md` | intentional (deliverables, reviewed earlier today) |
| `Tests/review-findings.md`, `Tests/review-findings-2.md`, `Tests/reverify-report.md`, `Tests/reverify-perf-notes.md`, `Tests/consistency-sweep.md`, `Tests/hig-gap-report.md` | intentional audit reports (findings-2 is the second review round on the worker-refactor) |
| `Tests/screenshots/` | intentionally excluded from commit per brief — left untouched |
| `docs/` (engine-protocol.md, branding/ logo PNGs) | intentional documentation |
| `scripts/package_release.sh` | intentional release tooling |
| `Whistral/AppIcon.icon/` (icon.json + Assets/) | Xcode icon-format asset — intentional |

No `.DS_Store`, no `__pycache__`, no editor droppings, no stray temp files. Nothing
suspect to act on.

## Verdict

**One red item must be resolved before commit:** the app's `CFBundleVersion` reads `1`,
not `0.1.0` (project.xcproj:39) — fix the setting and rebuild, or consciously relax the
requirement. The signature question (dev-signed vs the expected adhoc) is flagged for a
decision but is not a defect. Everything else — versions, no-sandbox entitlements, engine
compile, 6/6 E2E, ~1.2 s cold load, repo hygiene — is green.

---

## Follow-ups (2026-11-19, later)

- **CFBundleVersion red → RESOLVED (project-side).** `CURRENT_PROJECT_VERSION` was changed
  `"1"` → `"0.1.0"` at `Whistral.xcodeproj/project.xcproj:39` (aligned with
  `MARKETING_VERSION` at :52). The *built* app in DerivedData has NOT been re-verified —
  no builds were performed for this follow-up; the rebuild check is deferred to the commit
  gate as agreed.
- **Signature flag → RESOLVED as keep-dev-identity.** Decision: the development-identity
  signature stands (stronger than adhoc; `codesign -v --deep --strict` passes;
  TeamIdentifier 6M97BCH9GA, hardened runtime). No action needed.
- **Offline-revalidation note:** stays informational. One clarifying sentence, believed
  accurate for 0.1.0: the cached-load HF metadata check (which produces the transient
  `downloading` events on warm installs) requires network connectivity, and full-offline
  engine-launch behavior has never been tested — acceptable to ship unstated in 0.1.0
  docs.

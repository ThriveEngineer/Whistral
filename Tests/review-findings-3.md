# Whistral — Round 3 Findings (closing out review-findings-2.md)

Round 3 scope: re-verify open items #2, #8, #10 from `Tests/review-findings-2.md` against
the current working tree; give each a verdict — **(a) fully resolved**, **(b) partially
resolved with residual risk**, or **(c) still open** — with the exact code the verdict rests
on, and a one-pass patch recommendation for anything still open. No files were edited; no
commits made. (For reference on quoted line numbers: they refer to the current working tree,
which has shifted vs. round 2 because of the worker-thread/FLUSHING rework.)

> **No blocker-class bug was found in this round.** The FLUSHING registry is race-sound for
> the command-reader thread that owns it; the residual items below are minor.

## Confirmations (fixed items, spot-checked in code)

- **#1 (write-after-death pipe crash)** — fixed: `signal(SIGPIPE, SIG_IGN)` at process start
  (SidecarEngineClient.swift:83), posix `Darwin.write(handle.fileDescriptor, …)` with EPIPE
  handled as `return false` on the writeQueue (SidecarEngineClient.swift:374–379), handle
  invalidation funneled through `writeQueue` (343–344). No `FileHandle.write` remains on the
  frame path.
- **#3 (watchdog vs. long loads)** — fixed: re-arming, progress-aware pending-start watchdog
  (TranscriptionController.swift:42, 157–175; `.loading/.downloadingModel` re-arms at 356–359).
- **#4 (insert() always true)** — fixed: `type()`/`paste()` return real outcomes, pasteboard
  write failure restores and returns `false` (TextInserter.swift:91, 129, 159, 173).
- **#9 (onInterrupted assigned late)** — fixed: assigned before `audio.start()` with an
  explicit ordering comment (TranscriptionController.swift:197–204).

---

## Round 3 verdicts

### Finding #2 — mid-flush cancel unreachable / session-event cross-talk — verdict: (b) PARTIALLY RESOLVED, residual risk is minor

**What is now fixed.** The FLUSHING registry makes the previously-unreachable mid-flush cancel
live. Quotes from `Whistral/Resources/Engine/whistral_engine.py`:

- L596–603 (registry + prune):
  ```python
  RUNNER = None
  # Sessions that were stopped or cancelled but whose worker job may still be
  # flushing. … Pruned by the finished event.
  FLUSHING = []
  def _prune_flushing() -> None:
      FLUSHING[:] = [r for r in FLUSHING if not r.finished.is_set()]
  ```
- L643–646 (`stop` parks the runner instead of losing it):
  ```python
  elif action == "stop":
      if RUNNER is not None:
          RUNNER.stop()
          FLUSHING.append(RUNNER)
          RUNNER = None
  ```
- L648–659 (`cancel` reaches parked, still-running decoders — the round-2 hole):
  ```python
  elif action == "cancel":
      _prune_flushing()
      if RUNNER is not None:
          RUNNER.cancel()
          FLUSHING.append(RUNNER)
          RUNNER = None
      # A cancel that arrives while a previous session is still flushing
      # (Esc during .finalizing) kills that flush via the decode-loop poll.
      for r in FLUSHING:
          if not r.finished.is_set():
              r.ctl["cancel"] = True
  ```
- The poll the loop arms is real and covers the flush decode path: L186–187
  (`if self._killed.is_set() or (self.should_cancel and self.should_cancel()): raise
  SessionKilled()`), wired at L451–452 (`stream.should_cancel = lambda: bool(…ctl.get…)`),
  consulted by both decoding calls — L286 (streaming pump) and L322 (`flush()`'s
  decode_steps). A killed flush lands in `except SessionKilled` at L509–510:
  `emit({"type": "cancelled", "token": token})` — correct for Swift (token matches the
  still-current session when Esc-during-`.finalizing`, so it resets; harmless and
  token-dropped if a newer session exists).
- Token echoes are present on every terminal emit: `cancelled` at L447 and L510, `final` at
  L492 (pump-error), L506 (flush), L514 (outer error — plus the error event itself at L513),
  L569 (defensive stop echo), L585 (defensive cancel echo); `sessionStarted` L454;
  `segment` L484. Cross-session clobber of `final`/`cancelled` is therefore closed
  (Swift guards: TranscriptionController.swift:319/331 token checks).
- Also verified sound: `finished` is set in `_job`'s `finally` (L545–549) even when the
  worker-loop's own exception handler fires, so prune can't leak a parked runner; every
  entry into the registry is reader-thread-only (single command thread), so
  `FLUSHING[:]`/`ctl[...]` mutations are race-free.

**Residual risk (minor) — tokenless `partial` events can bleed a dead session's text into a
live one.** `decode_steps` still emits `partial` without any token (L199–205):

```python
emit({
    "type": "partial",
    "index": len(self.session_segments),
    "segmentText": self.segment_text,
    …
})
```

and the `_killed.clear()` at L307/`flush()` restarts partial flow inside the flush tail.
Scenario: stop session A (Swift `.finalizing`), user immediately starts B (Swift
`.recording`, B's job queued behind A's flush worker job); A's flush-tail `partial`s arrive
while Swift is in `.recording`, pass the phase-only guard (TranscriptionController.swift:
326–329), and overwrite B's `currentText`/HUD with A's text until B's own job starts and
B's partials correct it. No wrong insertion happens (insertion uses the token-checked
`final`), so this is a transient HUD/text-display glitch — but it is the one session event
type the token design skipped.

**Patch recommendation (residual of #2) — engine-only, one pass.** Swift already ignores
`partial` during `.finalizing`, so A's flush-tail partials are useful to no one:

✅ RESOLVED (fixer round 11): exactly this patch applied to
`whistral_engine.py` — `self.emit_partials = True` in `__init__` (:144), the
partial `emit(...)` wrapped in `if self.emit_partials:` (:206-213), and
`self.emit_partials = False` right after `flush()`'s `self._killed.clear()`
(:313). Verified: py_compile OK; E2E suite 6/6 PASS, exit 0.

- File `Whistral/Resources/Engine/whistral_engine.py`, class `VoxtralStream`:
  1. In `__init__` (near L140, next to `self.should_cancel = None`) add:
     `self.emit_partials = True`
  2. In `decode_steps`, wrap the partial `emit({...})` (L201–207) in
     `if self.emit_partials:`
  3. In `flush()` (L305, right after `self._killed.clear()` at L307) add:
     `self.emit_partials = False  # flush-tail partials are ignored by the app; a new
     session may already be recording (partials carry no token)`
- No Swift change needed; hoisting `partial` into the token protocol (engine + Swift) is a
  heavier alternative with the same effect — not recommended now.

---

### Finding #8 — `quit` with in-flight job: no cancel on the way out — verdict: (c) STILL OPEN

The rework did not touch the shutdown path. Quotes from the current file:

- L678–679 — the quit command still just returns:
  ```python
  elif action == "quit":
      return False
  ```
- L715–717 — the EOF path still cancels only the live `RUNNER`, not parked ones:
  ```python
  # App is gone; stop cleanly.
  if RUNNER is not None:
      RUNNER.cancel()
  return
  ```
- L720–724 — `main()` still relies on interpreter teardown:
  ```python
  try:
      read_frames()
  finally:
      sys.exit(0)
  ```

Same consequence as round 2: on quit, a flushing/streaming worker job is never asked to
stop; `sys.exit(0)` blocks until the in-flight MLX/Metal C call returns (bounded by one op,
but a decode sequence can be many ops back-to-back — the decode-step loop only exits
between steps, and nothing tells it to).

**Patch recommendation (one pass) — file `Whistral/Resources/Engine/whistral_engine.py`:**

1. In `handle_command`, replace L678–679 with:

   ```python
   elif action == "quit":
       # Ask all live/parked decode loops to stop; each poll interval is one
       # MLX step, so interpreter shutdown waits at most one in-flight op.
       if RUNNER is not None:
           RUNNER.cancel()
       for r in FLUSHING:
           if not r.finished.is_set():
               r.ctl["cancel"] = True
       return False
   ```

2. In `read_frames`, extend the EOF branch (L714–717) symmetrically:

✅ RESOLVED (fixer round 11): both branches applied verbatim to
`whistral_engine.py` — the `quit` branch now cancels `RUNNER` and sets
`ctl["cancel"]` on unfinished `FLUSHING` entries before `return False`
(:684-692), and the EOF branch does the same before `return` (:707-713). No
joins added; reader stays unblocked. E2E suite still 6/6 PASS, exit 0.

   ```python
   # App is gone; stop cleanly.
   if RUNNER is not None:
       RUNNER.cancel()
   for r in FLUSHING:
       if not r.finished.is_set():
           r.ctl["cancel"] = True
   return
   ```

   (Strictly optional for EOF — the process exits anyway — but it makes the cancellation
   intent uniform and costs three lines.)

No `join` is added anywhere: the decode-step polls make the worker finish promptly, and
joining from the reader thread would recreate the round-2 reader-blocking problem the
worker-queue refactor removed.

---

### Finding #10 — `lastTranscript` clobbered by empty abort finals — verdict: (c) STILL OPEN

The coincidental rework reordered the stop-sound but not the transcript assignment. Quotes
from `Whistral/TranscriptionController.swift` (current `insertFinalText`, L377–432):

- L383–385 — `lastTranscript` still set before the emptiness check:
  ```swift
  AppModel.shared.lastTranscript = text
  AppModel.shared.recordTranscript(text)
  let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
  ```
- Engine-side triggers unchanged, e.g. the outer-error terminal emit at
  `whistral_engine.py:513–514` (`emit({"type": "error", …})` then
  `emit({"type": "final", "text": "", "token": token})`): any aborted session whose final
  text is empty overwrites `lastTranscript` with `""`, and `recordTranscript` (which guards
  `!text.isEmpty`) can't compensate because `lastTranscript` was already clobbered.

**Patch recommendation (one pass) — file `Whistral/TranscriptionController.swift`,
`insertFinalText`:** delete L383 (`AppModel.shared.lastTranscript = text`), keep
`recordTranscript` as is, and insert after L385 (`let trimmed = …`):

```swift
// Only current, non-empty finals become "the last transcript"; empty abort
// finals (engine error paths) must not clobber the previous good one.
if !trimmed.isEmpty {
    AppModel.shared.lastTranscript = trimmed
}
```

Using `trimmed` (not raw `text`) also matches the copy-fallback text further down.

✅ RESOLVED (fixer round 11): the unconditional `lastTranscript = text` line is
deleted and the guarded assignment uses `trimmed`
(TranscriptionController.swift:411-417, assignment at :416). `recordTranscript`
unchanged. xcodebuild Debug: BUILD SUCCEEDED, zero warnings.

---

## Summary of round 3

| Round-2 item | Verdict | Action needed |
|---|---|---|
| #1 pipe write-after-death | **Fixed** (verified: SIG_IGN + posix write + EPIPE path) | none |
| #2 mid-flush cancel / token registry | **(b) Partially resolved** — cancel now reaches parked decoders via FLUSHING; residual: tokenless `partial` can bleed stale text into a new session's HUD | optional 4-line engine patch above (silence partials during flush) |
| #3 pending-start watchdog vs. long loads | **Fixed** (progress-aware re-arming) | none |
| #4 insert() failure reporting | **Fixed** (real `Bool` outcomes; pasteboard refused-write restores) | none |
| #8 quit/EOF doesn't cancel worker jobs | **(c) Still open** | 2-part engine patch above |
| #9 onInterrupted ordering | **Fixed** (assigned before `audio.start()`) | none |
| #10 empty abort finals clobber `lastTranscript` | **(c) Still open** | 3-line Swift patch above |

No edit was made to any project file; the only writes this round are this report.

---

# Round 4 verification (fixer rounds 10–11 + hud D1–D4) — independent, read-only

Date: 2026-11-19. No project file was edited this round; this section and the
xcodebuild run into DerivedData are the only writes. Current-source line numbers
were re-derived from the files (not trusted from the fixer notes).

## 1. Finding #2 residual — engine-side `emit_partials` — **GREEN**

Verdict: fully resolved (the round-3 residual: tokenless `partial` events from a
stopped session's flush-tail decode could bleed stale text into a new session's HUD).

Traced flow, all in `Whistral/Resources/Engine/whistral_engine.py`:

- **Per-instance, not global.** `VoxtralStream.__init__` :143–144:
  `self.emit_partials = True`. `grep -n emit_partials` over the whole file yields
  exactly three sites (:144 True, :206 guard, :313 False) — there is no module-level
  flag and no other way to set it back to True.
- **Silenced before decode.** `flush()` :312–313 sets `self._killed.clear()` then
  `self.emit_partials = False` immediately, and only afterwards calls
  `decode_steps(...)` (:322–333). So flush-tail partials are suppressed from the
  first decode step.
- **Guarded emit.** `decode_steps` :206–213: `if self.emit_partials: emit({... partial ...})`.
- **No cross-contamination.** A new session creates its *own* `VoxtralStream` inside
  `_stream_session` (:455), and the single FIFO worker runs jobs in order — an old
  flush completes before the next session's job starts (further serialized by
  `self.lock` at :439). Any concurrent FLUSHING entry carries its own runner with its
  own VoxtralStream/flag: a new session can never set the OLD runner's flag True
  mid-flush, because `emit_partials = True` is only ever written in `__init__`, and
  the silencing writes `self.emit_partials = False` on the old instance's own object.
- The flag can't be "set True while a flush is mid-decode of an old runner": nothing
  in the file assigns `True` again after `__init__`.

## 2. Finding #8 — quit/EOF cancellation — **GREEN (mechanics), one CAVEAT**

Quote check, current file:

- `handle_command` quit branch :683–691: `if RUNNER is not None: RUNNER.cancel()`,
  then `for r in FLUSHING: if not r.finished.is_set(): r.ctl["cancel"] = True`,
  then `return False`. ✅ symmetric with `cancel`.
- EOF branch (`read_frames`, :706–713): identical cancel of `RUNNER` plus the
  `FLUSHING` loop before `return`. ✅
- No `join` anywhere (grep: only `str.join` string joins and the :583 comment).
  The reader stays unblocked. ✅
- Quit while a flush decodes: `ctl["cancel"]=True` → decode-loop poll
  (:186–187 `if self._killed.is_set() or (self.should_cancel and self.should_cancel())`)
  raises `SessionKilled` inside `flush()` → caught at :509–510
  (`except SessionKilled: emit({"type": "cancelled", "token": token})`), which is a
  terminal, token-bearing event. ✅ in code.

**CAVEAT (not a regression, low impact, but the guarantee is weaker than it looks):**
the emit at :509–510 runs on the worker thread, which is created with
`daemon=True` (:395–399). After `handle_command` returns False, `read_frames`
returns and `main()`'s `finally: sys.exit(0)` (:721–724) triggers interpreter
finalization; a daemon thread that is inside an MLX C call (GIL released) and
re-acquires the GIL after finalization starts is terminated *without* running its
Python continuation — i.e. the `except SessionKilled: emit(cancelled)` in :511-512
typically never executes for a quit arriving mid-decode. The `emit` exists, but
delivery is best-effort. Impact ≈ zero (the app is quitting and
SidecarEngineClient doesn't depend on that event to exit); the patch's real goal —
stop the decode so shutdown is prompt — IS achieved.

*Optional hardening (one pass, engine-only):* in `main()`'s `finally`, before
`sys.exit(0)`, add a bounded grace join —
```python
finally:
    w = ENGINE._worker
    if w is not None:
        w.join(timeout=2.0)  # decode polls exit within one MLX op; bounded
    sys.exit(0)
```
This is *after* the reader loop, so it does not reintroduce the round-2
reader-blocking problem the patch deliberately avoided.

## 3. Finding #10 — `lastTranscript` clobber — **GREEN**

`Whistral/TranscriptionController.swift`, `insertFinalText`:

- The unconditional `AppModel.shared.lastTranscript = text` is gone (grep shows the
  only assignment is :416, inside the guard).
- :410–417: `AppModel.shared.recordTranscript(text)` unchanged,
  `let trimmed = text.trimmingCharacters(...)` (:411), then
  `if !trimmed.isEmpty { AppModel.shared.lastTranscript = trimmed }` (:415–417).
- `recordTranscript` itself still guards `!text.isEmpty` (`AppModel.swift:177–183`),
  recents flow unaffected. HUD/insertion flows below (:419–447) match the round-3
  baseline semantics. ✅
  (Minor note, unchanged behavior: `recordTranscript(text)` receives the *untrimmed*
  text, while `lastTranscript` now stores the *trimmed* one. Harmless — engine finals
  are already space-joined — just an observation, not a defect.)

## 4. hud-polish D1–D4 — **ALL GREEN**

- **D1 — GREEN.** `beginCapture` catch, `TranscriptionController.swift:218–225`:
  `let token = sessionToken` captured at throw time; the 2.0 s closure guards
  `self.sessionToken == token, self.phase == .idle` before `hud.hide()`.
  Resolved-note's :221-226 matches reality within ±1 line.
- **D2 — GREEN.** `HUDController.swift`: `isFadingOut` declared :28, set at
  :63 in `hide()`, cleared at :73 in the completion (after the gen-guarded
  `orderOut` :71–72) and at :133 in presentPanel's fresh branch. Fresh branch
  (:121–140) always bumps `generation` (:129) and refreshes contentSize/anchor
  (:130–131), but restarts the fade (alpha 0 → orderFront → fade-in :134–139) only
  when `!panel.isVisible || isFadingOut` (:132) — a fully-visible panel is resized
  and re-anchored with no alpha dip: no blink. The generation bump + gen-guard in
  `hide()`'s completion (:71) is preserved.
  - `MainActor.assumeIsolated` at :71 and :73 — warning-free confirmed by the
    independent build below; and semantically correct: the completion runs on the
    main thread (AppKit animation context), the gen read at :71 is side-effect-free,
    and the :73 mutation is wrapped. One theoretical residual: `showTranscribing()`
    (:51–54) uses the non-fresh `presentPanel()` and would not bump `generation`
    during an in-flight fade-out (a stale hide completion could then order the panel
    out at :72). Not reachable in current controller flow (every re-show after
    `hide()` goes through `showListening()` → `anchorFresh: true`), so recorded as
    observation only, not a defect.
- **D3 — GREEN.** `NSAlert.runModal` / `PermissionHotkeyBridge` /
  `Whistral.needsAccessibility` are gone (repo-wide grep: only a doc comment at
  :301 mentions the old behavior). Replaced by
  `TranscriptionController.showNeedsAccessibility()` (:303–316): passive HUD
  message + non-modal 2.5 s hide guarded by
  `sessionToken == token && phase == .idle` (:311–315). No activation, no modal.
- **D4 — GREEN (as scoped).** `insertFinalText` failure branch :441–447:
  `hud.showListening()` then `hud.micLevel = 0` (:443 — flat bars, not frozen),
  clipboard-copy message, and the 3.0 s hide guarded by
  `sessionToken == hideToken && phase == .idle` (:445–447). The Esc-hint variant is
  documented as deliberately out of scope (hud-regression.md D4 note) — accepted.
- **Sound hoist intact.** `if !insertionFailed { SessionSounds.maybePlayStop(...) }`
  at :427–431 — round-10's hoist was not broken by the D1–D4 pass.
- **anchorFresh generation bump intact.** :129 (`generation += 1`) inside the
  `!panel.isVisible || anchorFresh` branch, before the conditional fade reset.

## 5. Independent build check — **GREEN**

`xcodebuild -scheme Whistral -project Whistral.xcodeproj -configuration Debug
build CODE_SIGNING_ALLOWED=NO` → `** BUILD SUCCEEDED **` with zero Swift/clang
compiler warnings. (The only "warning" lines in the log are xcodebuild's
destination-selection note and appintentsmetadataprocessor's "no AppIntents
dependency" tool message — not compiler warnings, present on any project without
AppIntents.) This independently confirms the zero-warning claim, including that
D2's `MainActor.assumeIsolated` closure compiles clean under
`SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor`.

## 6. Regression sweep — **NO BLOCKER**

Checked for things the D1–D4 / round-11 passes could have broken worse than
baseline: token echo on `cancelled` in the flush/kill path still present
(:509–510, :551–552, :585); `FLUSHING` pruning on `start`/`cancel`
(`_prune_flushing` at :597–598, used :637/:647); no thread joins introduced;
`onInterrupted` still assigned before `audio.start()` (:211–212); pending-start
watchdog re-arm on `modelState` progress (:393–400). One observation-only item
recorded under D2 above; one caveat under #8 with an optional one-pass hardening.
No green item regressed, nothing worse than baseline.

## Round 4 verdict table

| Item | Verdict | One-line rationale |
|---|---|---|
| #2 `emit_partials` residual | 🟢 GREEN | Flag is per-VoxtralStream (:144), silencing pre-decode (:313) and guarded (:206); only three sites in file, no cross-contamination |
| #8 quit/EOF cancel | 🟢 GREEN | Symmetric quit (:683–691) and EOF (:706–713) cancel RUNNER + FLUSHING, no joins, reader unblocked |
| #8 sub-case: terminal event on quit-mid-flush | 🟡 CAVEAT | `cancelled` emit exists (:509–510) but the daemon worker is typically frozen at interpreter finalization before it runs; impact nil while quitting — optional bounded `main()` grace join given |
| #10 `lastTranscript` | 🟢 GREEN | Only assignment is the `!trimmed.isEmpty`-guarded one (:415–417); `recordTranscript`/HUD flows unchanged |
| D1 | 🟢 GREEN | Token+phase-guarded 2.0 s hide at :218–225 |
| D2 | 🟢 GREEN | `isFadingOut` (:28/:63/:73/:133) — no blink on visible panel; gen bump + assumeIsolated completion preserved (:71–73/:129), build warning-free |
| D3 | 🟢 GREEN | runModal/notification/bridge gone; passive HUD message + guarded 2.5 s hide (:303–316) |
| D4 | 🟢 GREEN | `hud.micLevel = 0` flat bars + guarded delayed hide (:443–447); Esc-hint variant documented as out of scope |
| Sound hoist / anchorFresh bump | 🟢 GREEN | :427–431 and :129 intact after the D-pass |
| Build | 🟢 GREEN | Independent zero-warning BUILD SUCCEEDED |

**BLOCKER: none.**

## Round 5 resolution — #8 optional hardening landed (fixer round 12)

✅ RESOLVED (fixer round 12): the optional bounded grace join from the round-4
snippet is applied to `main()`'s `finally` in `whistral_engine.py` (:736–744):
`w = ENGINE._worker; if w is not None: w.join(timeout=2.0)` before
`sys.exit(0)`. Bounded (2 s), reader-independent (runs only after the reader
loop ends), no unbounded joins anywhere. The #8 sub-case caveat above is closed:
a quit/EOF mid-decode now gives the daemon worker up to 2 s to run its
`except SessionKilled: emit(cancelled)` terminal emit before finalization.

Verified: py_compile OK; Tests/test_engine_e2e.py 6/6 PASS, exit 0; incremental
xcodebuild Debug BUILD SUCCEEDED, zero warnings. Backup: /tmp/whistral_engine.py.fixer-r12.

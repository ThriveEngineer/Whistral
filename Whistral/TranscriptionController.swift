//
//  TranscriptionController.swift
//  Whistral
//
//  Orchestrates a dictation session: hotkey → HUD → audio capture → engine
//  streaming → final text insertion.
//

import AppKit
import Combine
import Foundation

@MainActor
final class TranscriptionController: NSObject, ObservableObject {

    // MARK: - Dependencies

    let hud = HUDController()
    let audio = AudioCaptureEngine()
    let engine: SidecarEngineClient
    private let settings: SettingsStore

    // MARK: - State

    enum SessionPhase: Equatable {
        case idle
        case starting
        case recording
        case finalizing
    }

    @Published private(set) var phase: SessionPhase = .idle
    /// Bumped on every start; stale engine events are ignored.
    private var sessionToken = 0

    /// Latest full text of the current dictation (all segments so far).
    private var currentText = ""
    /// Set when Esc was pressed during recording/finalizing.
    private var cancelled = false
    /// Queued start while the engine is still loading.
    private var pendingStart = false
    /// Re-arm counter for the pending-start watchdog (bumped on modelState
    /// progress so a long download doesn't drop a queued session).
    private var pendingStartWatchdogEpoch = 0
    /// Bundle ID of the app that was frontmost when capture began, so we can
    /// detect focus changes before pasting.
    private var captureFrontmostBundleID: String?

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Sound feedback

    /// Subtle start/stop cues played at session boundaries, per HIG feedback
    /// guidance. Uses standard system sounds only — no bundled assets.
    /// Cancel stays silent on purpose: dropping a dictation needs no fanfare.
    private enum SessionSounds {
        private static var startSound: NSSound? = NSSound(named: NSSound.Name("Tink"))
        private static var stopSound: NSSound? = NSSound(named: NSSound.Name("Pop"))

        static func playStart() { startSound?.play() }
        static func playStop() { stopSound?.play() }

        static func maybePlayStart(enabled: Bool) {
            guard enabled else { return }
            playStart()
        }

        static func maybePlayStop(enabled: Bool) {
            guard enabled else { return }
            playStop()
        }
    }

    init(engine: SidecarEngineClient, settings: SettingsStore) {
        self.engine = engine
        self.settings = settings
        super.init()
        wireObservers()
    }

    private func wireObservers() {
        audio.onAudio = { [weak self] samples in
            guard let self, case .recording = self.phase else { return }
            self.engine.sendAudio(samples: samples)
        }
        audio.onLevel = { [weak hud = self.hud] level in
            hud?.reportRawLevel(level)
        }

        NotificationCenter.default.publisher(for: NSNotification.Name("Whistral.escPressed"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.cancel() }
            .store(in: &cancellables)
    }

    // MARK: - Hotkey entry points

    func hotkeyDown() {
        switch settings.triggerMode {
        case .hold:
            startSession()
        case .toggle:
            if phase == .recording || phase == .starting {
                stopSession()
            } else if phase == .idle {
                startSession()
            }
        }
    }

    func hotkeyUp() {
        guard settings.triggerMode == .hold else { return }
        if phase == .recording || phase == .starting {
            stopSession()
        }
    }

    // MARK: - Session lifecycle

    func startSession() {
        guard phase == .idle else { return }
        guard Permissions.microphone == .granted else {
            requestMicrophoneThenStart()
            return
        }
        guard Permissions.accessibility == .granted else {
            showNeedsAccessibility()
            return
        }

        currentText = ""
        cancelled = false
        sessionToken += 1

        switch AppModel.shared.engineState {
        case .ready:
            beginCapture()
        case .loading, .bootstrapping, .downloadingModel:
            // Engine is warming up; queue the session to start when ready.
            queuePendingStart()
        case .error(let message):
            hud.showListening()
            hud.update(text: "Engine error: \(message). Check the Engine pane in Settings.")
            phase = .starting
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                if self?.phase == .starting { self?.resetToIdle() }
            }
        case .notInstalled, .stopped:
            // Engine may still be bootstrapping or crashed earlier; ask for a
            // restart and queue the session for when it becomes ready.
            AppModel.shared.ensureEngineRunning()
            queuePendingStart()
        }
    }

    /// Shows the HUD and queues a session start for when the engine is ready.
    /// A progress-aware watchdog clears the queue only when readiness truly
    /// never arrives: any modelState loading/downloading event re-arms the
    /// 30 s window, so legitimate long first-run downloads (queue-deferred
    /// loads) don't drop a session the user already started.
    private func queuePendingStart() {
        pendingStart = true
        phase = .starting
        hud.showListening()
        hud.update(text: "Preparing the speech engine…")
        armPendingStartWatchdog()
    }

    /// (Re)arms the 30 s pending-start watchdog. Re-arming bumps `epoch`,
    /// so previously scheduled timers become no-ops.
    private func armPendingStartWatchdog() {
        pendingStartWatchdogEpoch += 1
        let epoch = pendingStartWatchdogEpoch
        let token = sessionToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 30.0) { [weak self] in
            guard let self else { return }
            guard self.pendingStart, self.pendingStartWatchdogEpoch == epoch,
                  self.sessionToken == token else { return }
            self.pendingStart = false
            if self.phase == .starting {
                self.audio.stop()
                self.phase = .idle
                self.hud.update(text: "The engine is taking too long to start. Try again, or check Settings.")
                AppModel.shared.lastError = "Engine start timed out. Try again; if it keeps happening, check the Engine pane in Settings."
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                    // A session may have started during the message window;
                    // don't bury its HUD.
                    guard let self, self.sessionToken == token, self.phase == .idle else { return }
                    self.hud.hide()
                }
            }
        }
    }

    private func beginCapture() {
        phase = .starting
        hud.showListening()
        captureFrontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        // Assign BEFORE starting capture: a hardware reconfiguration firing in
        // the start()'s observer-registration window must never find a nil
        // handler (callbacks are main-queue, so nothing interleaves inside the
        // synchronous block, but the ordering invariant is held explicitly).
        audio.onInterrupted = { [weak self] in
            self?.handleAudioInterrupt()
        }
        do {
            // Start cue BEFORE the mic opens so the blip is never captured or
            // collides with capture via a playback-driven route change.
            // Tradeoff, accepted deliberately: if audio.start() throws below,
            // the session fails right after a start blip. The zero-overlap
            // alternative (delaying capture until the cue finishes) is
            // rejected — it would add dictation-start latency.
            SessionSounds.maybePlayStart(enabled: settings.soundFeedback)
            try audio.start()
            engine.start(delayMs: settings.transcriptionDelayMs, sessionToken: sessionToken)
            phase = .recording
            scheduleMaxDurationWatchdog()
        } catch {
            hud.update(text: error.localizedDescription)
            phase = .idle
            let token = sessionToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                // A session may have started during the message window;
                // don't bury its HUD.
                guard let self, self.sessionToken == token, self.phase == .idle else { return }
                self.hud.hide()
            }
        }
    }

    /// Audio hardware reconfigured mid-session (device change, rate change).
    /// End the capture and flush what was heard so far — nothing is lost.
    private func handleAudioInterrupt() {
        guard phase == .recording || phase == .starting else { return }
        // Pass the reason through so it survives the showTranscribing() below:
        // the user should still see it during finalization.
        stopSession(finalizingMessage: "Audio input changed; finishing…")
    }

    /// Safety net for a lost hotkey-up in hold mode (Secure Input, tap
    /// disabled by the system, ...): cap dictation at 5 minutes.
    private func scheduleMaxDurationWatchdog() {
        let token = sessionToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 300.0) { [weak self] in
            guard let self, self.sessionToken == token else { return }
            if self.phase == .recording || self.phase == .starting {
                self.stopSession()
            }
        }
    }

    /// Ends the recording and waits for the engine's final text. An optional
    /// reason (e.g. audio interruption) is shown in the HUD during finalization
    /// instead of the default transcribing text.
    func stopSession(finalizingMessage: String? = nil) {
        guard phase == .recording || phase == .starting else { return }
        if phase == .starting {
            // Still never actually started capturing; treat as cancel.
            resetToIdle()
            return
        }
        phase = .finalizing
        audio.stop()
        hud.showTranscribing()
        if let finalizingMessage {
            hud.update(text: finalizingMessage)
        }
        engine.stop()
        // Final text arrives via engine event (didReceiveEvent). A watchdog
        // force-resets if the engine never replies (process death, hang).
        let token = sessionToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 45.0) { [weak self] in
            guard let self, self.phase == .finalizing, self.sessionToken == token else { return }
            AppModel.shared.lastError = "Transcription did not finish, so the dictation ended. Try again."
            self.resetToIdle()
        }
    }

    func cancel() {
        guard phase == .recording || phase == .starting || phase == .finalizing else { return }
        cancelled = true
        audio.stop()
        engine.cancel()
        // Intentionally silent: a cancelled dictation gets no sound cue, only
        // the HUD going away. (resetToIdle() therefore plays nothing here.)
        resetToIdle()
    }

    /// Ends the session and returns to idle. Pass `hideHUD: false` when a
    /// message must stay on the HUD a little longer; the caller hides it then.
    private func resetToIdle(hideHUD: Bool = true) {
        phase = .idle
        pendingStart = false
        audio.stop() // idempotent; also covers error-driven exits mid-recording
        if hideHUD {
            hud.hide()
        }
    }

    /// Accessibility is missing: keeps the start path non-blocking (no modal,
    /// no activation — the old `NSAlert.runModal` stalled the main run loop and
    /// stole focus) by riding the message on the HUD like every other state,
    /// with a delayed, token/phase-guarded hide (same pattern as mic denial).
    /// The `Whistral.needsAccessibility` notification this replaced had no
    /// receiver anywhere and is gone.
    private func showNeedsAccessibility() {
        let token = sessionToken
        hud.showListening()
        hud.update(text: "Accessibility access is needed to dictate. Allow it in System Settings > Privacy & Security > Accessibility.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            // A session may have started during the message window;
            // don't bury its HUD.
            guard let self, self.sessionToken == token, self.phase == .idle else { return }
            self.hud.hide()
        }
    }

    private func requestMicrophoneThenStart() {
        phase = .starting
        let token = sessionToken
        hud.showListening()
        hud.update(text: "Microphone access is needed to dictate…")
        Permissions.requestMicrophone { [weak self] status in
            guard let self else { return }
            if status == .granted {
                // The user may have released the hotkey while the system
                // dialog was up (the release ran resetToIdle). Only start if
                // the press is still current.
                guard self.phase == .starting else { return }
                self.phase = .idle
                self.startSession()
            } else {
                if self.phase == .starting { self.phase = .idle }
                self.hud.showListening()
                self.hud.update(text: "Microphone access is needed to dictate. Allow it in System Settings > Privacy & Security > Microphone.")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                    // A session may have started during the message window;
                    // don't bury its HUD.
                    guard let self, self.sessionToken == token, self.phase == .idle else { return }
                    self.hud.hide()
                }
            }
        }
        // In hold mode, a lost key-up (focus switch, tap timeout) would keep
        // the mic on forever; cap every recording session as a safety net.
        scheduleMaxDurationWatchdog()
    }

    // MARK: - Engine events

    func handleEngineEvent(_ event: EngineEvent) {
        switch event {
        case .partial(_, _, let text):
            guard phase == .recording || phase == .starting else { return }
            currentText = text
            hud.update(text: text.isEmpty ? "Start speaking…" : text)

        case .segment, .sessionStarted:
            break

        case .final(let text, let token):
            // Stale finals from an aborted session must not insert into a
            // fresh one: require the current phase AND a matching session
            // token (echoed by the engine on session events).
            guard phase == .finalizing else { return }
            guard token == nil || token == sessionToken else { return }
            insertFinalText(text, token: sessionToken)

        case .cancelled(let token):
            // Same guard: a late 'cancelled' must not kill a live session.
            guard token == nil || token == sessionToken else { return }
            if phase == .finalizing || phase == .starting {
                resetToIdle()
            }

        case .modelState(let state):
            // Load/download progress proves the engine is alive: a queued
            // session's watchdog is re-armed instead of firing mid-download.
            if pendingStart {
                switch state {
                case .loading, .downloadingModel:
                    armPendingStartWatchdog()
                default:
                    break
                }
            }
            maybeStartPendingSession()

        case .error(let message):
            if phase == .recording || phase == .finalizing {
                hud.update(text: message)
                let token = sessionToken
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    guard let self, self.sessionToken == token else { return }
                    self.resetToIdle()
                }
            }
            AppModel.shared.lastError = message

        case .ready, .fileTranscript:
            break
        }
    }

    private func insertFinalText(_ text: String, token: Int) {
        guard !cancelled, sessionToken == token else { resetToIdle(); return }

        // This final passed the phase/token guard in handleEngineEvent, so it
        // is current: this is the only place a transcript gets recorded.
        AppModel.shared.recordTranscript(text)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only current, non-empty finals become "the last transcript"; empty
        // abort finals (engine error paths) must not clobber the previous
        // good one.
        if !trimmed.isEmpty {
            AppModel.shared.lastTranscript = trimmed
        }

        var insertionFailed = false
        if settings.autoInsert, !trimmed.isEmpty {
            if Permissions.accessibility == .granted {
                if !TextInserter.insert(
                    trimmed,
                    method: settings.insertionMethod,
                    expectedBundleID: captureFrontmostBundleID
                ) {
                    insertionFailed = true
                }
            } else {
                // Accessibility is missing: the text would be silently dropped.
                insertionFailed = true
            }
        }

        // Subtle completion cue, played only after insertion has been kicked
        // off so sound can never delay the text (NSSound.play is async). It is
        // the "transcription done" cue, so it stays silent on the
        // insertion-failed path (incl. accessibility denied) below.
        if !insertionFailed {
            SessionSounds.maybePlayStop(enabled: settings.soundFeedback)
        }

        if insertionFailed {
            // The transcript lives on in Recent Transcripts; put it on the
            // clipboard so it is not lost, and say so instead of refading the
            // HUD as if nothing happened.
            // Copy-only on purpose: re-attempting insertion (paste's Cmd+V)
            // after a failure would double-paste into the app that failed.
            TextInserter.copyToPasteboard(trimmed)
            // Ending the session without hiding the HUD: the message below
            // stays up briefly. sessionToken is unchanged, so it guards the
            // delayed hide against a fresh session started in the meantime.
            resetToIdle(hideHUD: false)
            let hideToken = sessionToken
            hud.showListening()
            hud.micLevel = 0 // session is over: flat bars, not a frozen waveform
            hud.update(text: "Insertion failed — transcript copied to clipboard. Press ⌘V to paste.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self, self.sessionToken == hideToken, self.phase == .idle else { return }
                self.hud.hide()
            }
        } else {
            resetToIdle()
        }
    }

    private func maybeStartPendingSession() {
        guard pendingStart else { return }
        switch AppModel.shared.engineState {
        case .ready:
            pendingStart = false
            phase = .idle
            startSession()
        case .error(let message):
            // The load failed or the engine crashed while we were queued; bail
            // out visibly instead of waiting for a readiness that never comes.
            pendingStart = false
            audio.stop()
            phase = .starting
            hud.update(text: message)
            AppModel.shared.lastError = message
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                if self?.phase == .starting { self?.resetToIdle() }
            }
        default:
            break
        }
    }
}

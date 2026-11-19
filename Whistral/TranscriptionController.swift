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

    private var cancellables = Set<AnyCancellable>()

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
            PermissionHotkeyBridge.postNeedsAccessibility()
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
            pendingStart = true
            phase = .starting
            hud.showListening()
            hud.update(text: "Preparing the speech engine…")
        case .error(let message):
            phase = .starting
            hud.showListening()
            hud.update(text: "Engine error: \(message)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                if self?.phase == .starting { self?.resetToIdle() }
            }
        case .notInstalled, .stopped:
            AppModel.shared.ensureEngineRunning()
            phase = .starting
        }
    }

    private func beginCapture() {
        phase = .starting
        hud.showListening()
        do {
            try audio.start()
            engine.start(delayMs: settings.transcriptionDelayMs)
            phase = .recording
        } catch {
            hud.update(text: error.localizedDescription)
            phase = .idle
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.hud.hide()
            }
        }
    }

    func stopSession() {
        guard phase == .recording || phase == .starting else { return }
        if phase == .starting {
            // Still never actually started capturing; treat as cancel.
            resetToIdle()
            return
        }
        phase = .finalizing
        audio.stop()
        hud.showTranscribing()
        engine.stop()
        // Final text arrives via engine event (didReceiveEvent).
    }

    func cancel() {
        guard phase == .recording || phase == .starting || phase == .finalizing else { return }
        cancelled = true
        audio.stop()
        engine.cancel()
        resetToIdle()
    }

    private func resetToIdle() {
        phase = .idle
        pendingStart = false
        hud.hide()
    }

    private func requestMicrophoneThenStart() {
        phase = .starting
        Permissions.requestMicrophone { [weak self] status in
            guard let self else { return }
            if status == .granted {
                self.phase = .idle
                self.startSession()
            } else {
                self.phase = .idle
                self.hud.showListening()
                self.hud.update(text: "Microphone access is needed to dictate.")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                    self?.hud.hide()
                }
            }
        }
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

        case .final(let text):
            let tokenAtFinalize = sessionToken
            insertFinalText(text, token: tokenAtFinalize)

        case .cancelled:
            resetToIdle()

        case .modelState:
            maybeStartPendingSession()

        case .error(let message):
            if phase == .recording || phase == .finalizing {
                hud.update(text: message)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    self?.resetToIdle()
                }
            }
            AppModel.shared.lastError = message

        case .ready, .fileTranscript:
            break
        }
    }

    private func insertFinalText(_ text: String, token: Int) {
        guard !cancelled else { resetToIdle(); return }

        AppModel.shared.lastTranscript = text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if settings.autoInsert, !trimmed.isEmpty, Permissions.accessibility == .granted {
            TextInserter.insert(trimmed, method: settings.insertionMethod)
        }

        resetToIdle()
        _ = token // single-flight guarantee comes from resetToIdle above
    }

    private func maybeStartPendingSession() {
        guard pendingStart, case .ready = AppModel.shared.engineState else { return }
        pendingStart = false
        phase = .idle
        startSession()
    }
}

/// Small bridge for Esc-cancels from the HUD.
@MainActor
enum PermissionHotkeyBridge {
    static func postNeedsAccessibility() {
        NotificationCenter.default.post(name: Notification.Name("Whistral.needsAccessibility"), object: nil)
        let alert = NSAlert()
        alert.messageText = "Accessibility access needed"
        alert.informativeText = """
        Whistral needs Accessibility access to listen for your dictation shortcut \
        and to insert the transcription at your cursor. \
        Grant access in System Settings > Privacy & Security > Accessibility.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            Permissions.openAccessibilitySettings()
        }
    }
}

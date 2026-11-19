//
//  AppModel.swift
//  Whistral
//
//  Central app-wide state and wiring between the engine, hotkey, HUD,
//  windows and settings.
//

import AppKit
import Carbon.HIToolbox
import Combine
import Foundation
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {

    static let shared = AppModel()

    static let defaultModelID = "mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit"

    /// Available quantizations offered by mlx-community, lightest first.
    static let availableModels: [(id: String, label: String, detail: String)] = [
        ("mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit", "Voxtral Mini 4B Realtime — 4-bit", "Fastest, ~2.6 GB download"),
        ("mlx-community/Voxtral-Mini-4B-Realtime-2602-fp16", "Voxtral Mini 4B Realtime — FP16", "Highest quality, ~8.6 GB download"),
        ("mlx-community/Voxtral-Mini-4B-Realtime-6bit", "Voxtral Mini 4B Realtime — 6-bit", "Balanced, ~3.9 GB download"),
    ]

    let settings = SettingsStore.shared
    let engineClient = SidecarEngineClient()
    private(set) lazy var transcriber: TranscriptionController = makeTranscriber()

    private func makeTranscriber() -> TranscriptionController {
        TranscriptionController(engine: engineClient, settings: settings)
    }
    let hotkey = HotkeyController()

    @Published var engineState: EngineState = .stopped
    @Published var lastError: String?
    @Published var lastTranscript: String = ""
    @Published var recentTranscripts: [String] = []

    @Published var showOnboarding = false
    @Published var showSettings = false

    private var cancellables = Set<AnyCancellable>()
    private var didWireSettings = false

    func loadSettings() {
        settings.load()
    }

    /// Called once from AppDelegate after launch.
    func start() {
        loadSettings()
        wireEngineClient()
        engineClient.delegate = self

        if settings.hasCompletedOnboarding {
            enterNormalMode()
        } else {
            showOnboarding = true
        }

        // Detect accessibility while running so the hotkey activates as soon
        // as the user grants it.
        PermissionMonitor.shared.startPolling()
        PermissionMonitor.shared.$accessibility
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                guard let self, status == .granted else { return }
                if self.settings.hasCompletedOnboarding {
                    self.applyHotkey()
                }
            }
            .store(in: &cancellables)
    }

    func enterNormalMode() {
        applyHotkey()
        applyLaunchAtLogin()
        ensureEngineRunning()
    }

    func ensureEngineRunning() {
        engineClient.ensureRunning()
    }

    func applyHotkey() {
        hotkey.onKeyDown = { [weak self] in
            DispatchQueue.main.async { self?.transcriber.hotkeyDown() }
        }
        hotkey.onKeyUp = { [weak self] in
            DispatchQueue.main.async { self?.transcriber.hotkeyUp() }
        }
        hotkey.enable(hotkey: Hotkey(keyCode: settings.hotkeyCode, modifiers: settings.hotkeyModifiers))
    }

    private func reapplyHotkey() {
        if Permissions.accessibility == .granted {
            applyHotkey()
        }
    }

    func applyLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if settings.launchAtLogin {
                if service.status != .enabled {
                    try service.register()
                }
            } else if service.status == .enabled {
                try service.unregister()
            }
        } catch {
            lastError = "Could not update login item: \(error.localizedDescription)"
        }
    }

    private func wireEngineClient() {
        engineClient.delegate = self
        // Forward setting changes that need re-application.
        Publishers.CombineLatest(settings.$hotkeyCode, settings.$hotkeyModifiers)
            .dropFirst()
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.reapplyHotkey() }
            .store(in: &cancellables)

        settings.$launchAtLogin
            .dropFirst()
            .sink { [weak self] _ in self?.applyLaunchAtLogin() }
            .store(in: &cancellables)

        settings.$modelID
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] modelID in
                guard let self else { return }
                switch self.engineState {
                case .loading, .downloadingModel:
                    return
                default:
                    // (Re)load the newly selected model in the background.
                    self.engineClient.load(modelID: modelID)
                }
            }
            .store(in: &cancellables)

        observeEscapeKey()
    }

    /// Esc cancels the active dictation (monitored while HUD is visible).
    private func observeEscapeKey() {
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == UInt16(kVK_Escape) else { return }
            DispatchQueue.main.async {
                guard let self, self.transcriber.phase == .recording || self.transcriber.phase == .finalizing else { return }
                self.transcriber.cancel()
            }
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == UInt16(kVK_Escape),
               let self,
               self.transcriber.phase == .recording || self.transcriber.phase == .finalizing {
                self.transcriber.cancel()
                return nil
            }
            return event
        }
    }

    // MARK: - Transcripts

    func recordTranscript(_ text: String) {
        guard !text.isEmpty else { return }
        recentTranscripts.insert(text, at: 0)
        if recentTranscripts.count > 10 {
            recentTranscripts.removeLast(recentTranscripts.count - 10)
        }
    }
}

// MARK: - Engine client delegate

extension AppModel: SidecarEngineClientDelegate {

    func engineClient(_ client: SidecarEngineClient, didReceiveEvent event: EngineEvent) {
        switch event {
        case .modelState(let state):
            engineState = state
            transcriber.handleEngineEvent(event)

        case .final(let text):
            recordTranscript(text)
            transcriber.handleEngineEvent(event)

        case .partial, .segment, .cancelled, .sessionStarted:
            transcriber.handleEngineEvent(event)

        case .error(let message):
            lastError = message
            transcriber.handleEngineEvent(event)

        case .ready, .fileTranscript:
            break
        }
    }

    func engineClient(_ client: SidecarEngineClient, didLog message: String) {
        #if DEBUG
        print("[engine]", message)
        #endif
    }
}

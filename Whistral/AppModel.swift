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

    /// Default speech model for new installs (and users who never picked one).
    /// Existing users keep their saved choice; the picker order still leads
    /// with the Voxtral builds.
    static let defaultModelID = VozEngineClient.modelID

    /// Available quantizations offered by mlx-community, lightest first.
    /// Note: only repos in voxmlx-native converted format (config.json with a
    /// "multimodal" section) are loadable by the engine; the "-2602-4bit"
    /// community port uses an incompatible flat config and is not offered.
    static let availableModels: [(id: String, label: String, detail: String)] = [
        ("mlx-community/Voxtral-Mini-4B-Realtime-6bit", "Voxtral Mini 4B Realtime — 6-bit", "Recommended, ~3.9 GB download"),
        ("mistralai/Voxtral-Mini-4B-Realtime-2602", "Voxtral Mini 4B Realtime — BF16 (original)", "Highest quality, ~8.6 GB download"),
        (VozEngineClient.modelID, VozEngineClient.displayName, "On-device Core ML on the Neural Engine, ~337 MB download"),
    ]

    let settings = SettingsStore.shared
    let engineClient = SidecarEngineClient()
    let vozEngine = VozEngineClient()

    /// The engine that transcribes for the currently selected model.
    /// Model IDs prefixed with "voz:" route to the on-device Core ML engine;
    /// everything else goes to the Python/MLX sidecar.
    var activeEngine: any SpeechEngine {
        settings.modelID.hasPrefix("voz:") ? vozEngine : engineClient
    }

    private(set) lazy var transcriber: TranscriptionController = makeTranscriber()

    private func makeTranscriber() -> TranscriptionController {
        TranscriptionController(settings: settings)
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

        // Check for updates in the background on launch
        UpdateChecker.shared.checkForUpdates()

        // Detect both required permissions while running so the hotkey becomes
        // active as soon as the user grants them.
        PermissionMonitor.shared.startPolling()
        if settings.hasCompletedOnboarding {
            PermissionMonitor.shared.requestAccessibility()
            PermissionMonitor.shared.requestInputMonitoring()
        }
        Publishers.CombineLatest(
            PermissionMonitor.shared.$accessibility,
            PermissionMonitor.shared.$inputMonitoring
        )
            .receive(on: RunLoop.main)
            .sink { [weak self] accessibility, inputMonitoring in
                guard let self, self.settings.hasCompletedOnboarding else { return }
                if accessibility == .granted, inputMonitoring == .granted {
                    self.applyHotkey()
                } else {
                    self.hotkey.disable()
                }
            }
            .store(in: &cancellables)
    }

    func enterNormalMode() {
        applyHotkey()
        applyLaunchAtLogin()
        ensureEngineRunning()
        // In-process engines (Voz) never get a sidecar .ready event, so on a
        // fresh launch nothing else would trigger their model load.
        if activeEngine !== engineClient {
            switch engineState {
            case .loading, .downloadingModel, .ready:
                break
            default:
                engineState = .loading
                activeEngine.load(modelID: settings.modelID)
            }
        }
    }

    func ensureEngineRunning() {
        // The Voz engine runs in-process and needs no bootstrap; only the
        // Python sidecar has a venv to create and a process to spawn.
        if activeEngine === engineClient {
            engineClient.ensureRunning()
        }
    }

    func applyHotkey() {
        guard Permissions.accessibility == .granted,
              Permissions.inputMonitoring == .granted else {
            hotkey.disable()
            return
        }
        hotkey.onKeyDown = { [weak self] in
            DispatchQueue.main.async { self?.transcriber.hotkeyDown() }
        }
        hotkey.onKeyUp = { [weak self] in
            DispatchQueue.main.async { self?.transcriber.hotkeyUp() }
        }
        hotkey.enable(hotkey: Hotkey(keyCode: settings.hotkeyCode, modifiers: settings.hotkeyModifiers))
    }

    private func reapplyHotkey() {
        if Permissions.accessibility == .granted,
           Permissions.inputMonitoring == .granted {
            applyHotkey()
        } else {
            hotkey.disable()
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
            lastError = "Could not update the login item: \(error.localizedDescription). Try again in Settings."
        }
    }

    private func wireEngineClient() {
        engineClient.delegate = self
        vozEngine.delegate = self
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
                // (Re)load the newly selected model in the background. Both
                // engines no-op when their current model is already loaded or
                // loading, so no in-progress guard is needed here.
                self.activeEngine.load(modelID: modelID)
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

// MARK: - Engine delegate

extension AppModel: SpeechEngineDelegate {

    func speechEngine(_ engine: any SpeechEngine, didReceiveEvent event: EngineEvent) {
        switch event {
        case .modelState(let state):
            engineState = state
            transcriber.handleEngineEvent(event)

        case .final(_, _):
            // Recording is owned by TranscriptionController: it has the
            // session token and phase guard, so only accepted (current,
            // non-cancelled) finals reach recentTranscripts; lastTranscript
            // is likewise set there. Stale finals are dropped silently.
            transcriber.handleEngineEvent(event)

        case .partial, .segment, .cancelled, .sessionStarted:
            transcriber.handleEngineEvent(event)

        case .error(let message):
            lastError = message
            transcriber.handleEngineEvent(event)

        case .ready:
            // The sidecar process is up but has no model. Load the currently
            // selected model unless one is already loading (covers relaunch,
            // engine restarts after a crash, and post-onboarding).
            switch engineState {
            case .loading, .downloadingModel, .ready:
                break
            default:
                engineState = .loading
                activeEngine.load(modelID: settings.modelID)
            }

        case .fileTranscript:
            break
        }
    }

    func speechEngine(_ engine: any SpeechEngine, didLog message: String) {
        #if DEBUG
        print("[engine]", message)
        #endif
    }
}

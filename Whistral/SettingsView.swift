//
//  SettingsView.swift
//  Whistral
//
//  The Settings window: General, Dictation, Engine, About panes presented as
//  toolbar tabs, per Apple's macOS settings guidance.
//

import AVFoundation
import Carbon.HIToolbox
import Combine
import ServiceManagement
import SwiftUI

struct SettingsView: View {

    @StateObject private var settings = SettingsStore.shared
    @State private var selectedPane: Pane = .general

    enum Pane: String, CaseIterable, Identifiable {
        case general = "General"
        case dictation = "Dictation"
        case engine = "Engine"
        case about = "About"

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .dictation: return "mic"
            case .engine: return "waveform.badge.magnifyingglass"
            case .about: return "info.circle"
            }
        }
    }

    var body: some View {
        TabView(selection: $selectedPane) {
            GeneralPane()
                .tabItem { Label(Pane.general.rawValue, systemImage: Pane.general.symbol) }
                .tag(Pane.general)
            DictationPane()
                .tabItem { Label(Pane.dictation.rawValue, systemImage: Pane.dictation.symbol) }
                .tag(Pane.dictation)
            EnginePane()
                .tabItem { Label(Pane.engine.rawValue, systemImage: Pane.engine.symbol) }
                .tag(Pane.engine)
            AboutPane()
                .tabItem { Label(Pane.about.rawValue, systemImage: Pane.about.symbol) }
                .tag(Pane.about)
        }
        .frame(width: 560, height: 400)
        .onChange(of: selectedPane) { _, pane in
            SettingsWindowController.shared.setWindowTitle("Whistral Settings — \(pane.rawValue)")
        }
    }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        Form {
            Section {
                Toggle("Open Whistral when I log in", isOn: $settings.launchAtLogin)
                Toggle("Insert transcription at the cursor", isOn: $settings.autoInsert)
                Toggle("Sound feedback", isOn: $settings.soundFeedback)
            } header: {
                Text("Behavior")
            } footer: {
                Text("When insert-at-cursor is off, finished transcripts are shown in the menu under Recent Transcripts, ready to copy.")
            }
            Section("Errors") {
                if let error = AppModel.shared.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.callout)
                } else {
                    Text("No recent issues.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Dictation

private struct DictationPane: View {
    @ObservedObject private var settings = SettingsStore.shared
    // Observe the live poll so the accessibility row updates while the
    // window is open; the static Permissions.accessibility read here before
    // was unobservable, so the row stayed stale (and "off") mid-session.
    @ObservedObject private var permissionMonitor = PermissionMonitor.shared

    var body: some View {
        Form {
            Section("Shortcut") {
                HotkeyRecorderRow()

                Picker("Trigger", selection: $settings.triggerMode) {
                    ForEach(TriggerMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Text(settings.triggerMode.helpText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Insertion") {
                Picker("Method", selection: $settings.insertionMethod) {
                    ForEach(InsertionMethod.allCases) { method in
                        Text(method.label).tag(method)
                    }
                }
                Toggle("Insert transcription at the cursor", isOn: $settings.autoInsert)
                if permissionMonitor.accessibility != .granted {
                    HStack {
                        Label("Accessibility access is off — enable it to insert text.", systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Open Settings") {
                            Permissions.openPrivacyPane("Privacy_Accessibility")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct HotkeyRecorderRow: View {
    @ObservedObject private var settings = SettingsStore.shared
    @State private var isRecording = false

    var body: some View {
        HStack {
            Text("Dictation shortcut")
            Spacer()
            Button(action: { isRecording.toggle() }) {
                Text(isRecording ? "Press keys…" : settings.hotkeyDisplay)
                    .frame(minWidth: 110)
            }
            .background(isRecording ? Color.accentColor.opacity(0.25) : .clear)
            .accessibilityLabel("Dictation shortcut, currently \(settings.hotkeyDisplay)")
            .background(KeyEventCatcher(isActive: isRecording) { event in
                capture(event)
            })
            if settings.hotkeyModifiers != Hotkey.default.modifiers || settings.hotkeyCode != Hotkey.default.keyCode {
                Button("Reset") {
                    settings.hotkeyCode = Hotkey.default.keyCode
                    settings.hotkeyModifiers = Hotkey.default.modifiers
                }
                .controlSize(.small)
            }
        }
    }

    private func capture(_ event: NSEvent) {
        guard [.keyDown, .flagsChanged].contains(event.type) else { return }
        guard event.keyCode != UInt16(kVK_Escape) else {
            isRecording = false
            return
        }
        let relevantMods = NSEvent.ModifierFlags([.command, .option, .control, .shift])
            .intersection(event.modifierFlags)
        // Require at least one modifier or a function key so typing isn't swallowed.
        let plainLetter = relevantMods.isEmpty && event.keyCode < 96 && ![UInt16(kVK_Space), UInt16(kVK_Tab), UInt16(kVK_Return)].contains(event.keyCode)
        guard !plainLetter else { return }
        settings.hotkeyCode = UInt32(event.keyCode)
        settings.hotkeyModifiers = UInt64(relevantMods.rawValue)
        isRecording = false
    }
}

/// Captures keyboard events while active (during hotkey recording).
private struct KeyEventCatcher: NSViewRepresentable {

    var isActive: Bool
    var onEvent: (NSEvent) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onEvent = onEvent
        view.isActive = isActive
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onEvent = onEvent
        view.isActive = isActive
    }

    final class CatcherView: NSView {
        var onEvent: ((NSEvent) -> Void)?
        var isActive = false { didSet { syncMonitor() } }
        private var monitor: Any?

        private func syncMonitor() {
            if isActive, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
                    self?.onEvent?(event)
                    return nil
                }
            } else if !isActive, let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}

// MARK: - Engine

private struct EnginePane: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var app = AppModel.shared

    var body: some View {
        Form {
            Section("Model") {
                Picker("Speech model", selection: $settings.modelID) {
                    ForEach(AppModel.availableModels, id: \.id) { model in
                        Text(model.label).tag(model.id)
                    }
                }
                Text(modelDetail(for: settings.modelID))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                engineStatus
            }

            Section("Transcription delay") {
                Picker("Delay", selection: $settings.transcriptionDelayMs) {
                    ForEach(settings.transcriptionDelayOptions, id: \.self) { ms in
                        Text("\(ms) ms").tag(ms)
                    }
                }
                // Applies to the next dictation session.
                Text("Higher delays give the model more context and usually more accurate text; lower delays respond faster. Applies to the next dictation.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var engineStatus: some View {
        switch app.engineState {
        case .ready(let model):
            Label("Ready — \(model)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
        case .loading:
            Label("Loading model…", systemImage: "progress")
        case .downloadingModel(let received, let total):
            VStack(alignment: .leading, spacing: 4) {
                Text("Downloading model… \(ByteCountFormatter.string(fromByteCount: Int64(received), countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file))")
                ProgressView(value: Double(received), total: Double(max(total, 1)))
            }
        case .bootstrapping, .notInstalled:
            Label("Preparing the speech engine…", systemImage: "progress")
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .font(.callout)
        case .stopped:
            Label("Engine not running. It starts with your first dictation.", systemImage: "moon")
        }
    }

    private func modelDetail(for id: String) -> String {
        AppModel.availableModels.first { $0.id == id }?.detail ?? ""
    }
}

// MARK: - About

private struct AboutPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading) {
                    Text("Whistral").font(.title2.weight(.semibold))
                    Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0") (1)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            Text("Whistral is open source and runs entirely on your Mac. Speech recognition uses the Voxtral Mini 4B Realtime model by Mistral AI (Apache-2.0), executed locally with MLX thanks to Awni Hannun's voxmlx. Audio is never recorded to disk or sent anywhere.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent("Model") {
                Link("Voxtral Mini 4B Realtime",
                     destination: URL(string: "https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602")!)
            }
            .font(.callout)
            LabeledContent("Local build") {
                Link("mlx-community 6-bit (default)",
                     destination: URL(string: "https://huggingface.co/mlx-community/Voxtral-Mini-4B-Realtime-6bit")!)
            }
            .font(.callout)
            LabeledContent("License") {
                Link("Apache-2.0 (see LICENSE)", destination: URL(string: "https://www.apache.org/licenses/LICENSE-2.0.txt")!)
            }
            .font(.callout)

            Spacer()
        }
        .padding(24)
    }
}

#Preview {
    SettingsView()
}

//
//  OnboardingView.swift
//  Whistral
//
//  First-launch onboarding: welcome, permissions, engine setup and model
//  download. Design follows Apple's onboarding guidance: brief, optional,
//  permissions requested in context, large downloads never blocking.
//

import AVFoundation
import Combine
import ServiceManagement
import SwiftUI

struct OnboardingView: View {

    enum Step: Int, CaseIterable, Identifiable {
        case welcome
        case permissions
        case engine
        case model
        case finish

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .permissions: return "Permissions"
            case .engine: return "Setup"
            case .model: return "Download the speech model"
            case .finish: return "Ready"
            }
        }
    }

    @StateObject private var model = OnboardingModel()

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .font(.system(size: 42, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 32)
                    .accessibilityHidden(true)
                Text("Whistral")
                    .font(.largeTitle.weight(.semibold))
                Text(model.step.subtitle)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .padding(.bottom, 20)

            Divider()

            // Content
            VStack {
                switch model.step {
                case .welcome: WelcomeStep(model: model)
                case .permissions: PermissionsStep(model: model)
                case .engine: EngineStep(model: model)
                case .model: ModelStep(model: model)
                case .finish: FinishStep(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(24)

            Divider()

            // Footer controls
            HStack {
                if let hint = model.stepHint {
                    Text(hint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer()
                Button(model.step == .welcome ? "Continue" : "Continue") {
                    model.advance()
                }
                .disabled(!model.canContinue)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 520, height: 480)
        .onAppear { model.onAppear() }
    }
}

// MARK: - Steps

private extension OnboardingView.Step {
    var subtitle: String {
        switch self {
        case .welcome: return "On-device dictation with Smart Correction"
        case .permissions: return "Two permissions, requested once"
        case .engine: return "Setting up the speech engine"
        case .model: return "One-time download of the speech model"
        case .finish: return "Whistral is ready to transcribe"
        }
    }
}

// MARK: - View model

@MainActor
final class OnboardingModel: ObservableObject {

    @Published var step: OnboardingView.Step = .welcome
    @Published var engineLog: [String] = []
    @Published var downloadReceived: Int = 0
    @Published var downloadTotal: Int = 0
    @Published var downloadStarted = false
    @Published var modelReady = false
    @Published var setupFailed: String?

    private var cancellables = Set<AnyCancellable>()

    func onAppear() {
        let app = AppModel.shared

        app.engineClient.delegate = OnboardingEngineTap.shared
        OnboardingEngineTap.shared.model = self

        app.$engineState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .downloadingModel(let received, let total):
                    self.downloadStarted = true
                    self.downloadReceived = received
                    self.downloadTotal = max(total, 1)
                    self.modelReady = false
                case .loading, .bootstrapping:
                    self.downloadStarted = true
                    self.modelReady = false
                case .ready:
                    self.modelReady = true
                case .error(let message):
                    self.setupFailed = message
                default:
                    break
                }
            }
            .store(in: &cancellables)
    }

    var canContinue: Bool {
        switch step {
        case .welcome: return true
        case .permissions:
            // Never trap the user if a permission is denied; they can
            // grant it later from Settings.
            return true
        case .engine: return true
        case .model:
            // Never block onboarding on the download.
            return true
        case .finish: return true
        }
    }

    var engineSetupNeeded: Bool {
        !FileManager.default.fileExists(atPath: SidecarEngineClient.venvPythonURL.path)
    }

    var stepHint: String? {
        switch step {
        case .welcome:
            return "You can change everything later in Settings."
        case .permissions:
            return PermissionMonitor.shared.microphone == .granted
                ? "Accessibility lets Whistral insert the transcription at your cursor."
                : nil
        case .model:
            return "You can keep using your Mac while the model downloads."
        default:
            return nil
        }
    }

    func advance() {
        switch step {
        case .welcome:
            step = .permissions
        case .permissions:
            step = .engine
        case .engine:
            if engineSetupNeeded {
                AppModel.shared.ensureEngineRunning()
            }
            step = .model
        case .model:
            if !modelReady {
                AppModel.shared.engineClient.load(modelID: AppModel.shared.settings.modelID)
            }
            step = .finish
        case .finish:
            finish()
        }
    }

    func finish() {
        AppModel.shared.settings.hasCompletedOnboarding = true
        AppModel.shared.engineClient.delegate = AppModel.shared
        AppModel.shared.enterNormalMode()
        AppModel.shared.showOnboarding = false
        OnboardingWindowController.shared.close()
    }
}

/// Temporary engine tap that feeds setup logs and progress into onboarding.
final class OnboardingEngineTap: SidecarEngineClientDelegate {

    static let shared = OnboardingEngineTap()
    weak var model: OnboardingModel?

    func engineClient(_ client: SidecarEngineClient, didReceiveEvent event: EngineEvent) {
        DispatchQueue.main.async {
            AppModel.shared.engineClient(AppModel.shared.engineClient, didReceiveEvent: event)
            guard let model = self.model else { return }
            switch event {
            case .modelState(.downloadingModel(let received, let total)):
                model.downloadStarted = true
                model.downloadReceived = received
                model.downloadTotal = max(total, 1)
            case .modelState(.ready):
                model.modelReady = true
            case .modelState(.error(let message)):
                model.setupFailed = message
            default:
                break
            }
        }
    }

    func engineClient(_ client: SidecarEngineClient, didLog message: String) {
        DispatchQueue.main.async {
            guard let model = self.model else { return }
            model.engineLog.append(message)
            if model.engineLog.count > 8 { model.engineLog.removeFirst(model.engineLog.count - 8) }
        }
    }
}

// MARK: - Individual steps

private struct WelcomeStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            BulletRow(systemImage: "waveform",
                      title: "Voxtral speech-to-text",
                      detail: "Realtime streaming dictation powered by Mistral's Voxtral Mini 4B on Apple Silicon MLX. Recognizes 13 languages.")
            BulletRow(systemImage: "broom.fill",
                      title: "Smart on-device correction",
                      detail: "Apple Foundation Models clean up fillers (uh, um...), fix spoken self-corrections ('meet at 10, sorry 11am' -> '11am'), and polish grammar.")
            BulletRow(systemImage: "lock.shield",
                      title: "100% private and offline",
                      detail: "Both speech recognition and smart correction run entirely on your Mac. Nothing is ever sent to the cloud.")
            BulletRow(systemImage: "keyboard",
                      title: "Global dictation shortcut",
                      detail: "Hold \(AppModel.shared.settings.hotkeyDisplay) while you speak, and release to insert clean text directly into any focused app.")
            BulletRow(systemImage: "water.waves",
                      title: "Fluid activation & minimal HUD",
                      detail: "A subtle water-like glow ripples along your screen edge to confirm listening, with a minimal status pill at the bottom of the screen.")
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
}

private struct PermissionsStep: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var monitor = PermissionMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PermissionRow(
                icon: "mic",
                title: "Microphone",
                detail: "Whistral records audio only while you hold the dictation shortcut to turn your speech into text on this Mac.",
                status: monitor.microphone
            ) {
                monitor.requestMicrophone()
            }

            PermissionRow(
                icon: "accessibility",
                title: "Accessibility",
                detail: "Needed to observe your shortcut and insert the transcription at your cursor. No other use.",
                status: monitor.accessibility,
                grantedHint: "Open System Settings if you need to enable it later."
            ) {
                Permissions.openPrivacyPane("Privacy_Accessibility")
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct EngineStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !model.engineSetupNeeded {
                Label("Speech engine already set up.", systemImage: "checkmark.circle")
                    .foregroundStyle(.primary)
            } else {
                ProgressView()
                    .controlSize(.small)
                Text("Preparing a local speech environment (first run only; no model download yet).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let failed = model.setupFailed {
                Label(failed, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(model.engineLog.enumerated().reversed()), id: \.offset) { _, line in
                        Text(line)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct ModelStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.modelReady {
                Label("Model ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if let failed = model.setupFailed {
                Label(failed, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else if model.downloadStarted && model.downloadTotal > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Downloading Voxtral Mini 4B Realtime")
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: Int64(model.downloadReceived), countStyle: .file)
                             + " of "
                             + ByteCountFormatter.string(fromByteCount: Int64(model.downloadTotal), countStyle: .file))
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    ProgressView(value: Double(model.downloadReceived), total: Double(model.downloadTotal))
                }
            } else {
                Button("Start Download") {
                    AppModel.shared.engineClient.load(modelID: AppModel.shared.settings.modelID)
                }
                .controlSize(.large)
            }
            Spacer()
        }
        .accessibilityElement(children: .contain)
    }
}

private struct FinishStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            BulletRow(systemImage: "keyboard",
                      title: "Try it now",
                      detail: "Click into any text field, hold \(AppModel.shared.settings.hotkeyDisplay), speak naturally, and release.")
            BulletRow(systemImage: "broom.fill",
                      title: "Smart Correction is active",
                      detail: "Filler words and mid-sentence corrections are resolved automatically. You can toggle or tune Speed vs Quality in Settings.")
            BulletRow(systemImage: "menubar.rectangle",
                      title: "Lives in your menu bar",
                      detail: "Access Settings, switch models or presets (Speed, Medium, Quality), or copy recent transcripts from the menu bar.")
            BulletRow(systemImage: "questionmark.circle",
                      title: "Can't find the icon?",
                      detail: "Whistral keeps running even if macOS hides the icon. Use \(AppModel.shared.settings.hotkeyDisplay) to dictate, or relaunch Whistral to show it.")
            if !model.modelReady {
                Text("The model is still downloading in the background. You can finish now and dictate once it's ready.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Building blocks

private struct BulletRow: View {
    let systemImage: String?
    let assetName: String?
    let title: String
    let detail: String

    init(systemImage: String, title: String, detail: String) {
        self.init(systemName: systemImage, assetName: nil, title: title, detail: detail)
    }

    init(systemName: String?, assetName: String?, title: String, detail: String) {
        self.systemImage = systemName
        self.assetName = assetName
        self.title = title
        self.detail = detail
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage ?? "circle")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct PermissionRow: View {
    let icon: String
    let title: String
    let detail: String
    let status: PermissionStatus
    var grantedHint: String?
    var grantedActionTitle: String?
    let onAction: () -> Void

    init(icon: String, title: String, detail: String, status: PermissionStatus,
         grantedHint: String? = nil, grantedActionTitle: String? = nil,
         onAction: @escaping () -> Void) {
        self.icon = icon
        self.title = title
        self.detail = detail
        self.status = status
        self.grantedHint = grantedHint
        self.grantedActionTitle = grantedActionTitle
        self.onAction = onAction
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon == "accessibility" ? "figure.wave" : icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    statusBadge
                }
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if status == .granted, let grantedActionTitle {
                    Button(grantedActionTitle) { onAction() }
                        .controlSize(.small)
                }
                if status == .granted, let grantedHint {
                    Text(grantedHint)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var statusBadge: some View {
        switch status {
        case .granted:
            return AnyView(
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Granted")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("\(title) permission granted")
            )
        case .notDetermined, .denied:
            // HIG pre-alert rules (Privacy > Pre-alert screens, windows, or
            // views): the custom screen's button must read "Continue"-style,
            // reserving "Allow" for the system alert that we open next.
            return AnyView(
                Button(status == .denied ? "Open Settings" : "Continue") { onAction() }
            )
        }
    }
}

// Previews
struct OnboardingView_Previews: PreviewProvider {
    static var previews: some View {
        OnboardingView().preferredColorScheme(.light)
        OnboardingView().preferredColorScheme(.dark)
    }
}

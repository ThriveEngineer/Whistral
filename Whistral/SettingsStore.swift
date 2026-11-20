//
//  SettingsStore.swift
//  Whistral
//

import AppKit
import Combine
import Foundation
import SwiftUI

enum TriggerMode: String, CaseIterable, Identifiable {
    case hold = "hold"
    case toggle = "toggle"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hold: return "Hold and speak"
        case .toggle: return "Press to start and stop"
        }
    }

    var helpText: String {
        switch self {
        case .hold: return "Hold the shortcut while you speak, release to insert the text."
        case .toggle: return "Press the shortcut to start, press again to stop."
        }
    }
}

enum InsertionMethod: String, CaseIterable, Identifiable {
    case clipboard = "clipboard"
    case keystrokes = "keystrokes"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .clipboard: return "Paste (recommended)"
        case .keystrokes: return "Simulate keystrokes"
        }
    }
}

enum VoxtralMode: String, CaseIterable, Identifiable {
    case speed = "speed"
    case medium = "medium"
    case quality = "quality"
    case custom = "custom"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .speed:   return "Speed (Fast) -- 240 ms delay"
        case .medium:  return "Medium -- 480 ms delay"
        case .quality: return "Quality (Accurate) -- 720 ms delay"
        case .custom:  return "Custom"
        }
    }
}

/// All persisted user settings. Backed by UserDefaults.
final class SettingsStore: ObservableObject {

    static let shared = SettingsStore()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Keys

    private enum Key {
        static let hotkeyKeyCode = "hotkey.keyCode"
        static let hotkeyModifiers = "hotkey.modifiers"
        static let triggerMode = "triggerMode"
        static let autoInsert = "autoInsert"
        static let insertionMethod = "insertionMethod"
        static let modelID = "modelID"
        static let transcriptionDelayMs = "transcriptionDelayMs"
        static let launchAtLogin = "launchAtLogin"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let soundFeedback = "soundFeedback"
        static let llmCorrection = "llmCorrection"
        static let llmCorrectionStyle = "llmCorrectionStyle"
        static let llmCorrectionMode = "llmCorrectionMode"
        static let voxtralMode = "voxtralMode"
    }

    // MARK: - Values

    @Published var hotkeyCode: UInt32 = 49 {
        didSet { defaults.set(Int(hotkeyCode), forKey: Key.hotkeyKeyCode); objectWillChange.send() }
    }
    @Published var hotkeyModifiers: UInt64 = UInt64(CGEventFlags.maskAlternate.rawValue) {
        didSet { defaults.set(Int(hotkeyModifiers), forKey: Key.hotkeyModifiers); objectWillChange.send() }
    }
    @Published var triggerMode: TriggerMode = .hold {
        didSet { defaults.set(triggerMode.rawValue, forKey: Key.triggerMode); objectWillChange.send() }
    }
    @Published var autoInsert: Bool = true {
        didSet { defaults.set(autoInsert, forKey: Key.autoInsert); objectWillChange.send() }
    }
    @Published var insertionMethod: InsertionMethod = .clipboard {
        didSet { defaults.set(insertionMethod.rawValue, forKey: Key.insertionMethod); objectWillChange.send() }
    }
    @Published var modelID: String = AppModel.defaultModelID {
        didSet { defaults.set(modelID, forKey: Key.modelID); objectWillChange.send() }
    }
    @Published var transcriptionDelayMs: Int = 480 {
        didSet { defaults.set(transcriptionDelayMs, forKey: Key.transcriptionDelayMs); objectWillChange.send() }
    }
    @Published var launchAtLogin: Bool = false {
        didSet { defaults.set(launchAtLogin, forKey: Key.launchAtLogin); objectWillChange.send() }
    }
    @Published var hasCompletedOnboarding: Bool = false {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding); objectWillChange.send() }
    }
    @Published var soundFeedback: Bool = true {
        didSet { defaults.set(soundFeedback, forKey: Key.soundFeedback); objectWillChange.send() }
    }
    /// Run the on-device Foundation Model to fix grammar and misspeakings.
    @Published var llmCorrection: Bool = true {
        didSet { defaults.set(llmCorrection, forKey: Key.llmCorrection); objectWillChange.send() }
    }
    /// How aggressively the LLM should rewrite the transcript.
    @Published var llmCorrectionStyle: CorrectionStyle = .natural {
        didSet { defaults.set(llmCorrectionStyle.rawValue, forKey: Key.llmCorrectionStyle); objectWillChange.send() }
    }
    /// Speed (low latency) vs Quality (deeper context) for Apple Foundation Model.
    @Published var llmCorrectionMode: CorrectionMode = .speed {
        didSet { defaults.set(llmCorrectionMode.rawValue, forKey: Key.llmCorrectionMode); objectWillChange.send() }
    }
    /// Speed vs Quality preset for Voxtral speech-to-text.
    @Published var voxtralMode: VoxtralMode = .medium {
        didSet { defaults.set(voxtralMode.rawValue, forKey: Key.voxtralMode); objectWillChange.send() }
    }

    func applyVoxtralMode(_ mode: VoxtralMode) {
        voxtralMode = mode
        switch mode {
        case .speed:
            transcriptionDelayMs = 240
        case .medium:
            transcriptionDelayMs = 480
        case .quality:
            transcriptionDelayMs = 720
        case .custom:
            break
        }
    }

    // MARK: - Restore

    func load() {
        let defaultMods: UInt64 = CGEventFlags.maskAlternate.rawValue
        hotkeyCode = UInt32(defaults.object(forKey: Key.hotkeyKeyCode) as? Int ?? 49) // Space
        hotkeyModifiers = UInt64(defaults.object(forKey: Key.hotkeyModifiers) as? Int ?? Int(defaultMods))
        triggerMode = (defaults.string(forKey: Key.triggerMode)).flatMap(TriggerMode.init) ?? .hold
        autoInsert = defaults.object(forKey: Key.autoInsert) as? Bool ?? true
        insertionMethod = (defaults.string(forKey: Key.insertionMethod)).flatMap(InsertionMethod.init) ?? .clipboard
        modelID = defaults.string(forKey: Key.modelID) ?? AppModel.defaultModelID
        transcriptionDelayMs = defaults.object(forKey: Key.transcriptionDelayMs) as? Int ?? 480
        launchAtLogin = defaults.object(forKey: Key.launchAtLogin) as? Bool ?? false
        hasCompletedOnboarding = defaults.object(forKey: Key.hasCompletedOnboarding) as? Bool ?? false
        soundFeedback = defaults.object(forKey: Key.soundFeedback) as? Bool ?? true
        llmCorrection = defaults.object(forKey: Key.llmCorrection) as? Bool ?? true
        llmCorrectionStyle = (defaults.string(forKey: Key.llmCorrectionStyle)).flatMap(CorrectionStyle.init) ?? .natural
        llmCorrectionMode = (defaults.string(forKey: Key.llmCorrectionMode)).flatMap(CorrectionMode.init) ?? .speed
        voxtralMode = (defaults.string(forKey: Key.voxtralMode)).flatMap(VoxtralMode.init) ?? (transcriptionDelayMs <= 240 ? .speed : (transcriptionDelayMs == 480 ? .medium : (transcriptionDelayMs == 720 ? .quality : .custom)))
    }

    // MARK: - Display

    /// Human-readable shortcut, e.g. "⌥Space" or "F5".
    var hotkeyDisplay: String {
        var out = ""
        let flags = CGEventFlags(rawValue: hotkeyModifiers)
        if flags.contains(.maskCommand) { out += "⌘" }
        if flags.contains(.maskAlternate) { out += "⌥" }
        if flags.contains(.maskControl) { out += "⌃" }
        if flags.contains(.maskShift) { out += "⇧" }
        out += Keys.name(forCode: hotkeyCode)
        return out
    }

    var transcriptionDelayOptions: [Int] {
        [80, 160, 240, 320, 400, 480, 720, 960, 1200, 2400]
    }
}

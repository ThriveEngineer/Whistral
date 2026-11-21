//
//  Permissions.swift
//  Whistral
//

import ApplicationServices
import AppKit
import AVFoundation
import Combine

enum PermissionStatus: Equatable {
    case granted
    case denied
    case notDetermined
}

enum Permissions {

    // MARK: - Microphone

    static var microphone: PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }

    static func requestMicrophone(_ completion: @escaping (PermissionStatus) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            DispatchQueue.main.async { completion(microphone) }
        }
    }

    // MARK: - Accessibility

    /// Required to observe the dictation shortcut and to insert text
    /// in the frontmost app.
    static var accessibility: PermissionStatus {
        AXIsProcessTrusted() ? .granted : .denied
    }

    /// Asks macOS to show its Accessibility permission prompt.
    static func requestAccessibility() {
        let promptOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(promptOptions)
    }

    static func openPrivacyPane(_ path: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(path)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Lightweight observable wrapper so SwiftUI views can react to permission changes.
final class PermissionMonitor: ObservableObject {

    static let shared = PermissionMonitor()

    @Published var microphone: PermissionStatus = Permissions.microphone
    @Published var accessibility: PermissionStatus = Permissions.accessibility

    private var timer: AnyCancellable?
    private var didRequestAccessibility = false

    func startPolling() {
        guard timer == nil else { return }
        timer = Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                let newMic = Permissions.microphone
                let newAX = Permissions.accessibility
                if newMic != self.microphone { self.objectWillChange.send(); self.microphone = newMic }
                if newAX != self.accessibility { self.objectWillChange.send(); self.accessibility = newAX }
            }
    }

    func requestMicrophone() {
        Permissions.requestMicrophone { [weak self] status in
            self?.objectWillChange.send()
            self?.microphone = status
        }
    }

    func requestAccessibility() {
        guard accessibility != .granted, !didRequestAccessibility else { return }
        didRequestAccessibility = true
        Permissions.requestAccessibility()
    }
}

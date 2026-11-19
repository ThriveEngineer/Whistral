//
//  WindowControllers.swift
//  Whistral
//
//  NSWindow hosts for the onboarding guide and Settings panes.
//

import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController {

    static let shared = OnboardingWindowController()

    private var window: NSWindow?

    func show(reopenAsGuide: Bool = false) {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = reopenAsGuide ? "Whistral Guide" : "Welcome to Whistral"
            window.contentView = NSHostingView(rootView: OnboardingView())
            window.center()
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.performClose(nil)
        // Reopening later (Welcome Guide) restarts from the first step.
        window?.contentViewController = NSHostingController(rootView: OnboardingView())
    }
}

@MainActor
final class SettingsWindowController {

    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Whistral Settings"
            window.contentView = NSHostingView(rootView: SettingsView())
            window.center()
            window.isReleasedWhenClosed = false
            window.toolbarStyle = .preference
            window.tabbingMode = .disallowed
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func setWindowTitle(_ title: String) {
        window?.title = title
    }
}

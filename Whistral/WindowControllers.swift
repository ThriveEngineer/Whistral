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
                contentRect: NSRect(x: 0, y: 0, width: 540, height: 560),
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
        // Activate the app so the onboarding window comes frontmost
        // even though the app is an .accessory (menu-bar) app.
        NSApp.activate(ignoringOtherApps: true)
        NSApp.unhide(nil)
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
        // Activate the app so the onboarding window comes frontmost
        // even though the app is an .accessory (menu-bar) app.
        NSApp.activate(ignoringOtherApps: true)
        NSApp.unhide(nil)
    }

    func setWindowTitle(_ title: String) {
        window?.title = title
    }
}

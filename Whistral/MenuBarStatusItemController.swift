//
//  MenuBarStatusItemController.swift
//  Whistral
//

import AppKit

/// Owns the menu bar status item. The menu delegate rebuilds the menu every
/// time it opens so the state shown is always current.
@MainActor
final class MenuBarStatusItemController: NSObject, NSMenuDelegate {

    static let shared = MenuBarStatusItemController()

    private var statusItem: NSStatusItem?
    private var hasInstalled = false
    private var menuIsOpen = false

    /// Set by AppDelegate at install time. We deliberately do not cast
    /// `NSApp.delegate` to reach it: in a SwiftUI-lifecycle app
    /// (`@NSApplicationDelegateAdaptor`) the app's `delegate` is a SwiftUI
    /// proxy that forwards our delegate methods but defeats an `as?`
    /// cast — which silently skipped status-item installation.
    private weak var appDelegate: AppDelegate?

    func install(_ appDelegate: AppDelegate) {
        guard !hasInstalled else { return }
        self.appDelegate = appDelegate

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = Self.icon(isRecording: false)
        } else {
            NSLog("[Whistral] install(): status item button is nil")
        }

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu

        statusItem = item
        hasInstalled = true

        // The status item is Whistral's only mouse-accessible surface (the
        // app runs as an LSUIElement accessory), so never launch into a
        // hidden state — macOS can persist a removal from the menu bar.
        // People can still hide it during a session (menu bar overflow);
        // re-launching restores it, which onboarding and the hotkey tell
        // them about. See "Show/ensure visibility" below and populateMenu
        // in AppDelegate for the in-session fallbacks.
        item.isVisible = true

        // Build the initial content.
        appDelegate.populateMenu(menu)
    }

    private static func icon(isRecording: Bool) -> NSImage? {
        let image = NSImage(systemSymbolName: isRecording ? "waveform" : "mic.fill",
                            accessibilityDescription: isRecording
                                ? "Whistral — dictating"
                                : "Whistral — on-device dictation")
        image?.size = NSSize(width: 18, height: 18)
        return image
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        appDelegate?.populateMenu(menu)
    }

    // MARK: - Visibility

    /// Whether the extra is currently shown in the menu bar. The system may
    /// hide it at runtime (user customization or menu bar-space pressure),
    /// which would otherwise orphan the app — its only mouse access is this
    /// extra, because Whistral runs as an LSUIElement accessory app.
    var isExtraVisible: Bool {
        statusItem?.isVisible ?? false
    }

    /// Menu action that makes the extra visible again after the user (or the
    /// system) removed it from the menu bar. Titles HIG-correct: title case,
    /// no ellipsis — it actuates immediately and requires no further input.
    @objc func showInMenuBar(_ sender: NSMenuItem) {
        statusItem?.isVisible = true
    }

    // MARK: - Icon

    func setStatusIcon(isRecording: Bool) {
        guard hasInstalled, let button = statusItem?.button else { return }
        button.image = Self.icon(isRecording: isRecording)
    }
}

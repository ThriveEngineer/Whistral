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

    func install() {
        guard !hasInstalled else { return }
        guard let delegate = NSApp.delegate as? AppDelegate else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = Self.icon(isRecording: false)
        }

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu

        statusItem = item
        hasInstalled = true

        // Build the initial content.
        delegate.populateMenu(menu)
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
        (NSApp.delegate as? AppDelegate)?.populateMenu(menu)
    }

    // MARK: - Icon

    func setStatusIcon(isRecording: Bool) {
        guard hasInstalled, let button = statusItem?.button else { return }
        button.image = Self.icon(isRecording: isRecording)
    }
}

//
//  AppDelegate.swift
//  Whistral
//

import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItemBag = Set<AnyCancellable>()
    private var phaseBag = Set<AnyCancellable>()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Menu-bar-only app: no Dock icon, standard window states.
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel.shared

        MenuBarStatusItemController.shared.install(self)

        model.start()

        if model.showOnboarding {
            OnboardingWindowController.shared.show()
        }

        // Mirror dictation state in the menu bar icon.
        model.transcriber.$phase
            .receive(on: RunLoop.main)
            .sink { phase in
                MenuBarStatusItemController.shared.setStatusIcon(isRecording: phase == .recording)
            }
            .store(in: &phaseBag)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // the app lives in the menu bar
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.engineClient.terminate()
    }

    // MARK: - Actions

    @objc func toggleDictation(_ sender: NSMenuItem) {
        let transcriber = AppModel.shared.transcriber
        if transcriber.phase == .idle {
            transcriber.hotkeyDown()
        } else {
            transcriber.hotkeyUp()
        }
    }

    @objc func openSettings(_ sender: NSMenuItem) {
        SettingsWindowController.shared.show()
    }

    @objc func openOnboarding(_ sender: NSMenuItem) {
        OnboardingWindowController.shared.show(reopenAsGuide: true)
    }

    @objc func copyTranscript(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func openEngineFolder(_ sender: NSMenuItem) {
        NSWorkspace.shared.open(SidecarEngineClient.appSupportURL)
    }

    @objc func quit(_ sender: NSMenuItem) {
        AppModel.shared.engineClient.terminate()
        NSApp.terminate(sender)
    }

    // MARK: - Menu construction

    /// Adds the current items to `menu` (used by menuNeedsUpdate each time
    /// the status item opens).
    func populateMenu(_ menu: NSMenu) {
        menu.autoenablesItems = false

        let model = AppModel.shared

        let isIdle = model.transcriber.phase == .idle
        var isEngineReady = false
        if case .ready = model.engineState { isEngineReady = true }

        let dictation = NSMenuItem(
            title: isIdle ? "Start Dictation" : "Stop Dictation",
            action: #selector(toggleDictation(_:)),
            keyEquivalent: model.settings.hotkeyDisplay
        )
        dictation.target = self
        dictation.isEnabled = isEngineReady || !isIdle
        dictation.image = NSImage(systemSymbolName: isIdle ? "mic" : "stop.fill",
                                  accessibilityDescription: isIdle ? "Start dictation" : "Stop dictation")
        if !isIdle {
            dictation.state = .on
        }
        menu.addItem(dictation)

        let state = NSMenuItem(title: engineStateLabel, action: nil, keyEquivalent: "")
        state.isEnabled = false
        state.state = isEngineReady ? .on : .off
        menu.addItem(state)

        menu.addItem(.separator())

        let transcripts = NSMenuItem(title: "Recent Transcripts", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        if model.recentTranscripts.isEmpty {
            let emptyItem = NSMenuItem(title: "No transcripts yet", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            submenu.addItem(emptyItem)
        } else {
            for text in model.recentTranscripts {
                let preview = text.count > 64 ? String(text.prefix(64)) + "…" : text
                let transcriptItem = NSMenuItem(title: preview,
                                                action: #selector(copyTranscript(_:)),
                                                keyEquivalent: "")
                transcriptItem.target = self
                transcriptItem.representedObject = text
                transcriptItem.toolTip = "Copy to clipboard"
                submenu.addItem(transcriptItem)
            }
        }
        transcripts.submenu = submenu
        menu.addItem(transcripts)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…",
                                      action: #selector(openSettings(_:)),
                                      keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let helpItem = NSMenuItem(title: "Show Welcome Guide",
                                  action: #selector(openOnboarding(_:)),
                                  keyEquivalent: "")
        helpItem.target = self
        menu.addItem(helpItem)

        let logsItem = NSMenuItem(title: "Open Engine Folder",
                                  action: #selector(openEngineFolder(_:)),
                                  keyEquivalent: "")
        logsItem.target = self
        menu.addItem(logsItem)

        menu.addItem(.separator())

        // Fallback for gap "hidden status item": if the user or the system
        // removed the extra from the menu bar, this accessory app loses all
        // mouse access (that menu IS the app's only surface). The menu only
        // opens via the extra, so this item is mostly defensive; primary
        // recovery is the launch-time auto-restore in MenuBarStatusItem-
        // Controller.install() plus the onboarding instructions. HIG copy:
        // title case, no ellipsis (actuates immediately).
        if !MenuBarStatusItemController.shared.isExtraVisible {
            let showItem = NSMenuItem(
                title: "Show Whistral in Menu Bar",
                action: #selector(MenuBarStatusItemController.showInMenuBar(_:)),
                keyEquivalent: ""
            )
            showItem.target = MenuBarStatusItemController.shared
            menu.addItem(showItem)
        }

        let quit = NSMenuItem(title: "Quit Whistral",
                              action: #selector(quit(_:)),
                              keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private var engineStateLabel: String {
        switch AppModel.shared.engineState {
        case .notInstalled: return "Speech engine: not set up"
        case .bootstrapping: return "Setting up speech engine…"
        case .downloadingModel(let received, let total) where total > 0:
            let pct = Int(100 * Double(received) / Double(total))
            return "Downloading model — \(pct)%"
        case .loading: return "Loading model…"
        case .ready(let model): return "Ready — \(model)"
        case .error(let msg): return "Engine error: \(String(msg.prefix(60)))"
        case .stopped: return "Engine not running"
        default: break
        }
        return ""
    }
}

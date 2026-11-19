//
//  WhistralApp.swift
//  Whistral
//

import SwiftUI

@main
struct WhistralApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Whistral is a menu-bar app (LSUIElement): its windows are managed
        // by AppDelegate. A minimal Settings scene provides the standard
        // ⌘, handling and hosts the settings UI.
        Settings {
            SettingsView()
        }
    }
}

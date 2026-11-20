//
//  HUDController.swift
//  Whistral
//
//  The floating dictation HUD: a compact pill anchored at the bottom-centre
//  of the screen, showing only the waveform, spinner, or clean-up icon.
//

import AppKit
import Combine
import SwiftUI
import os.log

@MainActor
final class HUDController: NSObject, ObservableObject {

    @Published var phase: HUDPhase = .hidden
    @Published var partialText: String = ""
    @Published var micLevel: Float = 0

    private var panel: NSPanel?
    /// Generation counter: bumped on every show; a pending hide animation is
    /// only allowed to order the panel out if the generation hasn't changed.
    private var generation = 0
    /// True while a hide()'s fade-out animation is in flight (the panel stays
    /// "visible" until its completion orders it out), so a concurrent show
    /// knows it must restart the fade-in from transparent.
    private var isFadingOut = false

    /// Fixed geometry for the compact pill.
    static let pillSize = NSSize(width: 72, height: 38)

    enum HUDPhase {
        case hidden
        case listening
        case transcribing
        case cleaning
    }

    // MARK: - Show / update / hide

    func showListening() {
        phase = .listening
        partialText = ""
        presentPanel(anchorFresh: true)
    }

    func update(text: String) {
        partialText = text
        if text.localizedCaseInsensitiveContains("clean") {
            phase = .cleaning
            presentPanel()
        }
    }

    func showTranscribing() {
        phase = .transcribing
        presentPanel()
    }

    func showCleaning() {
        phase = .cleaning
        presentPanel()
    }

    func hide() {
        phase = .hidden
        partialText = ""
        micLevel = 0
        generation += 1
        let gen = generation
        guard let panel else { return }
        isFadingOut = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            // A show() during our fade bumped the generation; don't bury it.
            // This completion runs on the main thread, so the isolated read
            // is safe to assume here.
            guard MainActor.assumeIsolated({ self.generation == gen }) else { return }
            panel.orderOut(nil)
            MainActor.assumeIsolated { self.isFadingOut = false }
        })
    }

    // MARK: - Panel management

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.pillSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.worksWhenModal = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false

        let rootView = HUDView(controller: self)
        let hosting = NSHostingView(rootView: rootView)
        panel.contentView = hosting
        panel.setAccessibilityElement(true)
        panel.setAccessibilityLabel("Whistral dictation")
        return panel
    }

    private func presentPanel(anchorFresh: Bool = false) {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        let size = Self.pillSize
        let origin = anchorPoint(preferredSize: size)
        let targetFrame = NSRect(origin: origin, size: size)

        panel.setFrame(targetFrame, display: false)

        if !panel.isVisible || anchorFresh {
            generation += 1
            if !panel.isVisible || isFadingOut {
                isFadingOut = false
                panel.alphaValue = 0
                panel.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.16
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().alphaValue = 1
                }
            }
        }
    }

    /// Place the HUD at the horizontal centre of the screen containing the
    /// cursor, safely floating above the Dock / bottom edge.
    private func anchorPoint(preferredSize: NSSize) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
                     ?? NSScreen.main
                     ?? NSScreen.screens[0]
        let visible = screen.visibleFrame

        // Centre horizontally within the visible frame
        var x = visible.midX - preferredSize.width / 2

        // Float 56 pt above the bottom edge / Dock so it never clips or overlaps
        let margin: CGFloat = 56
        var y = visible.minY + margin

        // Hard-clamp: guarantee the entire pill stays on-screen
        x = min(max(x, visible.minX + 16), visible.maxX - preferredSize.width - 16)
        y = min(max(y, visible.minY + 16), visible.maxY - preferredSize.height - 16)

        return NSPoint(x: x, y: y)
    }

    /// Smooth the raw level reported from the audio thread.
    nonisolated func reportRawLevel(_ level: Float) {
        DispatchQueue.main.async {
            let decayed = self.micLevel * 0.80
            self.micLevel = max(level, decayed)
        }
    }
}

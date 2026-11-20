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

    enum HUDPhase {
        case hidden
        case listening
        case transcribing
    }

    // MARK: - Show / update / hide

    func showListening() {
        phase = .listening
        partialText = ""
        presentPanel(anchorFresh: true)
    }

    func update(text: String) {
        partialText = text
        if phase == .listening {
            presentPanel() // resize for content, without re-anchoring
        }
    }

    func showTranscribing() {
        phase = .transcribing
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
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 40),
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
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentView = hosting
        panel.setAccessibilityElement(true)
        panel.setAccessibilityLabel("Whistral dictation")
        return panel
    }

    private func presentPanel(anchorFresh: Bool = false) {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        let hosting = panel.contentView as? NSHostingView<HUDView>
        let contentSize = hosting?.fittingSize ?? NSSize(width: 100, height: 40)

        // Anchor to the pointer once per appearance; subsequent updates only
        // resize (and only when the size actually changed) so the HUD doesn't
        // visibly chase the mouse while dictating.
        let newFrame = NSRect(origin: anchorPoint(preferredSize: contentSize), size: contentSize)
        let currentFrame = panel.frame
        if !panel.isVisible || anchorFresh {
            // Fresh appearance, or an appearance while a previous hide's
            // fade-out is still in flight (the panel is technically still
            // visible until its completion orders it out): bump the
            // generation so that STALE hide completion no-ops. Always refresh
            // content size and anchor here, but only restart the fade-in
            // from transparent when the panel is not already fully visible —
            // re-animating alpha on a visible panel would visibly blink it.
            generation += 1
            panel.setContentSize(contentSize)
            panel.setFrameOrigin(newFrame.origin)
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
        } else if abs(currentFrame.size.width - contentSize.width) > 0.5
                    || abs(currentFrame.size.height - contentSize.height) > 0.5 {
            panel.setContentSize(contentSize)
        }
    }

    /// Place the HUD at the horizontal centre of the screen containing the
    /// cursor, comfortably above the Dock / bottom edge.
    private func anchorPoint(preferredSize: NSSize) -> NSPoint {
        // Use the screen the cursor is on; fall back to the menu-bar screen.
        let mouse  = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
                     ?? NSScreen.main
                     ?? NSScreen.screens[0]
        let visible = screen.visibleFrame

        // Centre horizontally; place bottom edge 32 pt above the visible-frame
        // minimum (above the Dock).  Clamp so the whole pill stays on-screen.
        let margin: CGFloat = 32
        var x = visible.midX - preferredSize.width  / 2
        var y = visible.minY + margin

        // Hard-clamp: never let any edge escape the visible frame.
        x = min(max(x, visible.minX + 8), visible.maxX - preferredSize.width  - 8)
        y = min(max(y, visible.minY + 8), visible.maxY - preferredSize.height - 8)
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

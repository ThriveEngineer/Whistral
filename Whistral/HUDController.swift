//
//  HUDController.swift
//  Whistral
//
//  The floating dictation HUD: a small, non-activating panel with a live
//  waveform and the transcription in progress, positioned near the pointer.
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

    enum HUDPhase {
        case hidden
        case listening
        case transcribing
    }

    // MARK: - Show / update / hide

    func showListening() {
        phase = .listening
        partialText = ""
        presentPanel()
    }

    func update(text: String) {
        partialText = text
        if phase == .listening {
            presentPanel() // resize for content
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
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    // MARK: - Panel management

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
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

    private func presentPanel() {
        let panel = self.panel ?? makePanel()
        self.panel = panel

        let hosting = panel.contentView as? NSHostingView<HUDView>
        let size = hosting?.fittingSize ?? NSSize(width: 380, height: 120)
        let contentSize = NSSize(
            width: max(240, min(460, size.width)),
            height: max(88, size.height)
        )

        let anchor = anchorPoint(preferredSize: contentSize)
        panel.setContentSize(contentSize)
        panel.setFrameOrigin(anchor)

        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                panel.animator().alphaValue = 1
            }
        }
    }

    /// Place the HUD just below and to the right of the pointer, inside the
    /// visible frame of the screen it belongs to.
    private func anchorPoint(preferredSize: NSSize) -> NSPoint {
        var mouse = NSEvent.mouseLocation
        if !NSScreen.screens.contains(where: { $0.frame.contains(mouse) }) {
            mouse = NSEvent.mouseLocation // still keep the value; clamp below
        }
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
        let visible = screen.visibleFrame

        var x = mouse.x + 16
        var y = mouse.y - preferredSize.height - 18
        x = min(max(x, visible.minX + 8), visible.maxX - preferredSize.width - 8)
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

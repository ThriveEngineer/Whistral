//
//  HUDView.swift
//  Whistral
//
//  Transient dictation HUD designed strictly in accordance with Apple's
//  macOS Human Interface Guidelines (HIG): lightweight, non-intrusive,
//  using native system materials, standard SF Symbols, and semantic typography.
//

import SwiftUI

struct HUDView: View {

    @ObservedObject var controller: HUDController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var statusTitle: String {
        switch controller.phase {
        case .listening:
            return "Listening…"
        case .transcribing:
            return "Processing…"
        case .hidden:
            return ""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header Row: Leading status indicator & label, trailing audio meter & cancel hint
            HStack(spacing: 8) {
                statusIndicator

                Text(statusTitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)

                Spacer()

                if controller.phase == .listening {
                    WaveformBars(level: controller.micLevel)
                        .padding(.trailing, 2)

                    Text("⎋ Esc")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.tertiary)
                }
            }

            // Live Transcription / Preview Text
            textContent
        }
        .padding(14)
        .frame(width: 380, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .shadow(color: .black.opacity(0.18), radius: 14, y: 5)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Status Indicator (HIG: Standard SF Symbols & ProgressView, no stars/sparkles/emojis)

    @ViewBuilder
    private var statusIndicator: some View {
        switch controller.phase {
        case .listening:
            Image(systemName: "mic.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)

        case .transcribing:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Processing transcription")

        case .hidden:
            EmptyView()
        }
    }

    // MARK: - Text Content

    @ViewBuilder
    private var textContent: some View {
        if controller.phase == .transcribing {
            Text(controller.partialText.isEmpty ? "Transcribing speech…" : controller.partialText)
                .font(.system(size: 14, weight: controller.partialText.isEmpty ? .regular : .medium))
                .foregroundStyle(controller.partialText.isEmpty ? .secondary : .primary)
                .lineLimit(4)
                .lineSpacing(2)
                .multilineTextAlignment(.leading)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(displayText)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(controller.partialText.isEmpty ? .secondary : .primary)
                .opacity(controller.partialText.isEmpty ? 0.75 : 1.0)
                .lineLimit(4)
                .lineSpacing(2)
                .multilineTextAlignment(.leading)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var displayText: String {
        if controller.partialText.isEmpty {
            return "Start speaking…"
        }
        return controller.partialText
    }
}

// MARK: - Waveform Audio Level Meter

/// Lightweight 5-bar audio meter adhering to macOS HIG feedback conventions.
struct WaveformBars: View {

    let level: Float

    private let barCount = 5

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(0..<barCount, id: \.self) { i in
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 2.5, height: barHeight(index: i))
                    .animation(.snappy(duration: 0.12), value: barHeight(index: i))
            }
        }
        .frame(height: 14)
        .accessibilityHidden(true)
    }

    private func barHeight(index: Int) -> CGFloat {
        let distance = abs(CGFloat(index) - CGFloat(barCount - 1) / 2.0)
        let falloff = 1.0 - (distance / CGFloat(barCount))
        let minHeight: CGFloat = 3
        let maxHeight: CGFloat = 13
        let amp = max(0, min(1, CGFloat(level)))
        return minHeight + (maxHeight - minHeight) * amp * falloff
    }
}

#Preview {
    VStack(spacing: 20) {
        HUDPreviewContainer(phase: .listening, text: "Hello, this is a live transcription while I dictate…")
        HUDPreviewContainer(phase: .transcribing, text: "Processing your dictation…")
    }
    .padding(30)
}

// Lightweight container for Xcode preview
private struct HUDPreviewContainer: View {
    let phase: HUDController.HUDPhase
    let text: String

    var body: some View {
        let proxy = HUDController()
        let content = Group {
            if phase == .listening || phase == .transcribing {
                HUDView(controller: proxy)
            }
        }
        return content.onAppear {
            proxy.phase = phase
            proxy.partialText = text
            proxy.micLevel = 0.7
        }
    }
}

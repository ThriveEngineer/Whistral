//
//  HUDView.swift
//  Whistral
//

import SwiftUI

struct HUDView: View {

    @ObservedObject var controller: HUDController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var statusTitle: String {
        switch controller.phase {
        case .listening: return "Listening…"
        case .transcribing: return "Transcribing…"
        case .hidden: return ""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: phaseSymbol)
                    .font(.system(size: 13, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)

                Text(statusTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                if controller.phase == .listening {
                    WaveformBars(level: controller.micLevel)
                    Text("Esc to cancel")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }

            textContent
        }
        .padding(16)
        .frame(width: 380, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(.separator.opacity(0.35), lineWidth: 1)
                }
        }
        .shadow(color: .black.opacity(0.22), radius: 18, y: 6)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var textContent: some View {
        if controller.phase == .transcribing {
            HStack(spacing: 10) {
                // Indeterminate shimmer
                TimelineView(.animation(minimumInterval: nil, paused: reduceMotion)) { context in
                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { i in
                            Circle()
                                .fill(.tertiary)
                                .frame(width: 6, height: 6)
                                .opacity(Self.transcribingDotOpacity(i, at: context.date))
                        }
                    }
                }
                Text(controller.partialText.isEmpty ? "Finishing up…" : controller.partialText)
                    .font(.system(size: 15, weight: controller.partialText.isEmpty ? .regular : .medium))
                    .foregroundStyle(controller.partialText.isEmpty ? .secondary : .primary)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(displayText)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(displayText.isEmpty ? .secondary : .primary)
                .italic(displayText.isEmpty)
                .lineLimit(4)
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

    private var phaseSymbol: String {
        switch controller.phase {
        case .listening: return "mic.fill"
        case .transcribing: return "sparkles"
        case .hidden: return "mic"
        }
    }

    /// Smooth, staggered pulse driven by the timeline date (continuous loop).
    /// Under Reduce Motion the timeline is paused, so this evaluates once and
    /// the dots keep a fixed opacity.
    private static func transcribingDotOpacity(_ index: Int, at date: Date) -> Double {
        let period: TimeInterval = 1.2
        let phase = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: period) / period
        let stagger = Double(index) / 3.0
        let wave = sin((phase + stagger) * 2 * .pi)
        return 0.3 + 0.7 * (wave * 0.5 + 0.5)
    }
}

/// Compact vertical bars that respond to live mic input.
struct WaveformBars: View {

    let level: Float

    private let barCount = 5

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<barCount, id: \.self) { i in
                Capsule()
                    .fill(.tint)
                    .frame(width: 3, height: barHeight(index: i))
                    .animation(.snappy(duration: 0.12), value: barHeight(index: i))
            }
        }
        .accessibilityHidden(true)
    }

    private func barHeight(index: Int) -> CGFloat {
        let distance = abs(CGFloat(index) - CGFloat(barCount - 1) / 2)
        let falloff = 1 - distance / CGFloat(barCount)
        let base: CGFloat = 4
        let maxGrow: CGFloat = 14
        return base + maxGrow * max(0, pow(CGFloat(level), 0.8)) * falloff
    }
}

#Preview {
    VStack(spacing: 20) {
        HUDPreviewContainer(phase: .listening, text: "Hello, this is a live transcription while I dictate…")
        HUDPreviewContainer(phase: .transcribing, text: "Working on the final draft…")
    }
    .padding(30)
}

// Lightweight container so previews don't need the controller's panel.
private struct HUDPreviewContainer: View {
    let phase: HUDController.HUDPhase
    let text: String

    var body: some View {
        let proxy = HUDController()
        let content = Group {
            if phase == .listening {
                HUDView(controller: proxy)
            }
        }
        // previews are illustrative only
        return content.onAppear {
            proxy.phase = phase
            proxy.partialText = text
            proxy.micLevel = 0.7
        }
    }
}

//
//  HUDView.swift
//  Whistral
//
//  Floating dictation HUD with modern glassmorphism, responsive live waveform,
//  subtle glowing accents, and clear visual feedback states.
//

import SwiftUI

struct HUDView: View {

    @ObservedObject var controller: HUDController
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isPulseActive = false

    private var statusTitle: String {
        switch controller.phase {
        case .listening:
            return "Listening…"
        case .transcribing:
            return settings.llmCorrection ? "Polishing with AI…" : "Transcribing…"
        case .hidden:
            return ""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header Row: Status icon + title + waveform + esc badge
            HStack(spacing: 8) {
                statusIndicator

                Text(statusTitle)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.88))

                Spacer()

                if controller.phase == .listening {
                    WaveformBars(level: controller.micLevel)
                        .padding(.trailing, 2)

                    // macOS-style keyboard cancel badge
                    HStack(spacing: 4) {
                        Text("esc")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                            )
                        Text("cancel")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(.secondary.opacity(0.8))
                    }
                }
            }

            // Subtle divider line separating status header from speech content
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 1)

            // Transcription Content
            textContent
        }
        .padding(16)
        .frame(width: 390, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    // Glassmorphic specular gradient border for realistic physical depth
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.35),
                                    Color.white.opacity(0.10),
                                    Color.black.opacity(0.05)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }
        }
        // Dual-layer shadow: subtle contact shadow + soft ambient drop shadow
        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
        .shadow(color: .black.opacity(0.18), radius: 20, y: 8)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Status Indicator

    @ViewBuilder
    private var statusIndicator: some View {
        switch controller.phase {
        case .listening:
            ZStack {
                // Pulsing outer aura
                Circle()
                    .fill(Color.red.opacity(0.35))
                    .frame(width: 14, height: 14)
                    .scaleEffect(isPulseActive && !reduceMotion ? 1.5 : 0.9)
                    .opacity(isPulseActive && !reduceMotion ? 0 : 0.75)
                    .animation(
                        reduceMotion ? nil : .easeOut(duration: 1.2).repeatForever(autoreverses: false),
                        value: isPulseActive
                    )

                // Solid center dot
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                    .shadow(color: Color.red.opacity(0.5), radius: 3)
            }
            .frame(width: 16, height: 16)
            .onAppear { isPulseActive = true }
            .onDisappear { isPulseActive = false }

        case .transcribing:
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.purple, Color.accentColor, Color.blue],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 16, height: 16)

        case .hidden:
            EmptyView()
        }
    }

    // MARK: - Text Content

    @ViewBuilder
    private var textContent: some View {
        if controller.phase == .transcribing {
            HStack(alignment: .top, spacing: 10) {
                // Animated loader dots
                TimelineView(.animation(minimumInterval: nil, paused: reduceMotion)) { context in
                    HStack(spacing: 3) {
                        ForEach(0..<3, id: \.self) { i in
                            Circle()
                                .fill(Color.accentColor.opacity(0.85))
                                .frame(width: 5, height: 5)
                                .scaleEffect(Self.transcribingDotScale(i, at: context.date))
                                .opacity(Self.transcribingDotOpacity(i, at: context.date))
                        }
                    }
                    .padding(.top, 6)
                }

                Text(controller.partialText.isEmpty ? "Finishing and polishing…" : controller.partialText)
                    .font(.system(size: 15, weight: controller.partialText.isEmpty ? .regular : .medium))
                    .foregroundStyle(controller.partialText.isEmpty ? .secondary : .primary)
                    .lineSpacing(3)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(displayText)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(controller.partialText.isEmpty ? .secondary : .primary)
                .opacity(controller.partialText.isEmpty ? 0.75 : 1.0)
                .italic(controller.partialText.isEmpty)
                .lineSpacing(3)
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

    // MARK: - Animation Helpers

    private static func transcribingDotOpacity(_ index: Int, at date: Date) -> Double {
        let period: TimeInterval = 1.1
        let phase = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: period) / period
        let stagger = Double(index) / 3.0
        let wave = sin((phase + stagger) * 2 * .pi)
        return 0.35 + 0.65 * (wave * 0.5 + 0.5)
    }

    private static func transcribingDotScale(_ index: Int, at date: Date) -> CGFloat {
        let period: TimeInterval = 1.1
        let phase = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: period) / period
        let stagger = Double(index) / 3.0
        let wave = sin((phase + stagger) * 2 * .pi)
        return 0.85 + 0.35 * CGFloat(wave * 0.5 + 0.5)
    }
}

// MARK: - Waveform Bars

/// Fluid 7-bar waveform that responds organically to live mic volume.
struct WaveformBars: View {

    let level: Float

    private let barCount = 7

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(0..<barCount, id: \.self) { i in
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.accentColor,
                                Color.accentColor.opacity(0.65)
                            ],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(width: 3, height: barHeight(index: i))
                    .animation(.snappy(duration: 0.10, extraBounce: 0.1), value: barHeight(index: i))
            }
        }
        .frame(height: 18)
        .accessibilityHidden(true)
    }

    private func barHeight(index: Int) -> CGFloat {
        let center = CGFloat(barCount - 1) / 2.0
        let dist = abs(CGFloat(index) - center) / center
        // Organic bell curve distribution so center bars move most
        let bell = cos(dist * (.pi / 2.4))
        let minHeight: CGFloat = 3
        let maxHeight: CGFloat = 16
        let amp = CGFloat(max(0, min(1, pow(level, 0.75))))
        return minHeight + (maxHeight - minHeight) * amp * bell
    }
}

#Preview {
    VStack(spacing: 20) {
        HUDPreviewContainer(phase: .listening, text: "Hello, this is a live transcription while I dictate…")
        HUDPreviewContainer(phase: .transcribing, text: "Working on the final draft…")
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

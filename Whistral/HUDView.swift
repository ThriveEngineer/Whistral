//
//  HUDView.swift
//  Whistral
//
//  Compact dictation pill anchored at the bottom-centre of the screen.
//  Shows only the essential real-time indicator — no text, no labels.
//  Apple HIG: native system material, standard SF Symbols, no sparkles/stars.
//

import SwiftUI

struct HUDView: View {

    @ObservedObject var controller: HUDController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            switch controller.phase {
            case .listening:
                WaveformBars(level: controller.micLevel)

            case .transcribing:
                // Loading spinner: centered in the pill
                LoadingSpinner()

            case .cleaning:
                // Clean-up indicator: broom — centered in the pill
                Image(systemName: "broom.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 16, height: 16)
                    .accessibilityLabel("Cleaning up text")

            case .hidden:
                EmptyView()
            }
        }
        .frame(width: 72, height: 38)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Dictation HUD")
    }
}

// MARK: - Loading Spinner (Pure SwiftUI: guaranteed animation in nonactivating panel)

struct LoadingSpinner: View {

    @State private var isSpinning = false

    var body: some View {
        Circle()
            .trim(from: 0.15, to: 0.85)
            .stroke(
                Color.accentColor,
                style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
            )
            .frame(width: 16, height: 16)
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: isSpinning)
            .onAppear {
                isSpinning = true
            }
            .accessibilityLabel("Processing transcription")
    }
}

// MARK: - Waveform Audio Level Meter

/// Lightweight 5-bar audio level meter.
struct WaveformBars: View {

    let level: Float

    private let barCount = 5

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<barCount, id: \.self) { i in
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3, height: barHeight(index: i))
                    .animation(.snappy(duration: 0.12), value: barHeight(index: i))
            }
        }
        .frame(height: 18)
        .accessibilityHidden(true)
    }

    private func barHeight(index: Int) -> CGFloat {
        let distance = abs(CGFloat(index) - CGFloat(barCount - 1) / 2.0)
        let falloff  = 1.0 - (distance / CGFloat(barCount))
        let minH: CGFloat = 4
        let maxH: CGFloat = 18
        let amp = max(0, min(1, CGFloat(level)))
        return minH + (maxH - minH) * amp * falloff
    }
}

#Preview {
    VStack(spacing: 20) {
        HUDPreviewContainer(phase: .listening)
        HUDPreviewContainer(phase: .transcribing)
        HUDPreviewContainer(phase: .cleaning)
    }
    .padding(40)
    .background(Color.gray.opacity(0.2))
}

private struct HUDPreviewContainer: View {
    let phase: HUDController.HUDPhase

    var body: some View {
        let proxy = HUDController()
        return HUDView(controller: proxy)
            .onAppear {
                proxy.phase    = phase
                proxy.micLevel = 0.65
            }
    }
}

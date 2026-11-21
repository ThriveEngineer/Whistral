//
//  WaterGlowView.swift
//  Whistral
//
//  Luminous fluid bottom-edge glow that indicates voice detection activation.
//  Uses the user's macOS system accent color, waving like gentle water,
//  fading from ~80% opacity at the bottom edge to 0% a few dozen pixels above.
//

import SwiftUI

struct WaterGlowView: View {

    /// Generation counter to reset animations on each activation.
    let id: Int

    @State private var phase1: CGFloat = 0
    @State private var phase2: CGFloat = 0
    @State private var opacity: Double = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            // Layer 1: Wider undulating liquid wave
            WaveShape(phase: phase1, amplitude: 5.5, frequency: 240)
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: Color.accentColor.opacity(0.80), location: 0.0),
                            .init(color: Color.accentColor.opacity(0.40), location: 0.50),
                            .init(color: Color.accentColor.opacity(0.0), location: 1.0)
                        ],
                        startPoint: .bottom,
                        endPoint: .top
                    )
                )
                .frame(height: 60)
                .blur(radius: 8)

            // Layer 2: Secondary wave with counter-phase and higher frequency
            WaveShape(phase: phase2, amplitude: 4.0, frequency: 160)
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: Color.accentColor.opacity(0.75), location: 0.0),
                            .init(color: Color.accentColor.opacity(0.35), location: 0.55),
                            .init(color: Color.accentColor.opacity(0.0), location: 1.0)
                        ],
                        startPoint: .bottom,
                        endPoint: .top
                    )
                )
                .frame(height: 50)
                .blur(radius: 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .opacity(opacity)
        .id(id)
        .onAppear {
            // Fluid horizontal wave shimmer
            withAnimation(.linear(duration: 3.2).repeatForever(autoreverses: false)) {
                phase1 = .pi * 4
            }
            withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) {
                phase2 = -.pi * 4
            }
            // Gentle fade-in over 0.25 seconds
            withAnimation(.easeOut(duration: 0.25)) {
                opacity = 1.0
            }
            // Smooth fade-out starting at 2.4s, completely gone by 3.0s
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
                withAnimation(.easeIn(duration: 0.6)) {
                    opacity = 0.0
                }
            }
        }
    }
}

// MARK: - Wave Shape

struct WaveShape: Shape {
    var phase: CGFloat
    var amplitude: CGFloat
    var frequency: CGFloat

    var animatableData: CGFloat {
        get { phase }
        set { phase = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let width = rect.width
        let height = rect.height

        path.move(to: CGPoint(x: 0, y: height))

        let step: CGFloat = 8
        var x: CGFloat = 0
        let verticalBob = cos(phase * 0.6) * (amplitude * 0.35)

        while x <= width + step {
            let relativeX = x / frequency
            let sine = sin(relativeX + phase) * amplitude + verticalBob
            let y = height - (height * 0.72 + sine)
            path.addLine(to: CGPoint(x: x, y: y))
            x += step
        }

        path.addLine(to: CGPoint(x: width, y: height))
        path.closeSubpath()
        return path
    }
}

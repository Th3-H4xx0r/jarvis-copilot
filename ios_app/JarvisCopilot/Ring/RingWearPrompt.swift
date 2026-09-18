import SwiftUI

/// "Put the ring on" — the sheet a measurement asks for when the ring answers
/// that nothing is on the finger.
///
/// Modelled on the AirPods pairing card: one instruction, the product itself
/// shown large and moving, and nothing else competing. It dismisses itself the
/// moment a reading comes back, so the person never has to acknowledge it.
struct RingWearPrompt: View {
    let metric: String
    let onCancel: () -> Void

    @State private var slide = false
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(action: onCancel) {
                    JcIcon("xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)

            Text("Put the ring on")
                .font(.title2.weight(.semibold))
                .padding(.top, 2)

            stage
                .frame(height: 210)
                .padding(.vertical, 10)

            Text("Wear the ring on your finger, then it will take your \(metric.lowercased()) reading.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 28)
                .padding(.bottom, 26)
        }
        .frame(maxWidth: .infinity)
        .background(JcTheme.surfaceAlt, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding(.horizontal, 22)
        .onAppear {
            // Two loops, deliberately out of step so the motion never reads as
            // one mechanical beat.
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { slide = true }
            withAnimation(.easeOut(duration: 2.2).repeatForever(autoreverses: false)) { pulse = true }
        }
    }

    /// The ring, a finger sliding into it, and the blue cue that says "here".
    private var stage: some View {
        ZStack {
            ForEach(0..<2, id: \.self) { index in
                Circle()
                    .stroke(JcTheme.accent.opacity(0.5), lineWidth: 1.5)
                    .frame(width: 96, height: 96)
                    .scaleEffect(pulse ? 1.9 : 0.75)
                    .opacity(pulse ? 0 : 0.7)
                    .animation(.easeOut(duration: 2.2).repeatForever(autoreverses: false)
                                .delay(Double(index) * 1.1), value: pulse)
            }

            RingSceneView(spin: false, entrance: false, pulsing: true, cameraDistance: 5.0)
                .frame(width: 210, height: 210)
                .allowsHitTesting(false)

            finger
                .offset(y: slide ? -6 : 78)
                .opacity(slide ? 1 : 0.35)
        }
        .accessibilityHidden(true)
    }

    /// A stylised finger: a soft white capsule with a rounded tip and a nail,
    /// enough to read as a hand at a glance without pretending to be one.
    private var finger: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(
                    LinearGradient(colors: [Color.white, Color.white.opacity(0.82)],
                                   startPoint: .top, endPoint: .bottom)
                )
                .frame(width: 42, height: 120)
                .overlay(alignment: .top) {
                    Capsule()
                        .fill(Color.white.opacity(0.55))
                        .frame(width: 20, height: 26)
                        .padding(.top, 10)
                        .blendMode(.plusLighter)
                }
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        }
    }
}

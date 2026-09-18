import SwiftUI

/// "Put the ring on" — the sheet a measurement asks for when the ring answers
/// that nothing is on the finger.
///
/// It shows the gesture rather than a diagram: a finger held still while the
/// ring comes down over it, which is the motion the person is being asked to
/// make. The card takes itself away the moment a reading lands.
struct RingWearPrompt: View {
    let metric: String
    let onDismiss: () -> Void

    @State private var seated = false
    @State private var glow = false

    /// How far above its resting place the ring starts each loop.
    private let travel: CGFloat = 58

    var body: some View {
        VStack(spacing: 0) {
            Text("Put the ring on")
                .font(.title2.weight(.semibold))
                .padding(.top, 26)

            Text("Slide it onto your finger and the \(metric.lowercased()) reading starts on its own.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 36)
                .padding(.top, 8)

            stage
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 10)

            Button(action: onDismiss) {
                Text("Not now")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .jcLiquidGlass(in: Capsule(), tint: .clear)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A shade lighter than the page behind it, so the sheet reads as a
        // layer above the screen rather than a hole in it.
        .background(RingWearPrompt.sheetBackground)
    }

    /// Slightly lighter than the app's black page.
    static let sheetBackground = Color(white: 0.07)

    // MARK: The gesture

    private var stage: some View {
        ZStack {
            // The cue sits under the finger's tip, where the ring will land.
            ForEach(0..<2, id: \.self) { index in
                Circle()
                    .stroke(JcTheme.accent.opacity(0.45), lineWidth: 1.5)
                    .frame(width: 82, height: 82)
                    .scaleEffect(glow ? 1.8 : 0.8)
                    .opacity(glow ? 0 : 0.65)
                    .offset(y: 2)
                    .animation(.easeOut(duration: 2.4).repeatForever(autoreverses: false)
                                .delay(Double(index) * 1.2), value: glow)
            }

            FingerView()
                .frame(width: 66, height: 146)
                .offset(y: 26)

            // Above the finger in the stack, so it genuinely passes over it.
            RingSceneView(spin: false, entrance: false, pulsing: seated, cameraDistance: 5.2)
                .frame(width: 140, height: 140)
                .offset(y: seated ? 2 : -travel)
                .scaleEffect(seated ? 1 : 1.06)
                .shadow(color: .black.opacity(0.5), radius: 14, y: 10)
                .allowsHitTesting(false)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) { seated = true }
            withAnimation(.easeOut(duration: 2.4).repeatForever(autoreverses: false)) { glow = true }
        }
        .accessibilityHidden(true)
    }
}

/// A stylised finger: tapered, domed at the tip, with a nail and a knuckle
/// crease. Drawn rather than illustrated so it inherits the app's palette and
/// stays sharp at any size.
private struct FingerView: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            ZStack(alignment: .top) {
                FingerShape()
                    .fill(
                        LinearGradient(
                            colors: [Color.white, Color(white: 0.93), Color(white: 0.78)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        // The soft edge that gives it roundness rather than a cut-out look.
                        FingerShape()
                            .stroke(Color.black.opacity(0.10), lineWidth: 1)
                    )
                    .overlay(alignment: .topLeading) {
                        // A highlight down the left, where the light is.
                        Capsule()
                            .fill(Color.white.opacity(0.75))
                            .frame(width: w * 0.16, height: h * 0.42)
                            .blur(radius: 9)
                            .offset(x: w * 0.22, y: h * 0.12)
                    }

                // Nail.
                RoundedRectangle(cornerRadius: w * 0.16, style: .continuous)
                    .fill(Color(white: 0.99))
                    .frame(width: w * 0.36, height: h * 0.13)
                    .overlay(
                        RoundedRectangle(cornerRadius: w * 0.16, style: .continuous)
                            .stroke(Color.black.opacity(0.06), lineWidth: 0.8)
                    )
                    .padding(.top, h * 0.05)

                // Knuckle crease, low enough to sit below where the ring lands.
                Capsule()
                    .fill(Color.black.opacity(0.07))
                    .frame(width: w * 0.42, height: 2)
                    .padding(.top, h * 0.72)
            }
            .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
        }
    }
}

/// The silhouette: a slight taper towards the tip and a dome on top.
private struct FingerShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let tipWidth = w * 0.72
        let tipInset = (w - tipWidth) / 2
        let domeHeight = tipWidth * 0.62

        var path = Path()
        path.move(to: CGPoint(x: tipInset, y: domeHeight))
        // Dome over the fingertip.
        path.addQuadCurve(to: CGPoint(x: w - tipInset, y: domeHeight),
                          control: CGPoint(x: w / 2, y: -domeHeight * 0.55))
        // Down the right, widening towards the knuckle.
        path.addQuadCurve(to: CGPoint(x: w, y: h),
                          control: CGPoint(x: w - tipInset * 0.2, y: h * 0.6))
        path.addLine(to: CGPoint(x: 0, y: h))
        // Back up the left.
        path.addQuadCurve(to: CGPoint(x: tipInset, y: domeHeight),
                          control: CGPoint(x: tipInset * 0.2, y: h * 0.6))
        path.closeSubpath()
        return path
    }
}

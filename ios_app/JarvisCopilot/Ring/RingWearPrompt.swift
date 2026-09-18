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

    /// One beat: the ring comes in from the right and seats on the finger.
    @State private var seated = false
    @State private var glow = false
    @State private var breathe = false
    @State private var loop: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            Text("Put the ring on")
                .font(.title3.weight(.semibold))
                .padding(.top, 22)

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

            // Sits on the sheet's bottom edge: the home indicator's safe area is
            // the margin, so adding another one left it floating mid-sheet.
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // A shade lighter than the page behind it, so the sheet reads as a
        // layer above the screen rather than a hole in it.
        .background(RingWearPrompt.sheetBackground)
        .onAppear { start() }
        .onDisappear { loop?.cancel() }
    }

    /// Slightly lighter than the app's black page.
    static let sheetBackground = Color(white: 0.07)

    // MARK: The gesture
    //
    // The hand does not move. It reaches in from the left, cut off at the edge
    // the way a hand entering frame is, and the ring travels along the finger
    // from the right until it seats — which is the motion being asked for.

    private var stage: some View {
        GeometryReader { geo in
            let midY = geo.size.height / 2
            // Where the ring comes to rest along the finger.
            let seatX = geo.size.width * 0.46

            ZStack(alignment: .leading) {
                // A slow bloom of the app's accent behind everything, so the
                // stage has somewhere to sit on a near-black sheet.
                Circle()
                    .fill(
                        RadialGradient(colors: [JcTheme.accent.opacity(0.30), .clear],
                                       center: .center, startRadius: 2, endRadius: 150)
                    )
                    .frame(width: 300, height: 300)
                    .blur(radius: 26)
                    .scaleEffect(breathe ? 1.12 : 0.88)
                    .opacity(breathe ? 0.9 : 0.45)
                    .position(x: seatX, y: midY)
                    .animation(.easeInOut(duration: 2.8).repeatForever(autoreverses: true), value: breathe)
                    .allowsHitTesting(false)

                ForEach(0..<2, id: \.self) { index in
                    Circle()
                        .stroke(JcTheme.accent.opacity(0.4), lineWidth: 1.5)
                        .frame(width: 74, height: 74)
                        .scaleEffect(glow ? 1.7 : 0.85)
                        .opacity(glow ? 0 : (seated ? 0.55 : 0))
                        .position(x: seatX, y: midY)
                        .animation(.easeOut(duration: 2.1).repeatForever(autoreverses: false)
                                    .delay(Double(index) * 1.05), value: glow)
                }

                // Pointing right, its base running off the left edge.
                FingerView()
                    .frame(width: 62, height: 168)
                    .rotationEffect(.degrees(90))
                    .frame(width: 168, height: 62)
                    .position(x: geo.size.width * 0.42, y: midY)

                // Threaded on: above the finger in the stack, travelling in
                // along the finger's own axis and stopping where it belongs.
                RingSceneView(spin: false, entrance: false, pulsing: seated, cameraDistance: 5.2)
                    .frame(width: 132, height: 132)
                    .rotationEffect(.degrees(-90))
                    .shadow(color: .black.opacity(0.55), radius: 12, x: -4)
                    .position(x: seated ? seatX : geo.size.width + 90, y: midY)
                    .opacity(seated ? 1 : 0.85)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityHidden(true)
    }

    /// Ring on, hold, back off the right edge, again.
    private func start() {
        withAnimation(.easeOut(duration: 2.1).repeatForever(autoreverses: false)) { glow = true }
        breathe = true
        loop?.cancel()
        loop = Task { @MainActor in
            while !Task.isCancelled {
                withAnimation(.spring(response: 0.75, dampingFraction: 0.85)) { seated = true }
                try? await Task.sleep(for: .milliseconds(1900))
                guard !Task.isCancelled else { return }
                withAnimation(.easeIn(duration: 0.45)) { seated = false }
                try? await Task.sleep(for: .milliseconds(560))
            }
        }
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

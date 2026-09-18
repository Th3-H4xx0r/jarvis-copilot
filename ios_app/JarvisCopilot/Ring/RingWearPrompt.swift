import SwiftUI

/// "Put the ring on" — the sheet a measurement asks for when the ring answers
/// that nothing is on the finger.
///
/// It shows the gesture rather than a diagram: a modelled hand held still while
/// the ring glides down the finger and settles where a ring sits, which is the
/// motion the person is being asked to make. The card takes itself away the
/// moment a reading lands.
struct RingWearPrompt: View {
    let metric: String
    /// Pins the animation for the render harness; nil means the loop drives it.
    var pinnedSeated: Bool?
    let onDismiss: () -> Void

    @State private var breathe = false

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
                .padding(.top, 6)

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
        .onAppear { if pinnedSeated == nil { breathe = true } }
    }

    /// Slightly lighter than the app's black page.
    static let sheetBackground = Color(white: 0.07)

    // MARK: The gesture
    //
    // One SceneKit scene holds the hand and the ring (`RingHandModel`), so the
    // band really does pass around the finger. The stage runs edge to edge: the
    // forearm leaves through the sheet's left side, the way a hand entering
    // frame does.

    private var stage: some View {
        GeometryReader { geo in
            ZStack {
                // A faint breath of the accent behind where the ring settles.
                Circle()
                    .fill(
                        RadialGradient(colors: [JcTheme.accent.opacity(0.16), .clear],
                                       center: .center, startRadius: 2, endRadius: 150)
                    )
                    .frame(width: 300, height: 300)
                    .blur(radius: 26)
                    .scaleEffect(breathe ? 1.12 : 0.88)
                    .opacity(breathe ? 0.5 : 0.22)
                    .position(x: geo.size.width * 0.53, y: geo.size.height * 0.42)
                    .animation(.easeInOut(duration: 2.8).repeatForever(autoreverses: true), value: breathe)
                    .allowsHitTesting(false)

                WearStage(pinnedSeated: pinnedSeated)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The hand and the ring, lit and framed. Built once, when it first appears.
private struct WearStage: View {
    let pinnedSeated: Bool?
    @State private var stage: RingHandModel.Stage?

    var body: some View {
        Group {
            if let stage {
                // 60 fps: the glide is the whole point, and the sheet is brief.
                SceneCanvas(scene: stage.scene, camera: stage.camera,
                            rendersContinuously: pinnedSeated == nil, preferredFramesPerSecond: 60)
            } else {
                Color.clear
            }
        }
        .onAppear {
            guard stage == nil else { return }
            let ring = RingModel.makeNode()
            let built = RingHandModel.Stage(ring: ring.pivot, accent: UIColor(JcTheme.accent).cgColor)
            if let pinnedSeated { built.pose(seated: pinnedSeated) } else { built.play() }
            stage = built
        }
    }
}

import SceneKit
import SwiftUI

/// What the wear sheet asks to be put on.
enum WearPromptKind {
    case ring, band

    var title: String { self == .ring ? "Put the ring on" : "Put the band on" }

    func message(_ metric: String) -> String {
        // "heart rate", but "ECG".
        let name = metric == metric.uppercased() ? metric : metric.lowercased()
        switch self {
        case .ring: return "Slide it onto your finger and the \(name) reading starts on its own."
        case .band: return "Slide it over your hand onto your wrist and the \(name) reading starts on its own."
        }
    }

    /// Where on the stage it settles, as a fraction of the stage: the accent breathes behind it.
    var settles: UnitPoint { self == .ring ? UnitPoint(x: 0.53, y: 0.42) : UnitPoint(x: 0.22, y: 0.52) }
}

/// "Put the ring on" (or the band) — the sheet a measurement asks for when the
/// wearable answers that it isn't being worn.
///
/// It shows the gesture rather than a diagram: a modelled hand held still while
/// the ring glides down the finger and settles where a ring sits — or the band
/// comes over the hand and closes round the wrist — which is the motion the
/// person is being asked to make. The card takes itself away the moment a
/// reading lands.
struct RingWearPrompt: View {
    let metric: String
    var kind: WearPromptKind = .ring
    /// Pins the animation for the render harness; nil means the loop drives it.
    var pinnedSeated: Bool?
    let onDismiss: () -> Void

    @State private var breathe = false

    var body: some View {
        VStack(spacing: 0) {
            Text(kind.title)
                .font(.title3.weight(.semibold))
                .padding(.top, 22)

            Text(kind.message(metric))
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
                // A faint breath of the accent behind where it settles.
                Circle()
                    .fill(
                        RadialGradient(colors: [JcTheme.accent.opacity(0.16), .clear],
                                       center: .center, startRadius: 2, endRadius: 150)
                    )
                    .frame(width: 300, height: 300)
                    .blur(radius: 26)
                    .scaleEffect(breathe ? 1.12 : 0.88)
                    .opacity(breathe ? 0.5 : 0.22)
                    .position(x: geo.size.width * kind.settles.x, y: geo.size.height * kind.settles.y)
                    .animation(.easeInOut(duration: 2.8).repeatForever(autoreverses: true), value: breathe)
                    .allowsHitTesting(false)

                WearStage(kind: kind, pinnedSeated: pinnedSeated)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityHidden(true)
    }
}

/// What a wear stage is to the sheet: a scene, its camera, a held pose and the loop.
private protocol WearScene: AnyObject {
    var scene: SCNScene { get }
    var camera: SCNNode { get }
    func pose(seated: Bool)
    func play()
}

extension RingHandModel.Stage: WearScene {}
extension BandHandModel.Stage: WearScene {}

/// The hand and the ring (or the band), lit and framed. Built once, when it first appears.
private struct WearStage: View {
    let kind: WearPromptKind
    let pinnedSeated: Bool?
    @State private var stage: (any WearScene)?
    /// Fades the scene in once it exists, so a slow first build never pops.
    @State private var shown = false

    var body: some View {
        Group {
            if let stage {
                // 60 fps: the glide is the whole point, and the sheet is brief.
                // Always continuous: the sheet is brief, and an on-demand view
                // can sit undrawn until something nudges it.
                SceneCanvas(scene: stage.scene, camera: stage.camera,
                            rendersContinuously: true, preferredFramesPerSecond: 60)
            } else {
                Color.clear
            }
        }
        .opacity(shown || pinnedSeated != nil ? 1 : 0)
        .animation(.easeOut(duration: 0.35), value: shown)
        .onAppear {
            guard stage == nil, let hand = RingHandModel.bundled else { return }
            let accent = UIColor(JcTheme.accent).cgColor
            let built: any WearScene
            switch kind {
            case .ring:
                built = RingHandModel.Stage(ring: RingModel.makeNode().pivot, hand: hand, accent: accent)
            case .band:
                guard let band = BandHandModel.Stage(band: BandModel.makeNode(), hand: hand, accent: accent)
                else { return }
                built = band
            }
            if let pinnedSeated { built.pose(seated: pinnedSeated) } else { built.play() }
            stage = built
            shown = true
        }
    }
}

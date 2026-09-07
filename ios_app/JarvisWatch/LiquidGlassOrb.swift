import SwiftUI

/// The phone's orb on the wrist — the REAL shader output.
///
/// watchOS has no SwiftUI shader effects, so `OrbShader.metal` cannot run here.
/// Its `setupOrb` is rendered offline on the Mac and one frame ships in the
/// bundle: identical pixels, produced by identical code.
///
/// It is a STILL, breathed with a scale animation, deliberately. Playing a
/// frame sequence meant decoding images on the main actor every tick, which
/// froze the watch solid — the UI stopped answering touches. The phone's orb
/// drifts slowly enough that a still with a gentle pulse reads as the same
/// object, and it costs nothing.
struct LiquidGlassOrb: View {
    /// The shader draws the sphere at 53% of its surface, exactly as on iOS.
    static let fill: CGFloat = 0.53

    /// Visible sphere diameter.
    let size: CGFloat
    var animating = true
    /// 0…1. Swells the sphere with the voice.
    var audioLevel: Double = 0

    @State private var breathing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var surface: CGFloat { size / Self.fill }

    var body: some View {
        Group {
            if let image = OrbFrames.still {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Color.clear
            }
        }
        .frame(width: surface, height: surface)
        // Two cheap, additive motions: a slow breath, and a swell with the
        // voice. Both are handled by the render server, not by us.
        .scaleEffect((breathing ? 1.03 : 0.985) + 0.10 * audioLevel)
        .animation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true), value: breathing)
        .animation(.easeOut(duration: 0.18), value: audioLevel)
        .onAppear { if animating && !reduceMotion { breathing = true } }
        .accessibilityHidden(true)
    }
}

/// The single bundled orb frame, decoded once, lazily.
enum OrbFrames {
    static let still: UIImage? = {
        guard let url = Bundle.main.url(forResource: "orb-000", withExtension: "png",
                                        subdirectory: "OrbFrames")
                ?? Bundle.main.url(forResource: "orb-000", withExtension: "png"),
              let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }()
}

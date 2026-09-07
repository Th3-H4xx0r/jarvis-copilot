import SwiftUI

/// The phone's orb on the wrist — the REAL shader output, not a lookalike.
///
/// watchOS has no SwiftUI shader effects (`colorEffect` / `ShaderLibrary` are
/// unavailable), so the phone's `OrbShader.metal` cannot run here. Instead its
/// `setupOrb` is rendered offline on the Mac across the shader's own 38.4 s
/// loop and the frames ship in the bundle: identical pixels, produced by
/// identical code. Re-render with the harness in `docs/` whenever the shader
/// changes.
///
/// Neighbouring frames differ only slightly (the liquid drifts a few percent),
/// so cross-fading between them reads as continuous motion rather than a
/// slideshow, at a fraction of the frames a true animation would need.
struct LiquidGlassOrb: View {
    /// The shader draws the sphere at 53% of its surface, exactly as on iOS.
    static let fill: CGFloat = 0.53
    /// The shader's outer loop; the frames span exactly this, so it seams.
    static let loop: Double = 38.4
    static let frameCount = 36

    /// Visible sphere diameter.
    let size: CGFloat
    var animating = true
    /// 0…1. Expands the sphere with the voice; never speeds the artwork up.
    var audioLevel: Double = 0

    @State private var envelope = OrbEnvelope()
    @State private var origin = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var surface: CGFloat { size / Self.fill }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20,
                                paused: !animating || reduceMotion || scenePhase != .active)) { timeline in
            let elapsed = timeline.date.timeIntervalSince(origin)
            let position = reduceMotion ? 0 : elapsed.truncatingRemainder(dividingBy: Self.loop)
            let exact = position / Self.loop * Double(Self.frameCount)
            let index = Int(exact) % Self.frameCount
            let next = (index + 1) % Self.frameCount
            let blend = exact - exact.rounded(.down)
            let pulse = reduceMotion ? 0 : envelope.update(target: audioLevel, t: elapsed)

            ZStack {
                Self.frame(index)
                Self.frame(next).opacity(blend)
            }
            .frame(width: surface, height: surface)
            .scaleEffect(1 + 0.10 * pulse)
        }
        .frame(width: surface, height: surface)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private static func frame(_ index: Int) -> some View {
        if let image = OrbFrames.image(index) {
            Image(uiImage: image).resizable().scaledToFit()
        } else {
            Color.clear
        }
    }
}

/// Decodes the bundled frames once and keeps them; 36 small PNGs are cheap to
/// hold and decoding one per displayed frame would stutter.
enum OrbFrames {
    private static var cache: [Int: UIImage] = [:]

    static func image(_ index: Int) -> UIImage? {
        if let hit = cache[index] { return hit }
        let name = String(format: "orb-%03d", index)
        guard let url = Bundle.main.url(forResource: name, withExtension: "png",
                                        subdirectory: "OrbFrames")
                ?? Bundle.main.url(forResource: name, withExtension: "png"),
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else { return nil }
        cache[index] = image
        return image
    }
}

/// Attack/release smoothing so the orb swells with speech and settles gently
/// instead of snapping frame to frame. Mirrors the phone's `VoiceOrbEnvelope`.
@Observable
final class OrbEnvelope {
    private var value = 0.0
    private var lastT = 0.0
    private let attack = 0.06
    private let release = 0.28

    func update(target: Double, t: Double) -> Double {
        // A paused ticker (wrist down, another app) resumes with a huge gap;
        // clamping it eases the level instead of snapping.
        let dt = min(max(t - lastT, 0), 0.1)
        lastT = t
        let tau = target > value ? attack : release
        let k = min(max(1 - exp(-dt / max(tau, 1e-3)), 0), 1)
        value += (target - value) * k
        return value
    }
}

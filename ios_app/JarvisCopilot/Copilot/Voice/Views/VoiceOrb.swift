import SwiftUI

#if JC_MAC_VOICE
/// Where `OrbShader.metal` was compiled to.
///
/// The bare `ShaderLibrary.setupOrb` the app uses resolves against the MAIN
/// bundle's default library. In the Mac client the main bundle belongs to the
/// Python tray that loaded this dylib and has no shaders at all, so the orb's
/// library has to be asked for by name — see `macVoiceResourceBundle` for how
/// it is found, and `mac_app/build.sh` for what compiles it (SwiftPM copies
/// `.metal` files into a bundle but never runs the Metal compiler on them).
private let orbShaders = macVoiceResourceBundle.map(ShaderLibrary.bundle) ?? .default
#else
private let orbShaders = ShaderLibrary.default
#endif

/// The same liquid surfaces and crisp glass shell used on the setup screen.
/// Audio adds a small, smoothed expansion; it never rotates the artwork faster.
struct VoiceOrb: View {
    let state: VoiceState
    let amplitude: Double
    var size: CGFloat = 248
    var animating = true
    var body: some View {
        LiquidGlassOrb(size: size / 0.53, animating: animating,
                       audioLevel: VoiceOrbGeometry.speechPulse(state: state, amplitude: amplitude))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Shared rendering keeps onboarding and voice visually identical. `size` is
/// the shader surface; the visible sphere occupies 53% of that surface.
struct LiquidGlassOrb: View {
    let size: CGFloat
    var animating = true
    var audioLevel: Double = 0
    @State private var envelope = VoiceOrbEnvelope()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var origin = Date()

    #if JC_MAC_VOICE
    /// A SwiftUI view hosted by AppKit has no `Scene`, so `scenePhase` reads
    /// `.background` for the life of the process — gating the ticker on it would
    /// freeze the orb on its first frame, silently. On the Mac the caller's
    /// `animating` is the whole gate: the panel raises it while it is on screen.
    private var sceneActive: Bool { true }
    #else
    @Environment(\.scenePhase) private var scenePhase
    private var sceneActive: Bool { scenePhase == .active }
    #endif

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60,
                                paused: !animating || reduceMotion || !sceneActive)) { timeline in
            let elapsed = timeline.date.timeIntervalSince(origin)
            let t = reduceMotion ? 0 : elapsed.truncatingRemainder(dividingBy: 38.4)
            let pulse = reduceMotion ? 0 : envelope.update(target: audioLevel, t: elapsed)
            Rectangle()
                .fill(.white)
                .colorEffect(orbShaders.setupOrb(.float2(size, size), .float(t)))
                .scaleEffect(1 + 0.10 * pulse)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

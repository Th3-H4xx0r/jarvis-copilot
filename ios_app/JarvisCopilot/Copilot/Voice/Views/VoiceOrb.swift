import SwiftUI

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
    @Environment(\.scenePhase) private var scenePhase
    @State private var origin = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60,
                                paused: !animating || reduceMotion || scenePhase != .active)) { timeline in
            let elapsed = timeline.date.timeIntervalSince(origin)
            let t = reduceMotion ? 0 : elapsed.truncatingRemainder(dividingBy: 38.4)
            let pulse = reduceMotion ? 0 : envelope.update(target: audioLevel, t: elapsed)
            Rectangle()
                .fill(.white)
                .colorEffect(ShaderLibrary.setupOrb(.float2(size, size), .float(t)))
                .scaleEffect(1 + 0.10 * pulse)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

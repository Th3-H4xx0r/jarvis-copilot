import Foundation

/// The maths behind the voice orb: the amplitude envelope that turns how loud
/// the speech is into how much the glass globe pulses. Kept out of the view so
/// the curve can be asserted without a renderer.
enum VoiceOrbGeometry {

    /// One-pole envelope constants (seconds). Fast attack, quickish release, so
    /// the orb throbs with the rhythm of speech — rising on a syllable, dropping
    /// between — rather than holding at the peak.
    static let attack = 0.05
    static let release = 0.16

    /// Advance the smoothed amplitude by `dt` seconds toward `target`.
    static func smooth(previous: Double, target: Double, dt: Double) -> Double {
        let tau = target > previous ? attack : release
        let k = min(max(1 - exp(-dt / max(tau, 1e-3)), 0), 1)
        return previous + (target - previous) * k
    }

    /// Perceptual gain makes quiet speech visible without scaling the audio.
    /// Idle keeps the shader's own breathing; both speakers drive the same pulse.
    static func speechPulse(state: VoiceState, amplitude: Double) -> Double {
        guard state == .listening || state == .speaking, amplitude.isFinite else { return 0 }
        return min(pow(min(max(amplitude - 0.003, 0), 1), 0.35) * 1.2, 1)
    }
}

/// The orb's smoothed amplitude, kept in a reference box so the `Canvas` draw
/// closure can advance it without invalidating the view every frame.
@MainActor
final class VoiceOrbEnvelope {
    private var value = 0.0
    private var lastT = 0.0

    /// Advance to `t` seconds and return the smoothed level.
    func update(target: Double, t: Double) -> Double {
        // Clamp dt: a paused ticker (a backgrounded app, another tab) resumes with
        // a huge gap, which would snap the envelope instead of easing it.
        let dt = min(max(t - lastT, 0), 0.1)
        lastT = t
        value = VoiceOrbGeometry.smooth(previous: value, target: target, dt: dt)
        return value
    }
}

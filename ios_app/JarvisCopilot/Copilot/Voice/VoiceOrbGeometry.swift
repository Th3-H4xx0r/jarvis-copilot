import CoreGraphics
import Foundation

/// The maths behind the voice orb — how loud the user is becomes how big, how
/// bright and how fast the glass globe moves.
///
/// Extracted from the `CustomPainter` in `voice/voice_orb.dart` for the same
/// reason `VoiceWaveformModel` was: the envelope curve is the part users actually
/// notice, and it is worth asserting without a renderer. The `Canvas` in
/// `Views/VoiceOrb.swift` owns only the drawing.
enum VoiceOrbGeometry {

    /// Points per ribbon loop. 120 in Flutter; 96 is visually identical at
    /// 248 pt and a fifth cheaper per frame.
    static let loopPoints = 96

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

    /// Only the user's own voice drives the orb; a reply's playback envelope
    /// would make it pulse at the assistant, which reads as feedback.
    static func micDrive(state: VoiceState, amplitude: Double) -> Double {
        state == .listening ? min(max(amplitude, 0), 1) : 0
    }

    /// Baseline per-state liveliness (brightness/glow), independent of mic level.
    static func energy(state: VoiceState, t: Double) -> Double {
        let breath = 0.5 + 0.5 * sin(t * 0.9)
        let talk = 0.5 + 0.5 * sin(t * 2.4)
        switch state {
        case .listening:  return 0.46
        case .speaking:   return 0.55 + 0.20 * talk
        case .thinking:   return 0.58 + 0.10 * breath
        case .connecting: return 0.40 + 0.12 * breath
        case .error:      return 0.34 + 0.08 * breath
        case .idle:       return 0.42 + 0.12 * breath
        }
    }

    /// How much the orb should swell/bloom right now, 0..1. The user's voice
    /// drives it while listening; every other state uses a slow time pulse so the
    /// orb always breathes and never looks frozen.
    static func reactive(state: VoiceState, amplitude: Double, t: Double) -> Double {
        let talk = 0.5 + 0.5 * sin(t * 2.4)
        let pulse = 0.5 + 0.5 * sin(t * 1.7)
        switch state {
        case .listening:
            // Steep saturating curve: even quiet speech gives a clear swell (mic
            // level reads low), while loud input still tops out gracefully near 1.
            return 1 - exp(-5.0 * min(max(amplitude, 0), 1))
        case .speaking:   return min(0.39 + 0.585 * talk, 1)   // +30% peaks
        case .thinking:   return 0.10 + 0.22 * pulse
        case .idle:       return 0.06 + 0.14 * pulse
        case .connecting, .error: return 0.05 + 0.10 * pulse
        }
    }

    /// Continuous spin. Listening is deliberately 0: the orb must only PULSE with
    /// the voice, never whirl, or it competes with the user for attention.
    static func spinSpeed(_ state: VoiceState) -> Double {
        switch state {
        case .thinking:   return 0.08
        case .speaking:   return 0.07
        case .listening:  return 0.0
        case .idle:       return 0.07
        case .connecting: return 0.06
        case .error:      return 0.05
        }
    }

    /// How fast the ribbons undulate ("silk flow").
    static func undulationRate(_ state: VoiceState) -> Double {
        switch state {
        case .thinking:   return 0.34
        case .speaking:   return 0.30
        case .listening:  return 0.10 // faint shimmer so it isn't dead-frozen
        case .idle:       return 0.32
        case .connecting: return 0.28
        case .error:      return 0.24
        }
    }

    /// Slow organic sway added to the spin so the ribbons never look like a
    /// uniformly rotating cage.
    static func wander(_ t: Double) -> Double {
        0.20 * sin(t * 0.13) + 0.12 * sin(t * 0.22 + 2.1)
    }

    /// Projected sphere radius. `base` is half the view's shortest side.
    static func radius(base: CGFloat, reactive: Double, t: Double) -> CGFloat {
        let breath = 0.5 + 0.5 * sin(t * 0.9)
        let scale = 1.0 + 0.025 * breath + 0.52 * reactive   // +30% swell on speech
        return base * 0.53 * scale
    }

    /// The outer halo blooms outward with the voice.
    static func haloRadius(_ radius: CGFloat, reactive: Double) -> CGFloat {
        radius * (1.50 + 0.30 * reactive)
    }

    /// Overall light level, 0..1.45.
    static func brightness(energy: Double, reactive: Double) -> Double {
        min(max(0.80 + 0.28 * energy + 0.36 * reactive, 0), 1.45)
    }

    /// Half-width of a ribbon band before the per-point depth term.
    static func ribbonHalfWidth(_ radius: CGFloat, reactive: Double) -> CGFloat {
        radius * 0.17 * (1.0 + 0.45 * reactive)
    }

    /// One ribbon: a wavy loop on a unit sphere, tilted in 3D.
    struct Strand: Sendable {
        let amp: Double
        let waves: Int
        let phase: Double
        let rx: Double
        let ry: Double
        let rz: Double
    }

    static let strands: [Strand] = [
        Strand(amp: 0.20, waves: 2, phase: 0.0, rx: 0.55, ry: 0.30, rz: 0.15),
        Strand(amp: 0.26, waves: 2, phase: 2.1, rx: 0.72, ry: 0.58, rz: 0.10),
        Strand(amp: 0.18, waves: 1, phase: 4.2, rx: 0.42, ry: 0.85, rz: 0.22),
    ]
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

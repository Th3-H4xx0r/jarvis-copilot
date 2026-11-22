import Foundation

/// A part of the Ray-Ban Meta the simulator is exercising right now, so the 3D model can glide the
/// camera to it and mark it (his ask, 2026-11-22: "pans and zooms into the element and shows an
/// indicator there when that part of the glasses is being simulated").
enum MetaGlassesPart: String, CaseIterable, Sendable {
    /// The 12 MP camera in the wearer's left end piece.
    case camera
    /// The white capture LED in the wearer's right end piece.
    case led
    /// The mic array (nose bridge + temples near the hinges) — listening.
    case mic
    /// The open-ear speakers under both temples, just ahead of the ears — Jarvis speaking, volume.
    case speakers
    /// The touchpad on the outer side of the right temple.
    case touchpad
    /// The capture button on top of the right temple.
    case captureButton
}

/// How the marked part pulses.
enum MetaGlassesPulse: String, Sendable {
    /// Blue, breathing — the mics are listening.
    case listening
    /// Blue, rippling outward — the speakers are playing Jarvis's voice.
    case speaking
    /// One white flash — a photo.
    case capture
    /// Steady white breathing while a clip records or the live stream runs.
    case recording
    /// One quick ripple — a tap, swipe or button press.
    case touch
}

/// What the model should show: which part, and how it pulses. Nil = the idle turntable.
struct MetaGlassesFocus: Equatable, Sendable {
    var part: MetaGlassesPart
    var pulse: MetaGlassesPulse
}

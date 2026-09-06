import Foundation

/// The level/geometry model behind the flowing multi-line audio waveform (the
/// Siri-style ribbon) from `voice/voice_waveform.dart`. Several overlaid sine
/// bands of slightly different frequency/phase, their amplitude driven by the
/// mic RMS while listening / the playback envelope while speaking.
///
/// Only the DATA lives here — the `Canvas` that strokes it is the second-wave
/// agent's view. Keeping the maths out of the painter makes the envelope curve
/// (the part users actually notice) unit-testable.
enum VoiceWaveformModel {

    /// Points per band. Fewer steps = cheaper repaint (was 64 in Flutter).
    static let steps = 44

    /// Fraction of the view height one band may swing at full envelope.
    static let heightFraction = 0.38

    struct Band: Equatable, Sendable {
        /// Index into `VoiceState.palette` — bands are tinted across the
        /// iridescent range so the ribbon matches the orb.
        let paletteIndex: Int
        let ampScale: Double
        let freqScale: Double
        let phase: Double
    }

    static let bands: [Band] = [
        Band(paletteIndex: 1, ampScale: 1.0, freqScale: 1.0, phase: 0.0), // mid colour, base freq
        Band(paletteIndex: 0, ampScale: 0.7, freqScale: 1.6, phase: 1.3), // inner, higher freq
        Band(paletteIndex: 3, ampScale: 0.5, freqScale: 0.7, phase: 2.4), // rim, lower freq
    ]

    /// Listening/speaking swell with amplitude so the ribbon visibly reacts to
    /// the voice; idle/connecting/thinking have gentle self-motion instead.
    static func isReactive(_ state: VoiceState) -> Bool {
        state == .listening || state == .speaking
    }

    /// Vertical scale for this frame. A gentle sqrt curve lifts quiet speech and
    /// a higher ceiling makes loud speech swing wide.
    static func envelope(state: VoiceState, amplitude: Double, t: Double) -> Double {
        guard isReactive(state) else { return 0.16 + 0.05 * sin(t * 2.0) }
        let amp = min(max(amplitude, 0), 1)
        return min(max(0.18, sqrt(amp) * 1.35), 1.4)
    }

    /// Vertical offset as a FRACTION OF THE VIEW HEIGHT at each of `steps + 1`
    /// evenly-spaced x positions. The view draws `y = midY + offset * height`.
    /// Amplitude tapers toward the edges so the ribbon pinches at the ends.
    static func offsets(band: Band, t: Double, env: Double) -> [Double] {
        (0...steps).map { i in
            let nx = Double(i) / Double(steps)
            let taper = sin(nx * .pi)
            let wave = sin(nx * .pi * 2 * (2.2 * band.freqScale)
                           + t * 3.0 * band.freqScale + band.phase)
            return wave * taper * heightFraction * env * band.ampScale
        }
    }
}

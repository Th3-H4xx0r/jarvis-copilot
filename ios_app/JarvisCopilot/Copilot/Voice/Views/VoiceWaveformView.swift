import SwiftUI

/// The flowing multi-line audio waveform under the orb (the Siri-style ribbon).
/// Port of `voice/voice_waveform.dart`'s painter; every number it draws comes
/// from ``VoiceWaveformModel``, which is already unit-tested.
struct VoiceWaveformView: View {
    let state: VoiceState
    /// 0..1 — mic RMS while listening, playback envelope while speaking.
    let amplitude: Double
    var height: CGFloat = 84
    /// False freezes the ticker (see `orbTickerEnabled`).
    var animating: Bool = true

    @State private var origin = Date()

    var body: some View {
        TimelineView(.animation(paused: !animating)) { timeline in
            let t = timeline.date.timeIntervalSince(origin)
            Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                draw(&context, size, t: t)
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    private func draw(_ context: inout GraphicsContext, _ size: CGSize, t: Double) {
        guard size.width > 0, size.height > 0 else { return }
        let palette = state.palette
        let middle = size.height / 2
        let env = VoiceWaveformModel.envelope(state: state, amplitude: amplitude, t: t)
        let steps = VoiceWaveformModel.steps

        for band in VoiceWaveformModel.bands {
            let offsets = VoiceWaveformModel.offsets(band: band, t: t, env: env)
            var path = Path()
            for (i, offset) in offsets.enumerated() {
                let x = size.width * CGFloat(i) / CGFloat(steps)
                let y = middle + CGFloat(offset) * size.height
                let point = CGPoint(x: x, y: y)
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            let colour = palette[min(band.paletteIndex, palette.count - 1)]
            context.stroke(path, with: .color(colour.opacity(0.85)),
                           style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
    }
}

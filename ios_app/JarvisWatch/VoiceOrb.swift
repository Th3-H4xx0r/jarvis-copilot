import SwiftUI

/// The JARVIS voice orb, on the wrist.
///
/// This is the PHONE's orb, not a lookalike: it runs the same
/// `OrbShader.metal` (`setupOrb`) through a SwiftUI shader effect, so the
/// liquid-glass sphere on the watch is the identical object. It replaces a
/// hand-drawn Canvas approximation — flowing ribbons on a dark disc — that
/// never really matched.
struct VoiceOrb: View {
    enum Mode: Equatable { case idle, thinking, speaking, error }

    var mode: Mode
    var size: CGFloat = 96
    /// 0…1 from playback, so the sphere breathes with the reply.
    var level: Double = 0

    /// Liveliness when there is no measured level to follow, so "thinking" and
    /// "speaking" read differently from a resting orb.
    private var drive: Double {
        switch mode {
        case .idle:     return 0
        case .thinking: return 0.22
        case .speaking: return max(level, 0.35)
        case .error:    return 0
        }
    }

    var body: some View {
        LiquidGlassOrb(size: size, animating: mode != .error, audioLevel: drive)
            .frame(width: size, height: size)
            // The shader surface is nearly twice the sphere it draws, and that
            // transparent bleed still swallowed touches: the orb sat invisibly
            // over the controls below it, so Volume/Chats/Menu did nothing
            // until a reply re-laid the screen out. Clip the drawing AND pin
            // the hit area to the sphere itself.
            .clipped()
            .contentShape(Circle())
            // An error still shows the orb, dimmed and drained, rather than
            // swapping in a different shape.
            .opacity(mode == .error ? 0.55 : 1)
            .saturation(mode == .error ? 0.25 : 1)
    }
}

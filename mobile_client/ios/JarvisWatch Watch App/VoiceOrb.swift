import SwiftUI

/// Animated JARVIS voice orb — a glowing gradient sphere whose colour, icon and
/// motion reflect the current state. The hero element of the watch UI.
struct VoiceOrb: View {
    enum Mode: Equatable { case idle, thinking, speaking, error }
    var mode: Mode
    var size: CGFloat = 96

    @State private var pulse = false
    @State private var spin = false

    // JARVIS palette
    private static let gold  = Color(red: 0.96, green: 0.72, blue: 0.27)
    private static let amber = Color(red: 0.88, green: 0.33, blue: 0.17)
    private static let blue  = Color(red: 0.49, green: 0.73, blue: 1.00)
    private static let red   = Color(red: 1.00, green: 0.48, blue: 0.54)

    private var fill: [Color] {
        switch mode {
        case .error:    return [Self.red, Color(red: 0.55, green: 0.12, blue: 0.18)]
        case .thinking: return [Self.blue, Self.amber]
        default:        return [Self.gold, Self.amber]
        }
    }
    private var icon: String {
        switch mode {
        case .idle:     return "mic.fill"
        case .thinking: return "sparkles"
        case .speaking: return "waveform"
        case .error:    return "exclamationmark.triangle.fill"
        }
    }

    var body: some View {
        ZStack {
            // soft outer glow
            Circle()
                .fill(RadialGradient(colors: [fill.first!.opacity(0.55), .clear],
                                     center: .center, startRadius: 1, endRadius: size * 0.75))
                .blur(radius: 8)
                .scaleEffect(pulse ? 1.18 : 0.92)

            // core sphere with a top-left highlight
            Circle()
                .fill(RadialGradient(colors: fill, center: UnitPoint(x: 0.38, y: 0.32),
                                     startRadius: 1, endRadius: size * 0.55))
                .overlay(
                    Circle()
                        .stroke(AngularGradient(
                            colors: [fill.first!.opacity(0.1), .white.opacity(0.85),
                                     fill.last!.opacity(0.2), fill.first!.opacity(0.1)],
                            center: .center), lineWidth: 2.5)
                        .opacity(mode == .thinking ? 1 : 0.4)
                        .rotationEffect(.degrees(spin ? 360 : 0))
                )
                .scaleEffect(pulse ? 1.05 : 0.95)
                .shadow(color: fill.first!.opacity(0.5), radius: 8)

            Image(systemName: icon)
                .font(.system(size: size * 0.3, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .onAppear {
            withAnimation(.easeInOut(duration: mode == .speaking ? 0.45 : 1.5)
                .repeatForever(autoreverses: true)) { pulse = true }
            withAnimation(.linear(duration: 3.5).repeatForever(autoreverses: false)) { spin = true }
        }
    }
}

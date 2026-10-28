import SwiftUI

/// The Voice orb (`OrbShader.metal`'s liquid-glass bubble) for the Dynamic Island and Lock
/// Screen card, where no shader runs: a glass bubble (dark body, bright rim, top highlight,
/// warm edge), a blue liquid band, faint stars and a soft glow. Still — a Live Activity
/// plays no SF Symbol effect or SwiftUI animation (probed 2026-10-27); the motion round it
/// is `JarvisPulse`, built on the system's own timers.
struct JarvisLiveOrb: View {
    var size: CGFloat
    /// The glow round it: the voice state's colour, or the orb's own blue.
    var glow: Color = JarvisLiveOrb.blue

    static let blue = Color(red: 0.24, green: 0.40, blue: 1.0)
    private static let deep = Color(red: 0.07, green: 0.13, blue: 0.55)
    private static let warm = Color(red: 0.98, green: 0.52, blue: 0.20)
    /// The rim's bluish white.
    private static let glass = Color(red: 0.78, green: 0.87, blue: 1.0)

    var body: some View {
        ZStack {
            halo
            // The bubble: dark glass, a touch lighter where the light comes in.
            Circle().fill(RadialGradient(colors: [Color(red: 0.06, green: 0.08, blue: 0.22), Color(red: 0.01, green: 0.01, blue: 0.05)],
                                         center: UnitPoint(x: 0.42, y: 0.36), startRadius: 0, endRadius: size * 0.56))
            ZStack {
                liquid
                stars
            }
            // The full bubble, or the clip takes the stars' tiny bounds.
            .frame(width: size, height: size)
            .clipShape(Circle())
            // The warm glint low on the right edge, as in the app's orb.
            Circle()
                .trim(from: 0.94, to: 1.1)
                .stroke(Self.warm.opacity(0.9), style: StrokeStyle(lineWidth: size * 0.06, lineCap: .round))
                .rotationEffect(.degrees(20))
                .blur(radius: size * 0.03)
                .padding(size * 0.04)
            Circle().trim(from: 0, to: 0.08)
                .stroke(Self.warm.opacity(0.7), style: StrokeStyle(lineWidth: size * 0.05, lineCap: .round))
                .rotationEffect(.degrees(20))
                .blur(radius: size * 0.03)
                .padding(size * 0.04)
            // Glass: a thin bright rim, lit from the top, and the curved highlight under it.
            Circle()
                .strokeBorder(LinearGradient(colors: [Self.glass.opacity(0.95), Self.glass.opacity(0.25), Self.glass.opacity(0.6)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: max(0.8, size * 0.02))
            Circle()
                .trim(from: 0.6, to: 0.9)
                .stroke(LinearGradient(colors: [.white.opacity(0), .white.opacity(0.85), .white.opacity(0)],
                                       startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: max(1, size * 0.04), lineCap: .round))
                .padding(size * 0.09)
                .blur(radius: size * 0.006)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// A soft glow.
    private var halo: some View {
        Circle()
            .fill(glow.opacity(0.4))
            .frame(width: size * 1.02, height: size * 1.02)
            .blur(radius: size * 0.1)
    }

    /// The liquid: a soft blue band across the middle, tilted like the shader's wave.
    private var liquid: some View {
        ZStack {
            Capsule()
                .fill(LinearGradient(colors: [Self.blue.opacity(0.85), Self.deep.opacity(0.8)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: size * 1.3, height: size * 0.3)
                .blur(radius: size * 0.07)
                .offset(y: size * 0.1)
            Capsule()
                .fill(Self.deep.opacity(0.55))
                .frame(width: size * 1.1, height: size * 0.34)
                .blur(radius: size * 0.1)
                .offset(y: size * 0.34)
        }
        .rotationEffect(.degrees(-18))
    }

    /// The faint stars scattered in the app's orb.
    private var stars: some View {
        ZStack {
            ForEach(Array(Self.starSpots.enumerated()), id: \.offset) { index, spot in
                star(index).offset(x: spot.x * size, y: spot.y * size)
            }
        }
    }

    private static let starSpots: [CGPoint] = [
        CGPoint(x: -0.2, y: 0.02), CGPoint(x: -0.05, y: -0.06), CGPoint(x: 0.1, y: 0.0),
        CGPoint(x: 0.22, y: 0.05), CGPoint(x: -0.12, y: 0.12), CGPoint(x: 0.04, y: 0.1),
    ]

    private func star(_ index: Int) -> some View {
        let d = max(1.2, size * (index % 2 == 0 ? 0.044 : 0.032))
        return Circle().fill(.white.opacity(index % 3 == 0 ? 0.55 : 0.75)).frame(width: d, height: d)
    }
}

import SwiftUI

/// Shared styling for the watch app, mirroring the mobile "dark glass +
/// iridescent" look: the Inter typeface and an ambient near-black backdrop with
/// faint aurora glows.
enum JcWatch {
    // Text
    static let text = Color(red: 0.93, green: 0.94, blue: 0.97)
    static let muted = Color(red: 0.72, green: 0.75, blue: 0.81)

    /// Ambient backdrop: near-black with a couple of very faint colour washes,
    /// matching the mobile voice screen (kept subtle for OLED battery).
    static var background: some View {
        ZStack {
            Color.black
            LinearGradient(
                colors: [Color(red: 0.04, green: 0.05, blue: 0.07), .black],
                startPoint: .top, endPoint: .bottom)
            RadialGradient(
                colors: [Color(red: 0.12, green: 0.66, blue: 0.61).opacity(0.16), .clear],
                center: .topLeading, startRadius: 2, endRadius: 160)
            RadialGradient(
                colors: [Color(red: 0.18, green: 0.42, blue: 1.0).opacity(0.12), .clear],
                center: .bottomTrailing, startRadius: 2, endRadius: 170)
        }
        .ignoresSafeArea()
    }
}

extension Font {
    /// App typeface = Inter (registered at launch in JarvisWatchApp). Inter's
    /// Medium/SemiBold ship under their OWN family names ("Inter Medium" etc.),
    /// so `.custom("Inter").weight(.medium)` would silently fall back to Regular.
    /// Reference each face by its exact PostScript name instead.
    static func inter(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let face: String
        switch weight {
        case .bold, .heavy, .black: face = "Inter-Bold"
        case .semibold: face = "Inter-SemiBold"
        case .medium: face = "Inter-Medium"
        default: face = "Inter-Regular"
        }
        return .custom(face, size: size)
    }
}

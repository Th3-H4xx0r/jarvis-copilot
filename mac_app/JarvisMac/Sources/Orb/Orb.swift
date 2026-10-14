import SwiftUI

/// The orb's look of the moment: the usual one, or a seasonal colouring picked
/// by date (or chosen in Settings). Jarvis's orb takes Mochi's place, so the
/// seasons are colours, not outfits.
enum OrbSkin: String, CaseIterable, Identifiable {
    case standard, winter, newYear, spring, summer, autumn, midnight, ember

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "Jarvis"
        case .winter: return "Winter"
        case .newYear: return "New Year"
        case .spring: return "Spring"
        case .summer: return "Summer"
        case .autumn: return "Autumn"
        case .midnight: return "Midnight"
        case .ember: return "Ember"
        }
    }

    /// The core / rim colours the orb is drawn with.
    var colors: (Color, Color) {
        switch self {
        case .standard: return (Color(red: 0.24, green: 0.78, blue: 0.78), Color(red: 0.11, green: 0.36, blue: 0.62))
        case .winter: return (Color(red: 0.80, green: 0.92, blue: 1.0), Color(red: 0.29, green: 0.47, blue: 0.86))
        case .newYear: return (Color(red: 1.0, green: 0.84, blue: 0.40), Color(red: 0.75, green: 0.30, blue: 0.85))
        case .spring: return (Color(red: 0.64, green: 0.93, blue: 0.62), Color(red: 0.98, green: 0.56, blue: 0.74))
        case .summer: return (Color(red: 1.0, green: 0.78, blue: 0.30), Color(red: 1.0, green: 0.40, blue: 0.30))
        case .autumn: return (Color(red: 1.0, green: 0.58, blue: 0.20), Color(red: 0.55, green: 0.20, blue: 0.10))
        case .midnight: return (Color(red: 0.55, green: 0.50, blue: 1.0), Color(red: 0.10, green: 0.08, blue: 0.30))
        case .ember: return (Color(red: 1.0, green: 0.36, blue: 0.24), Color(red: 0.35, green: 0.04, blue: 0.08))
        }
    }

    /// Seasons by date, as coucou dresses Mochi: New Year Dec 31–Jan 2,
    /// winter Dec 1–30, autumn Oct, summer Jun 21–Aug 31; else the usual look.
    static func auto(for date: Date = Date(), calendar: Calendar = Calendar(identifier: .gregorian)) -> OrbSkin {
        let c = calendar.dateComponents([.month, .day], from: date)
        let m = c.month ?? 1, d = c.day ?? 1
        if (m == 12 && d == 31) || (m == 1 && d <= 2) { return .newYear }
        if m == 12 { return .winter }
        if m == 10 { return .autumn }
        if (m == 6 && d >= 21) || m == 7 || m == 8 { return .summer }
        return .standard
    }

    /// The skin in use: the picked one, or the season's when set to automatic.
    static var current: OrbSkin {
        let raw = UserDefaults.standard.string(forKey: "orb.skin") ?? "auto"
        return OrbSkin(rawValue: raw) ?? .auto()
    }
}

/// What the orb is showing: colour and motion follow the most urgent session.
enum OrbMood: Equatable {
    case idle, working, waiting, finished, error, ratelimit, listening

    var tint: Color? {
        switch self {
        case .idle, .listening: return nil
        case .working: return nil   // the skin's own colours, pulsing
        case .waiting: return Color(red: 0.98, green: 0.75, blue: 0.14)
        case .finished: return Color(red: 0.20, green: 0.83, blue: 0.60)
        case .error: return Color(red: 0.97, green: 0.30, blue: 0.30)
        case .ratelimit: return Color(red: 1.0, green: 0.55, blue: 0.15)
        }
    }

    var pulses: Bool { self == .working || self == .waiting || self == .listening }
}

/// The Jarvis orb, drawn in SwiftUI: a soft glowing sphere whose colour and
/// pulse follow the mood. It animates only while visible (the island hides it
/// when closed), so a resting island draws nothing.
struct OrbView: View {
    var mood: OrbMood = .idle
    var skin: OrbSkin = .current
    var size: CGFloat = 18
    /// 0…1 extra glow, e.g. the music level (the orb "dances").
    var beat: Double = 0

    @State private var phase = false

    var body: some View {
        let (core, rim) = skin.colors
        let tint = mood.tint
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [(tint ?? core).opacity(0.95), (tint ?? rim).opacity(0.85),
                                              (tint ?? rim).opacity(0.25)],
                                     center: .init(x: 0.38, y: 0.32), startRadius: 0,
                                     endRadius: size * 0.62))
            Circle()
                .fill(RadialGradient(colors: [.white.opacity(0.55), .clear],
                                     center: .init(x: 0.34, y: 0.28), startRadius: 0,
                                     endRadius: size * 0.3))
        }
        .frame(width: size, height: size)
        .shadow(color: (tint ?? core).opacity(mood == .idle ? 0.25 : 0.65),
                radius: size * (0.25 + 0.3 * beat + (phase && mood.pulses ? 0.2 : 0)))
        .scaleEffect(mood.pulses ? (phase ? 1.06 : 0.94) : 1 + 0.08 * beat)
        .animation(mood.pulses ? .easeInOut(duration: mood == .waiting ? 0.7 : 1.1).repeatForever(autoreverses: true)
                               : .easeOut(duration: 0.2), value: phase)
        .onAppear { phase = mood.pulses }
        .onChange(of: mood) { _, m in phase = m.pulses }
        .accessibilityHidden(true)
    }
}

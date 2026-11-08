import Foundation

/// Every kind of wearable, and what the app needs to know about each in one place: the key its
/// settings and identity live under (the raw value — never rename one, stored defaults use it),
/// its name, its symbol, and whether it feeds Jarvis Health or tracks workouts.
enum WearableKind: String, CaseIterable {
    case ring, x5ring, band, bottle, scale, esp32, glasses

    /// As a button or Jarvis names it; nil for a kind without a "Connection Keep Alive" switch
    /// (iOS holds the glasses' Bluetooth audio, so there is no link of ours to keep).
    var keepAliveName: String? {
        switch self {
        case .ring: return "R12 ring"
        case .x5ring: return "X5 ring"
        case .band: return "smart band"
        case .bottle: return "bottle"
        case .scale: return "scale"
        case .esp32: return "ESP32 board"
        case .glasses: return nil
        }
    }

    var symbol: String {
        switch self {
        case .ring, .x5ring: return "circle.circle"
        case .band: return "applewatch.side.right"
        case .bottle: return "waterbottle"
        case .scale: return "scalemass"
        case .esp32: return "cpu"
        case .glasses: return "eyeglasses"
        }
    }

    /// Its days or weigh-ins go to Jarvis Health (a ring's days are synced by the server; a
    /// scale's weigh-ins are pushed by the phone).
    var feedsHealth: Bool { tracksWorkouts || self == .scale }

    /// Worn through a workout: heart rate, the live activity, a held link.
    var tracksWorkouts: Bool { self == .ring || self == .x5ring || self == .band }

    /// The id the device reports before its real one is known; never remembered as an identity.
    var unknownID: String {
        switch self {
        case .bottle: return "unpaired"
        case .scale: return "esf551"
        default: return rawValue
        }
    }

    /// The model name its catalogue registers under (nil: not seeded from shared records).
    var registryModel: String? {
        switch self {
        case .ring: return ColmiR12.model
        case .x5ring: return X5Ring.model
        case .band: return BandDevice.model
        case .bottle: return VsitooS1Pro.model
        case .scale: return Esf551Scale.model
        case .esp32: return Esp32Board.model
        case .glasses: return nil
        }
    }

    static let keepAliveSwitchable: [WearableKind] = allCases.filter { $0.keepAliveName != nil }
    static let healthKinds: Set<String> = Set(allCases.filter(\.feedsHealth).map(\.rawValue))
    static let workoutKinds: Set<String> = Set(allCases.filter(\.tracksWorkouts).map(\.rawValue))
}

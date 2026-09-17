import Foundation

// Compiled into BOTH the app and the widget: the widget renders these numbers
// and must agree with the app about the shape and the app-group key they
// travel under. Keep it dependency-free for that reason.

/// What the widget reads: small, flat, and written to the shared app group.
struct HealthSnapshot: Codable, Equatable {
    static let widgetKind = "JarvisHealthWidget"
    static let key = "jc.health.snapshot"

    var date: String
    var health: Int?
    var band: String
    var sleep: Int?
    var recovery: Int?
    var body: Int?
    var activity: Int?
    var analysis: String
    var generatedAt: Date
    var stale: Bool

    func value(for metric: HealthWidgetMetric) -> Int? {
        switch metric {
        case .health: return health
        case .sleep: return sleep
        case .recovery: return recovery
        case .body: return body
        case .activity: return activity
        }
    }

    static func defaults() -> UserDefaults {
        UserDefaults(suiteName: JarvisShared.appGroupID) ?? .standard
    }

    func write() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        Self.defaults().set(data, forKey: Self.key)
    }

    static func read() -> HealthSnapshot? {
        guard let data = defaults().data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(HealthSnapshot.self, from: data)
    }
}

/// Which number a widget instance shows.
enum HealthWidgetMetric: String, Codable, CaseIterable {
    case health, sleep, recovery, body, activity

    var label: String {
        switch self {
        case .health: return "Health"
        case .sleep: return "Sleep"
        case .recovery: return "Recovery"
        case .body: return "Body"
        case .activity: return "Activity"
        }
    }
}

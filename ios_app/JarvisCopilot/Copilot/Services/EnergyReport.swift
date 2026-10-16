import Foundation

/// The last daily energy report iOS handed us, kept where the app can show it.
///
/// iOS aggregates this on-device and delivers it roughly once every 24 h, so it
/// is the only honest answer to "did that battery change work?" — Settings >
/// Battery is a percentage with no attribution, and reading the raw payload out
/// of the device log needs a Mac, a cable and root.
///
/// `backgroundAudioSeconds` is the one that matters here: it is time spent under
/// `BackgroundKeepalive`, and it should be close to `backgroundSeconds` (the
/// keepalive is what keeps us unsuspended). What should FALL after this change is
/// `cpuSeconds` against the same background time, since the silent engine now
/// wakes the CPU ten times a second instead of a hundred.
struct EnergyReport: Codable, Equatable, Sendable {
    var received: Date
    var cpuSeconds: Double = 0
    var foregroundSeconds: Double = 0
    var backgroundSeconds: Double = 0
    var backgroundAudioSeconds: Double = 0
    var backgroundLocationSeconds: Double = 0
    /// Bytes each way over Wi-Fi and cellular in the day (optional: older saved reports lack them).
    var wifiUpBytes: Double?
    var wifiDownBytes: Double?
    var cellularUpBytes: Double?
    var cellularDownBytes: Double?
    /// Why iOS ended the app while it was in the background, by reason (memory, watchdog, …).
    var backgroundExits: [String: Int]?

    private static let key = "jc.energyReport"
    private static let historyKey = "jc.energyReports"
    static let keepDays = 7

    func save(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
        var days = Self.history(defaults: defaults).filter { $0.received != received }
        days.append(self)
        if let all = try? JSONEncoder().encode(Array(days.suffix(Self.keepDays))) {
            defaults.set(all, forKey: Self.historyKey)
        }
    }

    /// The last week of reports, oldest first.
    static func history(defaults: UserDefaults = .standard) -> [EnergyReport] {
        guard let data = defaults.data(forKey: historyKey),
              let days = try? JSONDecoder().decode([EnergyReport].self, from: data) else {
            return load(defaults: defaults).map { [$0] } ?? []
        }
        return days
    }

    static func load(defaults: UserDefaults = .standard) -> EnergyReport? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(EnergyReport.self, from: data)
    }

    /// CPU seconds burned per hour the app was alive — the number that should
    /// drop when the render buffer grows, independent of how long you used it.
    var cpuSecondsPerHour: Double? {
        let alive = foregroundSeconds + backgroundSeconds
        guard alive > 60 else { return nil }
        return cpuSeconds / (alive / 3600)
    }
}

import Foundation

/// One score the server computed, with the contributions that explain it.
struct ScorePart: Codable, Equatable {
    var value: Int?
    var band: String
    var points: [ScoreContribution]
    var missing: [String]

    init(value: Int? = nil, band: String = "—", points: [ScoreContribution] = [], missing: [String] = []) {
        self.value = value
        self.band = band
        self.points = points
        self.missing = missing
    }

    /// Nothing measurable, as opposed to a genuine zero.
    var isMissing: Bool { value == nil }
}

struct ScoreContribution: Codable, Equatable, Identifiable {
    var name: String
    var earned: Double
    var possible: Double
    var detail: String

    var id: String { name }

    /// What this cost, for "Duration cost the most" style reading.
    var lost: Double { max(0, possible - earned) }
}

/// A day's scores as the phone shows them. The server is the only place these
/// are computed; the phone renders what it was given and says when it is old.
struct HealthScores: Codable, Equatable {
    var date: String
    var health: ScorePart
    var sleep: ScorePart
    var recovery: ScorePart
    var body: ScorePart
    var activity: ScorePart
    var analysis: String
    var generatedAt: Date?
    var stale: Bool
    var baselineDays: Int
    var model: String

    enum CodingKeys: String, CodingKey {
        case date, health, sleep, recovery, body, activity, analysis, stale, model
        case generatedAt = "generated_at"
        case baselineDays = "baseline_days"
    }

    var parts: [(name: String, score: ScorePart)] {
        [("Sleep", sleep), ("Recovery", recovery), ("Body", body), ("Activity", activity)]
    }

    /// The contribution that cost the most across every part — the one worth naming.
    var biggestLoss: ScoreContribution? {
        parts.flatMap { $0.score.points }.max(by: { $0.lost < $1.lost }).flatMap { $0.lost > 0 ? $0 : nil }
    }
}

/// How a wearable's health analysis runs. Edited here, on the wearable's own
/// screen, and nowhere else — the server refuses writes from anywhere but this.
struct HealthSettings: Codable, Equatable {
    var enabled: Bool
    var model: String
    var provider: String
    var frequency: String
    var quietHours: QuietHours
    var rules: [String: Rule]
    var goals: Goals
    var deviceName: String?

    struct QuietHours: Codable, Equatable {
        var start: String
        var end: String
    }

    struct Rule: Codable, Equatable {
        var enabled: Bool
        var threshold: Double
    }

    struct Goals: Codable, Equatable {
        var steps: Int
        var activeMinutes: Int

        enum CodingKeys: String, CodingKey {
            case steps
            case activeMinutes = "active_minutes"
        }
    }

    enum CodingKeys: String, CodingKey {
        case enabled, model, provider, frequency, rules, goals
        case quietHours = "quiet_hours"
        case deviceName = "device_name"
    }

    static let frequencies = ["hourly", "every 6 hours", "every 12 hours", "daily", "manual"]

    /// The rules in the order the settings screen lists them, with their labels
    /// and the unit each threshold is in.
    static let ruleOrder: [(key: String, label: String, unit: String, range: ClosedRange<Double>, step: Double)] = [
        ("resting_hr_high", "Resting heart rate above usual", "bpm", 3...20, 1),
        ("hrv_low", "HRV below usual", "%", 5...50, 5),
        ("spo2_low", "Blood oxygen below", "%", 85...95, 1),
        ("short_sleep", "Sleep under", "h", 3...8, 0.5),
        ("health_low", "Health score under", "", 30...80, 5),
        ("stress_sustained", "High stress for", "min", 15...240, 15),
        ("battery_low", "Ring battery under", "%", 5...50, 5),
    ]
}

/// A wearable the server scores.
struct HealthDevice: Codable, Equatable {
    var spaceID: String
    var kind: String
    var deviceID: String
    var name: String
    var enabled: Bool
    var frequency: String?

    enum CodingKeys: String, CodingKey {
        case kind, name, enabled, frequency
        case spaceID = "space_id"
        case deviceID = "device_id"
    }
}

/// The registry space a wearable's health integration lives in.
///
/// The server derives the same id from the same device id — `space_id_for` in
/// `jarvis_health/store.py` — so both sides name a space without asking.
enum HealthSpace {
    static func id(kind: String, deviceID: String) -> String {
        let hex = deviceID.lowercased().split(whereSeparator: { !$0.isHexDigit })
            .first.map(String.init) ?? "unknown"
        return "wearable-\(kind)-\(String(hex.prefix(8)))"
    }

    static func id(forRing deviceID: String) -> String { id(kind: "ring", deviceID: deviceID) }
}

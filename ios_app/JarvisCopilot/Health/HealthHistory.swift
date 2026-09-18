import Foundation

/// A metric over a range, as the server buckets it (`/health/history`).
struct HealthHistory: Codable, Equatable {
    struct Bucket: Codable, Equatable, Identifiable {
        struct Stages: Codable, Equatable {
            var deep: Double
            var light: Double
            var rem: Double
            var awake: Double
        }

        var start: String
        var end: String
        var value: Double?
        var low: Double?
        var high: Double?
        /// Days measured in it; 0 is a gap, never a zero.
        var days: Int
        var stages: Stages?
        /// A day's share of its goal (1 = met), for the goal rings.
        var goalProgress: Double? = nil

        enum CodingKeys: String, CodingKey {
            case start, end, value, low, high, days, stages
            case goalProgress = "goal_progress"
        }

        var id: String { start }
        var startDate: Date { RingDates.date(forKey: start) ?? .distantPast }
        var endDate: Date { RingDates.date(forKey: end) ?? .distantPast }
    }

    struct Headline: Codable, Equatable {
        var label: String
        var value: Double?
        var low: Double?
        var high: Double?
        var kind: String
    }

    struct Stat: Codable, Equatable {
        var label: String
        var value: Double?
        var kind: String
    }

    /// The daily goal a day-by-day range is judged against, and how it went.
    struct Goal: Codable, Equatable {
        var value: Double
        var kind: String
        var met: Int
        var measured: Int
    }

    struct Previous: Codable, Equatable {
        var average: Double?
        var days: Int
    }

    var metric: String
    var range: String
    var title: String
    var kind: String
    var start: String
    var end: String
    var buckets: [Bucket]
    var headline: Headline
    var stats: [Stat]
    var previous: Previous
    var highlight: String
    var daysSoFar: Int
    var goal: Goal? = nil
    /// Exercise: every workout in the range, newest first.
    var workouts: [RingWorkout]? = nil

    enum CodingKeys: String, CodingKey {
        case metric, range, title, kind, start, end, buckets, headline, stats, previous, highlight, goal, workouts
        case daysSoFar = "days_so_far"
    }

    var isEmpty: Bool { !buckets.contains { $0.days > 0 } }
}

/// Numbers the way the Health tab writes them, by the kind the server names.
enum HealthFormat {
    static func string(_ value: Double?, kind: String) -> String {
        guard let value else { return "—" }
        switch kind {
        case "steps": return Int(value.rounded()).formatted()
        case "bpm": return "\(Int(value.rounded())) bpm"
        case "percent": return "\(Int(value.rounded()))%"
        case "ms": return "\(Int(value.rounded())) ms"
        case "celsius": return TemperatureUnit.current.format(value)
        case "minutes": return duration(Int(value.rounded()))
        case "kcal": return "\(Int(value.rounded()).formatted()) kcal"
        case "meters": return String(format: "%.2f km", value / 1000)
        default: return Int(value.rounded()).formatted()
        }
    }

    /// A low–high range in one unit ("52–141 bpm"), or the one number.
    static func range(_ low: Double?, _ high: Double?, kind: String) -> String? {
        guard let low, let high else { return nil }
        let unit = string(high, kind: kind).drop { $0.isNumber || $0 == "," || $0 == "." }
        return "\(Int(low.rounded()))–\(Int(high.rounded()))\(unit)"
    }

    static func duration(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    }
}

/// One metric's history for the history screen, with an offline copy of
/// each range so the screen opens on the last numbers with no signal.
@MainActor
final class HealthHistoryModel: ObservableObject {
    let metric: HealthMetric
    @Published private(set) var histories: [HealthRange: HealthHistory] = [:]
    @Published private(set) var loadedAt: [HealthRange: Date] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?

    private let client: HealthClient
    private let directory: URL

    init(metric: HealthMetric, client: HealthClient = HealthClient(spaceID: HealthSpace.shared),
         directory: URL? = nil) {
        self.metric = metric
        self.client = client
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HealthTab/history", isDirectory: true)
        for range in HealthRange.allCases where range != .day {
            if let saved = read(range) { histories[range] = saved }
        }
    }

    func load(_ range: HealthRange) async {
        guard range != .day else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let fresh = try await client.history(metric: metric.rawValue, range: range.rawValue)
            histories[range] = fresh
            loadedAt[range] = Date()
            error = nil
            write(fresh, range)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Put a range on screen without a server: tests and previews.
    func seed(_ history: HealthHistory, for range: HealthRange) {
        histories[range] = history
        loadedAt[range] = Date()
    }

    private func url(_ range: HealthRange) -> URL {
        directory.appendingPathComponent("\(metric.rawValue)-\(range.rawValue).json")
    }

    private func read(_ range: HealthRange) -> HealthHistory? {
        guard let data = try? Data(contentsOf: url(range)) else { return nil }
        return try? JSONDecoder().decode(HealthHistory.self, from: data)
    }

    private func write(_ history: HealthHistory, _ range: HealthRange) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(history).write(to: url(range), options: .atomic)
    }
}

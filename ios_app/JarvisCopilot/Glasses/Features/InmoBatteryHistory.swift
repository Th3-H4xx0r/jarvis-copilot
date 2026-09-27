import Foundation

/// Glasses-reported percentage observations; never a phone battery proxy.
final class InmoBatteryHistory {
    struct Sample: Codable, Identifiable {
        let id: UUID
        let date: Date
        let percent: Int
        let segment: UUID
        let connection: UUID
    }
    struct Estimate {
        let pointsPerHour: Double
        let hoursRemaining: Double
        let start: Date
        let end: Date
    }
    private(set) var samples: [Sample] = []
    private var segment = UUID()
    private var connection = UUID()
    private var disconnectedAt: Date?
    private let defaults: UserDefaults?
    private let key: String
    private static let retention: TimeInterval = 7 * 24 * 3600

    init(identity: String, defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        key = "inmo.battery.history.\(identity)"
        if let data = defaults?.data(forKey: key), let saved = try? JSONDecoder().decode([Sample].self, from: data) {
            samples = saved.filter { Date().timeIntervalSince($0.date) <= Self.retention }
            segment = samples.last?.segment ?? UUID()
        }
    }
    func connected(at date: Date = Date()) {
        connection = UUID()
        // Reconnection is a new connection session, even when the observation gap is brief.
        segment = UUID()
        disconnectedAt = nil
    }
    func disconnected(at date: Date = Date()) { disconnectedAt = date }
    func record(_ percent: Int, at date: Date = Date(), boundary: Bool = false) {
        guard (0...100).contains(percent) else { return }
        samples.removeAll { date.timeIntervalSince($0.date) > Self.retention }
        if let last = samples.last {
            guard date >= last.date else { return }
            if percent > last.percent || date.timeIntervalSince(last.date) > 600 { segment = UUID() }
            if !boundary, percent == last.percent, date.timeIntervalSince(last.date) < 60 { return }
        }
        samples.append(Sample(id: UUID(), date: date, percent: percent, segment: segment, connection: connection))
        // Hard cap protects storage even when an accessory oscillates rapidly.
        if samples.count > 20_160 { samples.removeFirst(samples.count - 20_160) }
        if let data = try? JSONEncoder().encode(samples) { defaults?.set(data, forKey: key) }
    }
    func estimate() -> Estimate? {
        guard disconnectedAt == nil, let last = samples.last else { return nil }
        let points = samples.filter { $0.segment == last.segment }
        guard points.count >= 3, let first = points.first,
              last.date.timeIntervalSince(first.date) >= 1800,
              first.percent - last.percent >= 2 else { return nil }
        // Theil–Sen median slope tolerates one noisy percentage report.
        let bounded = Array(points.suffix(120))
        guard let windowStart = bounded.first, last.date.timeIntervalSince(windowStart.date) >= 1800, windowStart.percent - last.percent >= 2 else { return nil }
        var slopes: [Double] = []
        for i in bounded.indices {
            for j in bounded.indices where j > i {
                let elapsed = bounded[j].date.timeIntervalSince(bounded[i].date)
                if elapsed > 0 { slopes.append(Double(bounded[i].percent - bounded[j].percent) * 3600 / elapsed) }
            }
        }
        slopes.sort()
        guard !slopes.isEmpty else { return nil }
        let rate = slopes[slopes.count / 2]
        guard rate > 0 else { return nil }
        return Estimate(pointsPerHour: rate, hoursRemaining: Double(last.percent) / rate, start: windowStart.date, end: last.date)
    }
    func snapshot(since: Date? = nil, now: Date = Date()) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        let selected = samples.filter { since == nil || $0.date >= since! }
        var result: [String: Any] = ["samples": selected.map { ["timestamp": formatter.string(from: $0.date), "percent": $0.percent, "segment_id": $0.segment.uuidString, "connection_id": $0.connection.uuidString] as [String: Any] }, "retention_days": 7, "charging": NSNull(), "charging_reason": "No validated charging signal", "estimate_available": false, "estimate_reason": "Not enough history"]
        if let last = samples.last {
            result["latest_percent"] = last.percent
            result["observed_at"] = formatter.string(from: last.date)
            result["stale"] = disconnectedAt != nil || now.timeIntervalSince(last.date) > 300
            let current = selected.filter { $0.connection == last.connection }
            if let first = current.first {
                result["measured_percentage_points_consumed"] = max(0, first.percent - last.percent)
                result["measured_duration_seconds"] = last.date.timeIntervalSince(first.date)
            }
        }
        if let estimate = estimate(), let latest = samples.last, now.timeIntervalSince(latest.date) <= 300 {
            result["estimate_available"] = true
            result["estimate_reason"] = "Estimate from recent use"
            result["estimated_percentage_points_per_hour"] = estimate.pointsPerHour
            result["estimated_hours_remaining"] = estimate.hoursRemaining
            result["estimate_window_start"] = formatter.string(from: estimate.start)
            result["estimate_window_end"] = formatter.string(from: estimate.end)
        }
        return result
    }
}

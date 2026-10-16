import CryptoKit
import Foundation

/// What each day last went up as, so a sync that re-reads a fortnight of unchanged days sends none
/// of them. The band and rings re-sent 17–18 days (~38 KB each) in one burst every few hours when
/// all that had changed was `synced_at`.
final class DayPushLedger: @unchecked Sendable {
    static let shared = DayPushLedger()
    /// An unchanged day still goes again after this long, in case the server lost its copy.
    static let resendAfter: TimeInterval = 24 * 3600
    /// Days remembered; the oldest sends are forgotten first.
    static let keep = 160

    private let defaults: UserDefaults
    private let now: () -> Date
    private let lock = NSLock()
    private static let storeKey = "healthDayPushLedger"

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
    }

    /// False when this exact day went up less than `resendAfter` ago.
    func shouldSend(_ day: [String: Any], space: String) -> Bool {
        guard let entry = Self.entry(day, space: space, at: now()) else { return true }
        return lock.withLock {
            guard let row = load()[entry.key], row.print == entry.print else { return true }
            return now().timeIntervalSince(row.at) >= Self.resendAfter
        }
    }

    /// The server took `day`.
    func sent(_ day: [String: Any], space: String) {
        guard let entry = Self.entry(day, space: space, at: now()) else { return }
        lock.withLock {
            var rows = load()
            rows[entry.key] = (entry.print, now())
            if rows.count > Self.keep {
                for key in rows.sorted(by: { $0.value.at < $1.value.at }).prefix(rows.count - Self.keep).map(\.key) {
                    rows[key] = nil
                }
            }
            defaults.set(rows.mapValues { ["p": $0.print, "t": $0.at.timeIntervalSince1970] }, forKey: Self.storeKey)
        }
    }

    /// Where a day is filed and a print of what matters in it. `synced_at` changes on every sync and
    /// says nothing; the battery rides on a day only for today's alert rule, so on an older day it
    /// is left out too.
    static func entry(_ day: [String: Any], space: String, at date: Date) -> (key: String, print: String)? {
        guard let key = day["date"] as? String else { return nil }
        var content = day
        content["synced_at"] = nil
        let format = DateFormatter()
        format.calendar = Calendar(identifier: .gregorian)
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd"
        let yesterday = format.string(from: date.addingTimeInterval(-86_400))
        if key < yesterday {
            content["battery_percent"] = nil
            content["charging"] = nil
        }
        guard let data = try? JSONSerialization.data(withJSONObject: content, options: [.sortedKeys]) else { return nil }
        let print = SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
        let device = day["device_id"] as? String ?? ""
        let source = day["source"] as? String ?? ""
        return ("\(space)|\(device)|\(source)|\(key)", print)
    }

    private func load() -> [String: (print: String, at: Date)] {
        let raw = defaults.dictionary(forKey: Self.storeKey) as? [String: [String: Any]] ?? [:]
        return raw.compactMapValues { row in
            guard let print = row["p"] as? String, let t = row["t"] as? Double else { return nil }
            return (print, Date(timeIntervalSince1970: t))
        }
    }
}

/// The one shape a day of ring data travels in.
///
/// Both paths to the server use this: the phone pushes it after a sync, and the
/// server pulls the same thing through `ring_get_health_day`. One builder means
/// the two can never disagree about what a field means.
///
/// Stage codes stay the ring's own (2 light, 3 deep, 4 REM, 5 awake) — the SDK's
/// ring adapter translates them, so no vendor numbering leaks into the scoring.
enum HealthDayPayload {
    static func make(_ day: RingDay, key: String, timezone: String = TimeZone.current.identifier,
                     deviceID: String = "", source: String = "ring") -> [String: Any] {
        var out: [String: Any] = [
            "date": key,
            "timezone": timezone,
            "utc_offset": TimeZone(identifier: timezone)?.secondsFromGMT() ?? TimeZone.current.secondsFromGMT(),
            "source": source,
        ]
        // Jarvis Health files each wearable's days under its own key.
        if !deviceID.isEmpty { out["device_id"] = deviceID }

        if !day.sleep.isEmpty {
            out["sleep"] = day.sleep.map { session -> [String: Any] in
                [
                    "start": iso(session.start),
                    "end": iso(session.end),
                    "stages": session.stages.map { ["stage": $0.stage, "minutes": $0.minutes] },
                ]
            }
        }
        if let hr = day.heartRate { out["heart_rate"] = wire(hr) }
        if let hrv = day.hrv { out["hrv"] = wire(hrv) }
        if let stress = day.stress { out["stress"] = wire(stress) }
        if let temperature = day.temperature { out["temperature"] = wire(temperature) }
        // Hourly lows and highs both travel: the score wants the day's real
        // minimum, and an average of the two would hide an 86% dip behind a 98%
        // high in the same hour.
        if let spo2 = day.spo2 { out["spo2"] = ["min": spo2.min, "max": spo2.max] }
        // Steps per 15-minute slot, so the server can count them from a wake
        // time rather than only from midnight.
        if !day.stepSlots.isEmpty {
            var values = [Int](repeating: 0, count: 96)
            for slot in day.stepSlots where (0..<96).contains(slot.slot) { values[slot.slot] = slot.steps }
            out["steps"] = ["interval_minutes": 15, "values": values]
        }

        // Only today carries `activity` totals; earlier days keep their steps in
        // the 15-minute slots, which is why the summary falls back to them and
        // why this must too — otherwise every past day scores as "no activity".
        let summary = day.summary
        var activity: [String: Any] = [:]
        if let steps = summary.steps { activity["steps"] = steps }
        if let minutes = summary.activeMinutes { activity["active_minutes"] = minutes }
        if let kcal = summary.kilocalories { activity["kilocalories"] = kcal }
        if let metres = summary.distanceMeters { activity["distance_meters"] = metres }
        if !activity.isEmpty { out["activity"] = activity }

        if !day.measurements.isEmpty {
            out["measurements"] = day.measurements.map { record -> [String: Any] in
                var row: [String: Any] = ["type": record.type, "time": iso(record.time), "outcome": record.outcome]
                if let value = record.value { row["value"] = value }
                if let celsius = record.celsius { row["celsius"] = celsius }
                if let systolic = record.systolic { row["systolic"] = systolic }
                if let diastolic = record.diastolic { row["diastolic"] = diastolic }
                // The band's multi-value results (glucose, blood components, body composition, ECG).
                if let extra = record.extra, !extra.isEmpty { row["extra"] = extra }
                return row
            }
        }
        if let synced = day.syncedAt { out["synced_at"] = iso(synced) }
        // Whether this day holds anything at all. The store synthesises an empty
        // day for a date it has never seen, and the server must not overwrite a
        // good copy of that date with this hollow one.
        out["has_data"] = day.syncedAt != nil
            && (!day.sleep.isEmpty || day.heartRate != nil || day.hrv != nil || day.stress != nil
                || day.spo2 != nil || day.temperature != nil || !activity.isEmpty
                || !day.measurements.isEmpty)
        return out
    }

    /// The battery belongs to the device rather than the day, but the alert rule
    /// that watches it reads it off the day the run scored.
    static func make(_ day: RingDay, key: String, timezone: String = TimeZone.current.identifier,
                     deviceID: String = "", source: String = "ring", battery: RingBattery?) -> [String: Any] {
        var out = make(day, key: key, timezone: timezone, deviceID: deviceID, source: source)
        if let battery {
            out["battery_percent"] = battery.percent
            out["charging"] = battery.charging
        }
        return out
    }

    private static func wire(_ s: RingSeries) -> [String: Any] {
        ["interval_minutes": s.intervalMinutes, "values": s.values]
    }

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static func iso(_ date: Date) -> String { formatter.string(from: date) }
}

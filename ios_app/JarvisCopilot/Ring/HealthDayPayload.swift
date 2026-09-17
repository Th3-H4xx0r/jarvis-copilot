import Foundation

/// The one shape a day of ring data travels in.
///
/// Both paths to the server use this: the phone pushes it after a sync, and the
/// server pulls the same thing through `ring_get_health_day`. One builder means
/// the two can never disagree about what a field means.
///
/// Stage codes stay the ring's own (2 light, 3 deep, 4 REM, 5 awake) — the SDK's
/// ring adapter translates them, so no vendor numbering leaks into the scoring.
enum HealthDayPayload {
    static func make(_ day: RingDay, key: String, timezone: String = TimeZone.current.identifier) -> [String: Any] {
        var out: [String: Any] = [
            "date": key,
            "timezone": timezone,
            "utc_offset": TimeZone(identifier: timezone)?.secondsFromGMT() ?? TimeZone.current.secondsFromGMT(),
            "source": "ring",
        ]

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
                     battery: RingBattery?) -> [String: Any] {
        var out = make(day, key: key, timezone: timezone)
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

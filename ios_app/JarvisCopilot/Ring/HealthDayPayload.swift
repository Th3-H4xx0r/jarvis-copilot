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
        if let spo2 = day.spo2 { out["spo2"] = ["min": spo2.min, "max": spo2.max] }

        var activity: [String: Any] = [:]
        if let totals = day.activity {
            activity["steps"] = totals.steps
            activity["active_minutes"] = totals.sportMinutes
            activity["kilocalories"] = Double(totals.calories) / 1000
            activity["distance_meters"] = totals.distanceMeters
        }
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

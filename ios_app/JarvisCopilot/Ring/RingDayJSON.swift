import Foundation

/// A ring day as the `*_get_day` / `*_get_history` skills return it — shared by every ring that
/// stores `RingDay`s, so the R12 and the X5 answer Jarvis in one shape.
enum RingDayJSON {
    static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static func json<T: Encodable>(_ value: T) -> Any {
        guard let data = try? encoder.encode(value),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return [:] }
        return object
    }

    static func parseMetrics(_ raw: Any?) throws -> Set<RingMetric>? {
        guard let raw else { return nil }
        let names: [String]
        if let list = raw as? [String] {
            names = list
        } else if let single = raw as? String {
            names = [single]
        } else {
            throw DeviceError.badArgument("'metrics' must be a list of metric names")
        }
        var out = Set<RingMetric>()
        for name in names {
            guard let metric = RingMetric(rawValue: name.lowercased()) else {
                throw DeviceError.badArgument("unknown metric '\(name)'. Use: "
                    + RingMetric.allCases.map(\.rawValue).joined(separator: ", "))
            }
            out.insert(metric)
        }
        return out.isEmpty ? nil : out
    }

    private static let summaryKeys: [RingMetric: [String]] = [
        .activity: ["steps", "kilocalories", "distance_meters", "active_minutes"],
        .sleep: ["sleep_minutes", "deep_minutes", "light_minutes", "rem_minutes", "awake_minutes"],
        .heartRate: ["heart_rate_min", "heart_rate_avg", "heart_rate_max", "heart_rate_latest"],
        .spo2: ["spo2_min", "spo2_avg", "spo2_latest"],
        .hrv: ["hrv_avg", "hrv_latest"],
        .stress: ["stress_avg", "stress_latest"],
        .temperature: ["temperature_avg", "temperature_latest"],
        .bloodPressure: ["blood_pressure_systolic", "blood_pressure_diastolic"],
        .bloodSugar: ["blood_sugar_min", "blood_sugar_max"],
    ]

    static func summary(_ summary: RingDaySummary, metrics: Set<RingMetric>?) -> [String: Any] {
        guard var dict = json(summary) as? [String: Any] else { return [:] }
        if let metrics {
            let keep = Set(metrics.flatMap { summaryKeys[$0] ?? [] })
            dict = dict.filter { keep.contains($0.key) }
        }
        return dict
    }

    static func detail(_ day: RingDay, metrics: Set<RingMetric>?) -> [String: Any] {
        let wants = { (metric: RingMetric) in metrics?.contains(metric) ?? true }
        let timed = { (values: [RingTimedValue]) in values.map { [$0.minute, $0.value] as [Any] } }
        var out: [String: Any] = [:]
        if wants(.activity) {
            if let activity = day.activity { out["activity"] = json(activity) }
            out["step_slots"] = [
                "fields": ["slot_15min", "steps", "calories_small", "distance_m"],
                "rows": day.stepSlots.map { [$0.slot, $0.steps, $0.calories, $0.distanceMeters] },
            ]
        }
        if wants(.sleep) {
            out["sleep"] = day.sleep.map { session -> [String: Any] in
                ["start": iso(session.start), "end": iso(session.end), "asleep_minutes": session.asleepMinutes,
                 "stages": session.stages.map { [$0.stage, $0.minutes] }]
            }
            out["sleep_stage_codes"] = ["2": "light", "3": "deep", "4": "rem", "5": "awake"]
            out["naps"] = day.naps.map { ["start": iso($0.start), "end": iso($0.end)] }
        }
        if wants(.heartRate) {
            if let series = day.heartRate { out["heart_rate_series"] = json(series) }
            out["heart_rate_manual"] = timed(day.manualHeartRate)
            out["heart_rate_instant"] = timed(day.instantHeartRate)
        }
        if wants(.spo2) {
            if let spo2 = day.spo2 { out["spo2_hourly"] = json(spo2) }
            out["spo2_manual"] = timed(day.manualSpO2)
            out["spo2_instant"] = timed(day.instantSpO2)
        }
        if wants(.hrv), let hrv = day.hrv { out["hrv_series"] = json(hrv) }
        if wants(.stress), let stress = day.stress { out["stress_series"] = json(stress) }
        if wants(.temperature) {
            if let temperature = day.temperature { out["temperature_series_c"] = json(temperature) }
            out["temperature_instant_c"] = timed(day.instantTemperature)
        }
        if wants(.bloodPressure) { out["blood_pressure"] = json(day.bloodPressure) }
        if wants(.bloodSugar), let sugar = day.bloodSugar { out["blood_sugar_hourly"] = json(sugar) }
        out["measurements"] = json(day.measurements)
        out["timed_value_fields"] = ["minute_of_day", "value"]
        return out
    }
}

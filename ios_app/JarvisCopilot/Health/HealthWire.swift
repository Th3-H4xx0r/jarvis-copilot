import Foundation

/// A day as Jarvis Health stores it: SDK stage codes, series anchored at the
/// day's local midnight as a UTC instant.
///
/// The Health tab draws it through the ring's own `RingDay`, so every existing
/// card — the charts that scrub, the sleep timeline — renders server data
/// without a second set of views.
struct HealthWireDay: Codable, Equatable {
    struct Series: Codable, Equatable {
        var start: String
        var intervalMinutes: Int
        var values: [Double]

        enum CodingKeys: String, CodingKey {
            case start, values
            case intervalMinutes = "interval_minutes"
        }
    }

    struct Sleep: Codable, Equatable {
        var start: String
        var end: String
        /// `[code, minutes]` pairs in the SDK's codes.
        var stages: [[Int]]
    }

    var date: String
    var timezone: String
    var utcOffset: Int
    var sleep: [Sleep]?
    var heartRate: Series?
    var hrv: Series?
    var stress: Series?
    var spo2: Series?
    var temperature: Series?
    var steps: Series?
    var activity: [String: Double]?

    enum CodingKeys: String, CodingKey {
        case date, timezone, sleep, hrv, stress, spo2, temperature, steps, activity
        case utcOffset = "utc_offset"
        case heartRate = "heart_rate"
    }

    /// SDK codes (1 awake, 2 deep, 3 light, 4 REM) back to the ring's.
    static let ringStage: [Int: Int] = [1: RingSleepStage.awake, 2: RingSleepStage.deep,
                                        3: RingSleepStage.light, 4: RingSleepStage.rem]

    /// The ring's day model, so the existing cards draw server data unchanged.
    func ringDay() -> RingDay {
        var day = RingDay(date: date)
        func series(_ s: Series?) -> RingSeries? {
            s.map { RingSeries(intervalMinutes: $0.intervalMinutes, values: $0.values) }
        }
        day.heartRate = series(heartRate)
        day.hrv = series(hrv)
        day.stress = series(stress)
        day.temperature = series(temperature)
        if let spo2, !spo2.values.isEmpty {
            let hourly = spo2.values.map { Int($0.rounded()) }
            day.spo2 = RingMinMax(min: hourly, max: hourly)
        }
        if let steps {
            day.stepSlots = steps.values.enumerated().compactMap { index, value in
                value > 0 ? RingStepSlot(slot: index, steps: Int(value), calories: 0, distanceMeters: 0) : nil
            }
        }
        if let activity {
            day.activity = RingActivity(steps: Int(activity["steps"] ?? 0), runningSteps: 0,
                                        calories: Int((activity["kilocalories"] ?? 0) * 1000),
                                        distanceMeters: Int(activity["distance_meters"] ?? 0),
                                        sportMinutes: Int(activity["active_minutes"] ?? 0))
        }
        day.sleep = (sleep ?? []).compactMap { s in
            guard let start = HealthClient.instant.date(from: s.start),
                  let end = HealthClient.instant.date(from: s.end) else { return nil }
            let stages = s.stages.compactMap { pair -> RingSleepStage? in
                guard pair.count == 2, let code = Self.ringStage[pair[0]] else { return nil }
                return RingSleepStage(stage: code, minutes: pair[1])
            }
            return RingSleepSession(start: start, end: end, reportedStartMinute: 0, stages: stages)
        }
        day.syncedAt = Date()
        return day
    }
}

struct HealthCurvePoint: Codable, Equatable {
    var at: Date
    var level: Double
}

struct HealthDrain: Codable, Equatable {
    var start: Date
    var end: Date
    var points: Double
}

/// The Body Battery as the server charted it: a day's, or the window since waking.
struct HealthBattery: Codable, Equatable {
    struct Calibrating: Codable, Equatable {
        var nights: Int
        var needed: Int
    }

    var level: Double?
    var band: String
    var wakeLevel: Double?
    var charged: Double?
    var drained: Double?
    var drains: [String: Double]?
    var biggestDrain: HealthDrain?
    var curve: [HealthCurvePoint]
    var calibrating: Calibrating?
    var partial: Bool?
    var noSleep: Bool?
    var recoveryFactor: Double?
    /// When the night began and ended, and the level it began at — shaded on
    /// the curve so the climb reads as sleep.
    var bedLevel: Double?
    var bedAt: Date?
    var wakeAt: Date?

    enum CodingKeys: String, CodingKey {
        case level, band, charged, drained, drains, curve, calibrating, partial
        case bedLevel = "bed_level"
        case bedAt = "bed_at"
        case wakeAt = "wake_at"
        case wakeLevel = "wake_level"
        case biggestDrain = "biggest_drain"
        case noSleep = "no_sleep"
        case recoveryFactor = "recovery_factor"
    }
}

/// Today: from falling asleep last night to now. `start` is bedtime, or
/// midnight when no night was recorded (`noWake`).
struct HealthNow: Codable, Equatable {
    var start: Date
    var end: Date
    var minutes: Int
    var noWake: Bool
    var day: HealthWireDay?
    var battery: HealthBattery
    /// When last night ended.
    var wake: Date? = nil

    enum CodingKeys: String, CodingKey {
        case start, end, minutes, day, battery, wake
        case noWake = "no_wake"
    }
}

/// One calendar day from the shared integration.
struct HealthDayResponse: Codable, Equatable {
    var date: String
    var day: HealthWireDay?
    var battery: HealthBattery?
    var hasData: Bool

    enum CodingKeys: String, CodingKey {
        case date, day, battery
        case hasData = "has_data"
    }
}

/// A wearable in Jarvis Health's roster — a data source that can be unlinked.
struct HealthRosterDevice: Codable, Equatable, Identifiable {
    var key: String
    var kind: String
    var name: String?
    var linked: Bool
    var lastSyncedAt: String?

    var id: String { key }

    enum CodingKeys: String, CodingKey {
        case key, kind, name, linked
        case lastSyncedAt = "last_synced_at"
    }
}

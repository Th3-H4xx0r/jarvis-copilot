import Foundation

struct RingMeasurementRecord: Codable, Equatable {
    var type: String
    var time: Date
    var outcome: String
    var value: Int?
    var systolic: Int?
    var diastolic: Int?
    var celsius: Double?
}

/// Everything collected from the ring for one local day.
struct RingDay: Codable, Equatable {
    var date: String
    var activity: RingActivity?
    var stepSlots: [RingStepSlot] = []
    /// Night sleep, keyed to the day it ended.
    var sleep: [RingSleepSession] = []
    var naps: [RingNap] = []
    /// Legacy-protocol sleep: 15-minute slot → the ring's seven quality bytes.
    var legacySleepSlots: [Int: [Int]] = [:]
    var heartRate: RingSeries?
    var hrv: RingSeries?
    var stress: RingSeries?
    /// °C.
    var temperature: RingSeries?
    var spo2: RingMinMax?
    var bloodSugar: RingMinMax?
    var manualHeartRate: [RingTimedValue] = []
    var manualSpO2: [RingTimedValue] = []
    var instantHeartRate: [RingTimedValue] = []
    var instantSpO2: [RingTimedValue] = []
    var instantTemperature: [RingTimedValue] = []
    var bloodPressure: [RingBloodPressureReading] = []
    var measurements: [RingMeasurementRecord] = []
    var syncedAt: Date?

    init(date: String) {
        self.date = date
    }

    private enum CodingKeys: String, CodingKey {
        case date, activity, stepSlots, sleep, naps, legacySleepSlots, heartRate, hrv, stress, temperature, spo2,
             bloodSugar, manualHeartRate, manualSpO2, instantHeartRate, instantSpO2, instantTemperature,
             bloodPressure, measurements, syncedAt
    }

    /// Tolerates files written before a field existed.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(String.self, forKey: .date)
        activity = try c.decodeIfPresent(RingActivity.self, forKey: .activity)
        stepSlots = try c.decodeIfPresent([RingStepSlot].self, forKey: .stepSlots) ?? []
        sleep = try c.decodeIfPresent([RingSleepSession].self, forKey: .sleep) ?? []
        naps = try c.decodeIfPresent([RingNap].self, forKey: .naps) ?? []
        legacySleepSlots = try c.decodeIfPresent([Int: [Int]].self, forKey: .legacySleepSlots) ?? [:]
        heartRate = try c.decodeIfPresent(RingSeries.self, forKey: .heartRate)
        hrv = try c.decodeIfPresent(RingSeries.self, forKey: .hrv)
        stress = try c.decodeIfPresent(RingSeries.self, forKey: .stress)
        temperature = try c.decodeIfPresent(RingSeries.self, forKey: .temperature)
        spo2 = try c.decodeIfPresent(RingMinMax.self, forKey: .spo2)
        bloodSugar = try c.decodeIfPresent(RingMinMax.self, forKey: .bloodSugar)
        manualHeartRate = try c.decodeIfPresent([RingTimedValue].self, forKey: .manualHeartRate) ?? []
        manualSpO2 = try c.decodeIfPresent([RingTimedValue].self, forKey: .manualSpO2) ?? []
        instantHeartRate = try c.decodeIfPresent([RingTimedValue].self, forKey: .instantHeartRate) ?? []
        instantSpO2 = try c.decodeIfPresent([RingTimedValue].self, forKey: .instantSpO2) ?? []
        instantTemperature = try c.decodeIfPresent([RingTimedValue].self, forKey: .instantTemperature) ?? []
        bloodPressure = try c.decodeIfPresent([RingBloodPressureReading].self, forKey: .bloodPressure) ?? []
        measurements = try c.decodeIfPresent([RingMeasurementRecord].self, forKey: .measurements) ?? []
        syncedAt = try c.decodeIfPresent(Date.self, forKey: .syncedAt)
    }

    // MARK: Merging

    mutating func mergeStepSlots(_ slots: [RingStepSlot]) {
        var bySlot = Dictionary(stepSlots.map { ($0.slot, $0) }, uniquingKeysWith: { _, new in new })
        for slot in slots { bySlot[slot.slot] = slot }
        stepSlots = bySlot.values.sorted { $0.slot < $1.slot }
    }

    /// A re-synced night replaces the copy that ended within five minutes of it.
    mutating func mergeSleep(_ session: RingSleepSession) {
        sleep.removeAll { abs($0.end.timeIntervalSince(session.end)) < 300 }
        sleep.append(session)
        sleep.sort { $0.end < $1.end }
    }

    mutating func mergeNaps(_ new: [RingNap]) {
        naps.removeAll { old in new.contains { abs($0.start.timeIntervalSince(old.start)) < 120 } }
        naps += new
        naps.sort { $0.start < $1.start }
    }

    mutating func mergeBloodPressure(_ readings: [RingBloodPressureReading]) {
        bloodPressure.removeAll { old in readings.contains { $0.time == old.time } }
        bloodPressure += readings
        bloodPressure.sort { $0.time < $1.time }
    }

    static func merged(_ existing: [RingTimedValue], _ new: [RingTimedValue]) -> [RingTimedValue] {
        var byMinute = Dictionary(existing.map { ($0.minute, $0) }, uniquingKeysWith: { _, latest in latest })
        for value in new { byMinute[value.minute] = value }
        return byMinute.values.sorted { $0.minute < $1.minute }
    }

    // MARK: Summary

    var summary: RingDaySummary {
        var s = RingDaySummary()

        let slotSteps = stepSlots.reduce(0) { $0 + $1.steps }
        if let activity {
            s.steps = activity.steps
            s.kilocalories = activity.kilocalories
            s.distanceMeters = activity.distanceMeters
            s.activeMinutes = activity.sportMinutes
        } else if !stepSlots.isEmpty {
            s.steps = slotSteps
            s.kilocalories = Double(stepSlots.reduce(0) { $0 + $1.calories }) / 1000
            s.distanceMeters = stepSlots.reduce(0) { $0 + $1.distanceMeters }
        }

        if let night = sleep.max(by: { $0.asleepMinutes < $1.asleepMinutes }) {
            s.sleepMinutes = night.asleepMinutes
            s.deepMinutes = night.minutes(of: RingSleepStage.deep)
            s.lightMinutes = night.minutes(of: RingSleepStage.light)
            s.remMinutes = night.minutes(of: RingSleepStage.rem)
            s.awakeMinutes = night.minutes(of: RingSleepStage.awake)
        }

        let heart = (heartRate?.readings.map { RingTimedValue(minute: $0.minute, value: $0.value) } ?? [])
            + manualHeartRate + instantHeartRate
        if !heart.isEmpty {
            let values = heart.map(\.value)
            s.heartRateMin = Int(values.min() ?? 0)
            s.heartRateMax = Int(values.max() ?? 0)
            s.heartRateAvg = Int((values.reduce(0, +) / Double(values.count)).rounded())
            s.heartRateLatest = Int(heart.max(by: { $0.minute < $1.minute })?.value ?? 0)
        }

        var oxygen = (manualSpO2 + instantSpO2).map(\.value)
        if let spo2 {
            oxygen += zip(spo2.min, spo2.max).compactMap { low, high in
                low > 0 && high > 0 ? Double(low + high) / 2 : nil
            }
        }
        if !oxygen.isEmpty {
            let lows = (spo2?.min.filter { $0 > 0 }.map(Double.init) ?? []) + (manualSpO2 + instantSpO2).map(\.value)
            s.spo2Min = Int(lows.min() ?? oxygen.min() ?? 0)
            s.spo2Avg = Int((oxygen.reduce(0, +) / Double(oxygen.count)).rounded())
            let latestPoint = (manualSpO2 + instantSpO2).max(by: { $0.minute < $1.minute })
            s.spo2Latest = latestPoint.map { Int($0.value) } ?? spo2?.max.last(where: { $0 > 0 })
        }

        if let hrv, !hrv.readings.isEmpty {
            let values = hrv.readings.map(\.value)
            s.hrvAvg = Int((values.reduce(0, +) / Double(values.count)).rounded())
            s.hrvLatest = Int(values.last ?? 0)
        }
        if let stress, !stress.readings.isEmpty {
            let values = stress.readings.map(\.value)
            s.stressAvg = Int((values.reduce(0, +) / Double(values.count)).rounded())
            s.stressLatest = Int(values.last ?? 0)
        }

        let temps = (temperature?.readings.map { RingTimedValue(minute: $0.minute, value: $0.value) } ?? [])
            + instantTemperature
        if !temps.isEmpty {
            let values = temps.map(\.value)
            s.temperatureAvg = (values.reduce(0, +) / Double(values.count) * 100).rounded() / 100
            s.temperatureLatest = temps.max(by: { $0.minute < $1.minute })?.value
        }
        return s
    }
}

struct RingDaySummary: Codable, Equatable {
    var steps: Int?
    var kilocalories: Double?
    var distanceMeters: Int?
    var activeMinutes: Int?
    var sleepMinutes: Int?
    var deepMinutes: Int?
    var lightMinutes: Int?
    var remMinutes: Int?
    var awakeMinutes: Int?
    var heartRateMin: Int?
    var heartRateAvg: Int?
    var heartRateMax: Int?
    var heartRateLatest: Int?
    var spo2Min: Int?
    var spo2Avg: Int?
    var spo2Latest: Int?
    var hrvAvg: Int?
    var hrvLatest: Int?
    var stressAvg: Int?
    var stressLatest: Int?
    var temperatureAvg: Double?
    var temperatureLatest: Double?
}

/// Per-ring history, one JSON file per local day under Application Support.
@MainActor
final class RingHistoryStore: ObservableObject {
    private static var instances: [String: RingHistoryStore] = [:]

    static func shared(for deviceID: String) -> RingHistoryStore {
        if let existing = instances[deviceID] { return existing }
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let folder = String(deviceID.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
        let store = RingHistoryStore(directory: base.appendingPathComponent("Ring", isDirectory: true)
            .appendingPathComponent(folder, isDirectory: true))
        instances[deviceID] = store
        return store
    }

    /// Bumps on every write, so screens redraw.
    @Published private(set) var revision = 0

    let directory: URL
    private var cache: [String: RingDay] = [:]
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func day(_ key: String) -> RingDay {
        if let cached = cache[key] { return cached }
        let loaded = (try? Data(contentsOf: fileURL(key))).flatMap { try? decoder.decode(RingDay.self, from: $0) }
            ?? RingDay(date: key)
        cache[key] = loaded
        return loaded
    }

    func update(_ key: String, _ mutate: (inout RingDay) -> Void) {
        var value = day(key)
        let before = value
        mutate(&value)
        guard value != before else { return }
        cache[key] = value
        do {
            try encoder.encode(value).write(to: fileURL(key), options: .atomic)
        } catch {
            JcLog.devices.error("ring: could not save \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        revision += 1
    }

    /// Today first.
    func recentDays(_ count: Int, now: Date = Date(), calendar: Calendar = .current) -> [RingDay] {
        (0..<max(0, count)).map {
            day(RingDates.dayKey(RingDates.midnight(daysAgo: $0, now: now, calendar: calendar), calendar: calendar))
        }
    }

    func prune(keepDays: Int = 365, now: Date = Date(), calendar: Calendar = .current) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return }
        for url in files where url.pathExtension == "json" {
            let key = url.deletingPathExtension().lastPathComponent
            if let age = RingDates.daysAgo(key: key, now: now, calendar: calendar), age > keepDays {
                try? FileManager.default.removeItem(at: url)
                cache[key] = nil
            }
        }
    }

    private func fileURL(_ key: String) -> URL {
        directory.appendingPathComponent("\(key).json")
    }
}

import CryptoKit
import HealthKit
import UIKit

/// A kind of data Jarvis keeps in Apple Health, each with its own switch.
enum AppleHealthKind: String, CaseIterable, Identifiable {
    case workouts, heartRate, restingHeartRate, hrv, bloodOxygen, steps, distance, activeEnergy, sleep, body

    var id: String { rawValue }

    var title: String {
        switch self {
        case .workouts: return "Workouts"
        case .heartRate: return "Heart rate"
        case .restingHeartRate: return "Resting heart rate"
        case .hrv: return "Heart rate variability"
        case .bloodOxygen: return "Blood oxygen"
        case .steps: return "Steps"
        case .distance: return "Walking + running distance"
        case .activeEnergy: return "Active energy"
        case .sleep: return "Sleep"
        case .body: return "Weight and body fat"
        }
    }

    var symbol: String {
        switch self {
        case .workouts: return "figure.run"
        case .heartRate: return "heart.fill"
        case .restingHeartRate: return "bed.double.fill"
        case .hrv: return "waveform.path.ecg"
        case .bloodOxygen: return "drop.fill"
        case .steps: return "figure.walk"
        case .distance: return "point.topleft.down.to.point.bottomright.curvepath"
        case .activeEnergy: return "flame.fill"
        case .sleep: return "moon.fill"
        case .body: return "scalemass.fill"
        }
    }

    /// What it writes, for the permission request.
    var sampleTypes: [HKSampleType] {
        switch self {
        case .workouts: return [HKObjectType.workoutType(), HKSeriesType.workoutRoute()]
        case .heartRate: return [HKQuantityType(.heartRate)]
        case .restingHeartRate: return [HKQuantityType(.restingHeartRate)]
        case .hrv: return [HKQuantityType(.heartRateVariabilitySDNN)]
        case .bloodOxygen: return [HKQuantityType(.oxygenSaturation)]
        case .steps: return [HKQuantityType(.stepCount)]
        case .distance: return [HKQuantityType(.distanceWalkingRunning)]
        case .activeEnergy: return [HKQuantityType(.activeEnergyBurned)]
        case .sleep: return [HKCategoryType(.sleepAnalysis)]
        case .body: return [HKQuantityType(.bodyMass), HKQuantityType(.bodyFatPercentage),
                            HKQuantityType(.bodyMassIndex), HKQuantityType(.leanBodyMass)]
        }
    }

    /// Kinds made from the ring's days (the rest come from workouts and the scale).
    static let fromRingDays: [AppleHealthKind] = [.heartRate, .restingHeartRate, .hrv, .bloodOxygen, .steps, .distance,
                                                  .activeEnergy, .sleep]
}

/// One sample Jarvis will write — pure data, so what a day becomes is
/// tested without HealthKit.
struct AppleHealthSample: Equatable {
    enum Value: Equatable {
        case quantity(HKQuantityTypeIdentifier, unit: String, value: Double)
        case sleep(HKCategoryValueSleepAnalysis)
    }

    var value: Value
    var start: Date
    var end: Date
    /// Stable per sample: a re-sync replaces instead of duplicating.
    var syncID: String
}

/// What a ring day and the scale's weigh-ins become in Apple Health.
enum AppleHealthPlan {
    static let bpm = "count/min"

    /// A ring day's samples of one kind. `busy` are workouts already in
    /// Apple Health: the active energy and distance inside them are the
    /// workout's, so the ring's are zeroed there rather than counted twice
    /// (zero, not left out, so one written before the workout is replaced).
    static func samples(_ kind: AppleHealthKind, day: RingDay, calendar: Calendar = .current,
                        busy: [DateInterval] = []) -> [AppleHealthSample] {
        guard let midnight = RingDates.date(forKey: day.date, calendar: calendar) else { return [] }
        func at(_ minute: Int) -> Date { midnight.addingTimeInterval(Double(minute) * 60) }
        let tag = day.date.replacingOccurrences(of: "-", with: "")
        switch kind {
        case .heartRate:
            var byMinute: [Int: Double] = [:]
            for reading in day.heartRate?.readings ?? [] { byMinute[reading.minute] = reading.value }
            for spot in day.manualHeartRate + day.instantHeartRate { byMinute[spot.minute] = spot.value }
            return byMinute.keys.sorted().compactMap { minute in
                let value = byMinute[minute]!
                guard (30...230).contains(value) else { return nil }
                return AppleHealthSample(value: .quantity(.heartRate, unit: bpm, value: value), start: at(minute), end: at(minute),
                                         syncID: "jarvis-hr-\(tag)-\(minute)")
            }
        case .restingHeartRate:
            // The mean of the three lowest readings in the main night's sleep.
            guard let night = day.sleep.max(by: { $0.asleepMinutes < $1.asleepMinutes }), let series = day.heartRate else { return [] }
            let lows = series.readings
                .filter { (30...120).contains($0.value) }
                .filter { at($0.minute) >= night.start && at($0.minute) <= night.end }
                .map(\.value).sorted().prefix(3)
            guard lows.count == 3 else { return [] }
            let value = (lows.reduce(0, +) / 3).rounded()
            return [AppleHealthSample(value: .quantity(.restingHeartRate, unit: bpm, value: value), start: night.end, end: night.end,
                                      syncID: "jarvis-rhr-\(tag)")]
        case .hrv:
            return (day.hrv?.readings ?? []).filter { (5...300).contains($0.value) }.map {
                AppleHealthSample(value: .quantity(.heartRateVariabilitySDNN, unit: "ms", value: $0.value),
                                  start: at($0.minute), end: at($0.minute), syncID: "jarvis-hrv-\(tag)-\($0.minute)")
            }
        case .bloodOxygen:
            var out: [AppleHealthSample] = []
            if let spo2 = day.spo2 {
                for hour in 0..<min(spo2.min.count, spo2.max.count) where spo2.min[hour] >= 70 && spo2.max[hour] <= 100 && spo2.max[hour] > 0 {
                    let value = Double(spo2.min[hour] + spo2.max[hour]) / 2 / 100
                    out.append(AppleHealthSample(value: .quantity(.oxygenSaturation, unit: "%", value: value),
                                                 start: at(hour * 60), end: at(hour * 60 + 59), syncID: "jarvis-spo2-\(tag)-h\(hour)"))
                }
            }
            for spot in day.manualSpO2 + day.instantSpO2 where (70...100).contains(spot.value) {
                out.append(AppleHealthSample(value: .quantity(.oxygenSaturation, unit: "%", value: spot.value / 100),
                                             start: at(spot.minute), end: at(spot.minute), syncID: "jarvis-spo2-\(tag)-m\(spot.minute)"))
            }
            return out
        case .steps, .distance, .activeEnergy:
            return day.stepSlots.compactMap { slot in
                let start = at(slot.slot * 15), end = at(slot.slot * 15 + 15)
                var value: Double
                let type: HKQuantityTypeIdentifier
                let unit: String
                switch kind {
                case .steps: (value, type, unit) = (Double(slot.steps), .stepCount, "count")
                case .distance: (value, type, unit) = (Double(slot.distanceMeters), .distanceWalkingRunning, "m")
                // The ring counts small calories.
                default: (value, type, unit) = (Double(slot.calories) / 1000, .activeEnergyBurned, "kcal")
                }
                guard value > 0 else { return nil }
                if kind != .steps, busy.contains(where: { $0.start < end && $0.end > start }) { value = 0 }
                return AppleHealthSample(value: .quantity(type, unit: unit, value: value), start: start, end: end,
                                         syncID: "jarvis-\(kind.rawValue)-\(tag)-\(slot.slot)")
            }
        case .sleep:
            var out: [AppleHealthSample] = []
            for session in day.sleep {
                let key = Int(session.start.timeIntervalSince1970)
                out.append(AppleHealthSample(value: .sleep(.inBed), start: session.start, end: session.end,
                                             syncID: "jarvis-sleep-\(key)-bed"))
                var cursor = session.start
                for (i, stage) in session.stages.enumerated() where stage.minutes > 0 {
                    let end = min(session.end, cursor.addingTimeInterval(Double(stage.minutes) * 60))
                    guard end > cursor else { break }
                    let value: HKCategoryValueSleepAnalysis
                    switch stage.stage {
                    case RingSleepStage.deep: value = .asleepDeep
                    case RingSleepStage.rem: value = .asleepREM
                    case RingSleepStage.awake: value = .awake
                    default: value = .asleepCore
                    }
                    out.append(AppleHealthSample(value: .sleep(value), start: cursor, end: end, syncID: "jarvis-sleep-\(key)-\(i)"))
                    cursor = end
                }
            }
            for nap in day.naps where nap.end > nap.start {
                out.append(AppleHealthSample(value: .sleep(.asleepUnspecified), start: nap.start, end: nap.end,
                                             syncID: "jarvis-nap-\(Int(nap.start.timeIntervalSince1970))"))
            }
            return out
        case .workouts, .body:
            return []
        }
    }

    /// A weigh-in's weight, body fat, BMI and lean mass.
    static func body(_ reading: ScaleReading) -> [AppleHealthSample] {
        let id = reading.id.uuidString.lowercased()
        var out = [AppleHealthSample(value: .quantity(.bodyMass, unit: "kg", value: reading.weightKg),
                                     start: reading.date, end: reading.date, syncID: "jarvis-weight-\(id)")]
        if let fat = reading.metrics[.bodyFat], fat > 0, fat < 80 {
            out.append(AppleHealthSample(value: .quantity(.bodyFatPercentage, unit: "%", value: fat / 100),
                                         start: reading.date, end: reading.date, syncID: "jarvis-fat-\(id)"))
        }
        if let bmi = reading.metrics[.bmi], bmi > 0 {
            out.append(AppleHealthSample(value: .quantity(.bodyMassIndex, unit: "count", value: bmi),
                                         start: reading.date, end: reading.date, syncID: "jarvis-bmi-\(id)"))
        }
        if let lean = reading.metrics[.fatFreeWeight], lean > 0 {
            out.append(AppleHealthSample(value: .quantity(.leanBodyMass, unit: "kg", value: lean),
                                         start: reading.date, end: reading.date, syncID: "jarvis-lean-\(id)"))
        }
        return out
    }

    /// A fingerprint of what would be written: unchanged, nothing is sent.
    static func fingerprint(_ samples: [AppleHealthSample]) -> String {
        let text = samples.map { sample -> String in
            switch sample.value {
            case .quantity(_, _, let v): return "\(sample.syncID)=\(v)@\(sample.start.timeIntervalSince1970)-\(sample.end.timeIntervalSince1970)"
            case .sleep(let v): return "\(sample.syncID)=s\(v.rawValue)@\(sample.start.timeIntervalSince1970)-\(sample.end.timeIntervalSince1970)"
            }
        }.joined(separator: ";")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Keeps Apple Health in step with the ring and the scale: after each ring
/// sync, each weigh-in, when the app opens and on Sync Now. Each switched-on
/// kind writes only the days that changed since last time; every sample has
/// a sync identifier, so nothing is ever written twice.
@MainActor
final class AppleHealthSync: ObservableObject {
    static let shared = AppleHealthSync()

    @Published private(set) var kinds: Set<AppleHealthKind>
    @Published private(set) var lastSynced: Date?
    @Published private(set) var syncing = false

    private let healthStore = HKHealthStore()
    private let kindsKey = "jc.health.appleHealthKinds"
    private let lastKey = "jc.health.appleHealthLastSync"
    private let fingerprintsURL: URL
    private var fingerprints: [String: String]
    private var pending: Task<Void, Never>?
    private var watching: [NSObjectProtocol] = []
    /// How far back a first sync reaches.
    static let historyDays = 180
    /// How far back a routine sync looks: a ring sync only revises its last few days.
    static let recentDays = 3
    /// The next sync walks the whole window (first time, a kind switched on, Sync Now).
    private var needsFull: Bool

    init() {
        let stored = UserDefaults.standard.stringArray(forKey: kindsKey)
        kinds = stored.map { Set($0.compactMap(AppleHealthKind.init(rawValue:))) } ?? Set(AppleHealthKind.allCases)
        let last = UserDefaults.standard.object(forKey: lastKey) as? Date
        lastSynced = last
        needsFull = last == nil
        fingerprintsURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AppleHealthSync.json")
        fingerprints = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: fingerprintsURL))) ?? [:]
        watching.append(NotificationCenter.default.addObserver(forName: .jcRingDaysSynced, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncSoon() }
        })
        watching.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, (self.lastSynced.map { Date().timeIntervalSince($0) > 900 } ?? true) else { return }
                self.syncSoon(after: 3)
            }
        })
    }

    private var writer: AppleHealthWriter { .shared }
    var isOn: Bool { writer.enabled && writer.isAvailable }

    func isOn(_ kind: AppleHealthKind) -> Bool { kinds.contains(kind) }

    enum Access { case allowed, notAsked, denied }

    /// Whether Apple Health lets Jarvis write this kind.
    func access(_ kind: AppleHealthKind) -> Access {
        let statuses = kind.sampleTypes.map { healthStore.authorizationStatus(for: $0) }
        if statuses.contains(.sharingAuthorized) { return .allowed }
        return statuses.contains(.notDetermined) ? .notAsked : .denied
    }

    /// Asks for whichever of these kinds' types were never asked about
    /// (Apple Health shows nothing when every one was).
    func authorize(_ which: [AppleHealthKind]) async {
        let types = Set(which.flatMap(\.sampleTypes)).filter { healthStore.authorizationStatus(for: $0) == .notDetermined }
        guard !types.isEmpty else { return }
        do {
            try await healthStore.requestAuthorization(toShare: types, read: [HKObjectType.workoutType()])
        } catch {
            JcLog.dropped(JcLog.devices, "apple health permission", error)
        }
        objectWillChange.send()
    }

    /// The Sync Now button: ask for anything new, then write at once.
    func syncNow() async {
        pending?.cancel()
        needsFull = true
        await authorize(Array(kinds))
        await sync()
    }

    /// Every type a switched-on kind writes (asked for together).
    var shareTypes: Set<HKSampleType> {
        var out = Set(AppleHealthKind.allCases.flatMap(\.sampleTypes))
        if #available(iOS 18.0, *) { out.insert(HKQuantityType(.workoutEffortScore)) }
        return out
    }

    func set(_ kind: AppleHealthKind, _ on: Bool) {
        if on { kinds.insert(kind) } else { kinds.remove(kind) }
        UserDefaults.standard.set(kinds.map(\.rawValue).sorted(), forKey: kindsKey)
        guard on else { return }
        // A kind switched back on writes its whole window again.
        fingerprints = fingerprints.filter { !$0.key.hasPrefix("\(kind.rawValue)|") }
        saveFingerprints()
        needsFull = true
        Task {
            await authorize([kind])
            syncSoon(after: 1)
        }
    }

    /// Soon, not now: a ring sync and a weigh-in arriving together are one sync.
    func syncSoon(after seconds: Double = 8) {
        guard isOn else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    /// Write what changed, kind by kind, day by day.
    func sync() async {
        guard isOn, !syncing else { return }
        syncing = true
        // What was written stays written even when a later day fails (a
        // locked phone refuses writes): the next sync starts from there.
        let full = needsFull
        let finished = await writeChanges(days: full ? Self.historyDays : Self.recentDays)
        saveFingerprints()
        if finished {
            if full { needsFull = false }
            lastSynced = Date()
            UserDefaults.standard.set(lastSynced, forKey: lastKey)
        }
        syncing = false
    }

    private func writeChanges(days: Int) async -> Bool {
        let version = Int(Date().timeIntervalSince1970)
        if let ring = WearablesHub.shared.ring.store {
            let keys = Array(ring.allKeys().suffix(days))
            for key in keys {
                let day = ring.day(key)
                let busy = kinds.contains(.activeEnergy) || kinds.contains(.distance) ? await workoutIntervals(on: key) : []
                for kind in AppleHealthKind.fromRingDays where kinds.contains(kind) && allowed(kind) {
                    let samples = AppleHealthPlan.samples(kind, day: day, busy: busy)
                    guard await write(samples, key: "\(kind.rawValue)|\(key)", version: version) else { return false }
                }
                await Task.yield()
            }
        }
        if kinds.contains(.body), allowed(.body) {
            let owner = ScaleHistoryStore.shared.activeProfile?.id
            for reading in ScaleHistoryStore.shared.readings where reading.profileID == nil || owner == nil || reading.profileID == owner {
                guard await write(AppleHealthPlan.body(reading), key: "body|\(reading.id.uuidString)", version: version) else {
                    return false
                }
            }
        }
        return true
    }

    /// Allowed to write at least one of the kind's types.
    private func allowed(_ kind: AppleHealthKind) -> Bool {
        kind.sampleTypes.contains { healthStore.authorizationStatus(for: $0) == .sharingAuthorized }
    }

    /// Sends one day's samples of one kind if they changed; false stops the sync (HealthKit refused).
    private func write(_ samples: [AppleHealthSample], key: String, version: Int) async -> Bool {
        let print = AppleHealthPlan.fingerprint(samples)
        guard fingerprints[key] != print else { return true }
        let objects: [HKObject] = samples.compactMap { sample in
            let metadata: [String: Any] = [HKMetadataKeySyncIdentifier: sample.syncID, HKMetadataKeySyncVersion: version]
            switch sample.value {
            case .quantity(let id, let unit, let value):
                let type = HKQuantityType(id)
                guard healthStore.authorizationStatus(for: type) == .sharingAuthorized else { return nil }
                return HKQuantitySample(type: type, quantity: HKQuantity(unit: HKUnit(from: unit), doubleValue: value),
                                        start: sample.start, end: sample.end, metadata: metadata)
            case .sleep(let value):
                let type = HKCategoryType(.sleepAnalysis)
                guard healthStore.authorizationStatus(for: type) == .sharingAuthorized else { return nil }
                return HKCategorySample(type: type, value: value.rawValue, start: sample.start, end: sample.end, metadata: metadata)
            }
        }
        if !objects.isEmpty {
            do {
                try await healthStore.save(objects)
            } catch {
                JcLog.dropped(JcLog.devices, "apple health sync", error)
                return false
            }
        }
        fingerprints[key] = print
        return true
    }

    /// Our own workouts on that day, whose active energy is already written.
    private func workoutIntervals(on key: String) async -> [DateInterval] {
        guard kinds.contains(.workouts), let midnight = RingDates.date(forKey: key),
              let next = Calendar.current.date(byAdding: .day, value: 1, to: midnight) else { return [] }
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: midnight, end: next),
            HKQuery.predicateForObjects(from: HKSource.default()),
        ])
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: predicate, limit: HKObjectQueryNoLimit,
                                      sortDescriptors: nil) { _, samples, _ in
                continuation.resume(returning: (samples ?? []).map { DateInterval(start: $0.startDate, end: $0.endDate) })
            }
            healthStore.execute(query)
        }
    }

    private func saveFingerprints() {
        try? JSONEncoder().encode(fingerprints).write(to: fingerprintsURL, options: .atomic)
    }
}

extension Notification.Name {
    /// The ring's days changed on the phone (a sync finished).
    static let jcRingDaysSynced = Notification.Name("jc.ring.daysSynced")
}

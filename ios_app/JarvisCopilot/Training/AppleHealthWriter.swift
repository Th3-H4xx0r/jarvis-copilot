import HealthKit

/// A workout as Apple Health will keep it.
struct HealthWorkoutPlan: Equatable {
    struct Reading: Equatable {
        var at: Date
        var bpm: Double
    }

    var activity: HKWorkoutActivityType
    var indoor: Bool
    var start: Date
    var end: Date
    var heartRates: [Reading]
    var activeKcal: Double
    var distanceType: HKQuantityTypeIdentifier?
    var meters: Double
    var effort: Int?
    var syncID: String
    var version: Int
}

/// How a Jarvis workout maps onto Apple Health's — pure, so it is tested
/// without HealthKit.
enum AppleHealthPlanner {
    /// The activity type for a ring sport, and whether it is indoors.
    static func activity(sport: Int) -> (HKWorkoutActivityType, indoor: Bool) {
        switch sport {
        case 7, 42: return (.running, false)
        case 40: return (.running, true)
        case 4: return (.walking, false)
        case 41: return (.walking, true)
        case 9: return (.cycling, false)
        case 24: return (.cycling, true)
        case 8: return (.hiking, false)
        case RingSport.strengthID: return (.traditionalStrengthTraining, true)
        case 22: return (.yoga, true)
        case 6: return (.swimming, true)
        case 5: return (.jumpRope, true)
        case 26: return (.elliptical, true)
        case 27: return (.rowing, true)
        case 80: return (.stairClimbing, true)
        case 89: return (.highIntensityIntervalTraining, true)
        case 94: return (.pilates, true)
        case 35: return (.cardioDance, true)
        case 31: return (.basketball, true)
        case 32: return (.soccer, false)
        case 29: return (.tennis, false)
        case 21: return (.badminton, true)
        case 30: return (.golf, false)
        case 20: return (.climbing, true)
        default: return (.other, true)
        }
    }

    /// The distance Apple Health files a sport's metres under, if any.
    static func distanceType(sport: Int) -> HKQuantityTypeIdentifier? {
        switch activity(sport: sport).0 {
        case .running, .walking, .hiking: return .distanceWalkingRunning
        case .cycling: return .distanceCycling
        case .swimming: return .distanceSwimming
        default: return nil
        }
    }

    /// One id per workout, from its start, so an edit replaces it.
    static func syncID(_ start: Date) -> String {
        "jarvis-" + HealthClient.instant.string(from: start).filter(\.isNumber)
    }

    static func plan(_ workout: RingWorkout, version: Int) -> HealthWorkoutPlan {
        let (activity, indoor) = activity(sport: workout.sport)
        let readings = workout.heartRates.enumerated().compactMap { i, bpm in
            bpm > 0 ? HealthWorkoutPlan.Reading(at: workout.start.addingTimeInterval(Double(i * 5)), bpm: Double(bpm)) : nil
        }
        let type = distanceType(sport: workout.sport)
        return HealthWorkoutPlan(activity: activity, indoor: indoor, start: workout.start, end: max(workout.end, workout.start),
                                 heartRates: readings.filter { $0.at <= workout.end }, activeKcal: max(0, workout.kilocalories),
                                 distanceType: type, meters: type == nil ? 0 : workout.distanceMeters, effort: workout.effort,
                                 syncID: syncID(workout.start), version: version)
    }
}

/// Saves workouts to Apple Health when the person turned it on in Health
/// settings: the workout, its heart rate, active calories, distance and — on
/// iOS 18 — its effort. Saving never waits on it and never fails for it.
@MainActor
final class AppleHealthWriter: ObservableObject {
    static let shared = AppleHealthWriter()

    private let healthStore = HKHealthStore()
    private let enabledKey = "jc.health.appleHealth"
    private let versionsKey = "jc.health.appleHealthVersions"

    @Published private(set) var enabled: Bool

    init() {
        enabled = UserDefaults.standard.bool(forKey: enabledKey)
    }

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// Allowed to write workouts (the person may have said no in Settings).
    var isAuthorized: Bool {
        isAvailable && healthStore.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized
    }

    private var sampleTypes: [HKSampleType] {
        [HKQuantityType(.heartRate), HKQuantityType(.activeEnergyBurned), HKQuantityType(.distanceWalkingRunning),
         HKQuantityType(.distanceCycling), HKQuantityType(.distanceSwimming)]
    }

    private var shareTypes: Set<HKSampleType> {
        var types = Set(sampleTypes)
        types.insert(HKObjectType.workoutType())
        if #available(iOS 18.0, *) { types.insert(HKQuantityType(.workoutEffortScore)) }
        return types
    }

    /// Turning it on asks for permission; it stays off if that is refused.
    @discardableResult
    func setEnabled(_ on: Bool) async -> Bool {
        guard on else {
            enabled = false
            UserDefaults.standard.set(false, forKey: enabledKey)
            return true
        }
        guard isAvailable else { return false }
        do {
            try await healthStore.requestAuthorization(toShare: shareTypes, read: [HKObjectType.workoutType()])
        } catch {
            JcLog.dropped(JcLog.devices, "apple health permission", error)
            return false
        }
        enabled = isAuthorized
        UserDefaults.standard.set(enabled, forKey: enabledKey)
        return enabled
    }

    private var versions: [String: Int] {
        get { UserDefaults.standard.dictionary(forKey: versionsKey) as? [String: Int] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: versionsKey) }
    }

    /// Save (or replace) a workout in Apple Health.
    func export(_ workout: RingWorkout) async {
        guard enabled, isAuthorized else { return }
        let id = AppleHealthPlanner.syncID(workout.start)
        let version = (versions[id] ?? 0) + 1
        // A second export is an edit: the old one and its samples go first,
        // so heart rate is not counted twice.
        if versions[id] != nil { await remove(start: workout.start) }
        do {
            try await save(AppleHealthPlanner.plan(workout, version: version))
            versions[id] = version
        } catch {
            JcLog.dropped(JcLog.devices, "apple health workout", error)
        }
    }

    /// Take a workout (and what was saved with it) out of Apple Health.
    func remove(start: Date) async {
        guard isAuthorized else { return }
        let id = AppleHealthPlanner.syncID(start)
        let predicate = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier, allowedValues: [id])
        let found: [HKWorkout] = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: predicate,
                                      limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                continuation.resume(returning: samples as? [HKWorkout] ?? [])
            }
            healthStore.execute(query)
        }
        for workout in found {
            for type in sampleTypes {
                _ = try? await healthStore.deleteObjects(of: type, predicate: HKQuery.predicateForObjects(from: workout))
            }
            if #available(iOS 18.0, *) {
                _ = try? await healthStore.deleteObjects(of: HKQuantityType(.workoutEffortScore),
                                                         predicate: HKQuery.predicateForWorkoutEffortSamplesRelated(workout: workout, activity: nil))
            }
            try? await healthStore.delete(workout)
        }
        versions[id] = nil
    }

    private func save(_ plan: HealthWorkoutPlan) async throws {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = plan.activity
        configuration.locationType = plan.indoor ? .indoor : .outdoor
        let builder = HKWorkoutBuilder(healthStore: healthStore, configuration: configuration, device: .local())
        try await builder.beginCollection(at: plan.start)
        let perMinute = HKUnit.count().unitDivided(by: .minute())
        var samples: [HKSample] = plan.heartRates.map {
            HKQuantitySample(type: HKQuantityType(.heartRate), quantity: HKQuantity(unit: perMinute, doubleValue: $0.bpm),
                             start: $0.at, end: $0.at)
        }
        if plan.activeKcal > 0 {
            samples.append(HKQuantitySample(type: HKQuantityType(.activeEnergyBurned),
                                            quantity: HKQuantity(unit: .kilocalorie(), doubleValue: plan.activeKcal),
                                            start: plan.start, end: plan.end))
        }
        if let type = plan.distanceType, plan.meters > 0 {
            samples.append(HKQuantitySample(type: HKQuantityType(type), quantity: HKQuantity(unit: .meter(), doubleValue: plan.meters),
                                            start: plan.start, end: plan.end))
        }
        if !samples.isEmpty { try await builder.addSamples(samples) }
        try await builder.addMetadata([HKMetadataKeySyncIdentifier: plan.syncID, HKMetadataKeySyncVersion: plan.version,
                                       HKMetadataKeyIndoorWorkout: plan.indoor])
        try await builder.endCollection(at: plan.end)
        guard let workout = try await builder.finishWorkout() else { return }
        if #available(iOS 18.0, *), let effort = plan.effort {
            let sample = HKQuantitySample(type: HKQuantityType(.workoutEffortScore),
                                          quantity: HKQuantity(unit: .appleEffortScore(), doubleValue: Double(effort)),
                                          start: plan.start, end: plan.end)
            try await healthStore.save(sample)
            try await healthStore.relateWorkoutEffortSample(sample, with: workout, activity: nil)
        }
    }
}

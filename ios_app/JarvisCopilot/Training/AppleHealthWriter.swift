import CoreLocation
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
    /// An outdoor workout's route, fix by fix, for Apple Health's map.
    var route: [CLLocation] = []
    /// Metres climbed, when the route measured it.
    var elevationGain: Double?
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

    /// A route as Apple Health takes it: located fixes inside the workout.
    static func locations(_ route: WorkoutRoute?, start: Date, end: Date) -> [CLLocation] {
        guard let route else { return [] }
        return route.points.compactMap { p in
            let time = route.start.addingTimeInterval(p.t)
            guard time >= start, time <= end else { return nil }
            return CLLocation(coordinate: p.coordinate, altitude: p.ele ?? 0, horizontalAccuracy: 5,
                              verticalAccuracy: p.ele == nil ? -1 : 5, course: -1, speed: p.speed ?? -1, timestamp: time)
        }
    }

    static func plan(_ workout: RingWorkout, version: Int, route: WorkoutRoute? = nil) -> HealthWorkoutPlan {
        let (activity, indoor) = activity(sport: workout.sport)
        let readings = workout.heartRates.enumerated().compactMap { i, bpm in
            bpm > 0 ? HealthWorkoutPlan.Reading(at: workout.start.addingTimeInterval(Double(i * 5)), bpm: Double(bpm)) : nil
        }
        let type = distanceType(sport: workout.sport)
        let end = max(workout.end, workout.start)
        return HealthWorkoutPlan(activity: activity, indoor: indoor, start: workout.start, end: end,
                                 heartRates: readings.filter { $0.at <= workout.end }, activeKcal: max(0, workout.kilocalories),
                                 distanceType: type, meters: type == nil ? 0 : workout.distanceMeters, effort: workout.effort,
                                 syncID: syncID(workout.start), version: version,
                                 route: locations(route, start: workout.start, end: end),
                                 elevationGain: workout.route?.gainMeters)
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
        types.insert(HKSeriesType.workoutRoute())
        if #available(iOS 18.0, *) { types.insert(HKQuantityType(.workoutEffortScore)) }
        return types
    }

    /// Why the last attempt to turn it on failed, in the person's words.
    @Published private(set) var problem: String?

    /// Turning it on asks for permission; it stays off if that is refused.
    @discardableResult
    func setEnabled(_ on: Bool) async -> Bool {
        problem = nil
        guard on else {
            enabled = false
            UserDefaults.standard.set(false, forKey: enabledKey)
            return true
        }
        guard isAvailable else {
            problem = "Apple Health isn't available on this device."
            return false
        }
        do {
            // Everything Jarvis can keep there, asked once; the switches in
            // Health settings decide what is actually written.
            try await healthStore.requestAuthorization(toShare: shareTypes.union(AppleHealthSync.shared.shareTypes),
                                                       read: [HKObjectType.workoutType()])
        } catch {
            JcLog.dropped(JcLog.devices, "apple health permission", error)
            // A build signed without the HealthKit capability is refused
            // before anyone is asked.
            problem = "\(error)".localizedCaseInsensitiveContains("entitlement")
                ? "This build of Jarvis can't reach Apple Health yet — it needs the HealthKit capability."
                : "Apple Health couldn't be reached. Try again in a moment."
            return false
        }
        // On if Apple Health allowed any of it; what each kind may write is
        // shown by its own switch.
        enabled = shareTypes.union(AppleHealthSync.shared.shareTypes)
            .contains { healthStore.authorizationStatus(for: $0) == .sharingAuthorized }
        if !enabled {
            problem = "Apple Health said no. Allow Jarvis in Settings › Health › Data Access & Devices, then turn this on again."
        }
        UserDefaults.standard.set(enabled, forKey: enabledKey)
        if enabled { Task { await AppleHealthSync.shared.syncNow() } }
        return enabled
    }

    private var versions: [String: Int] {
        get { UserDefaults.standard.dictionary(forKey: versionsKey) as? [String: Int] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: versionsKey) }
    }

    /// Save (or replace) a workout in Apple Health.
    func export(_ workout: RingWorkout) async {
        guard enabled, isAuthorized, AppleHealthSync.shared.isOn(.workouts) else { return }
        let id = AppleHealthPlanner.syncID(workout.start)
        let version = (versions[id] ?? 0) + 1
        // Whatever is filed under this workout goes first — an edit, or a
        // reinstall that forgot what was sent — so nothing is counted twice.
        await remove(start: workout.start)
        do {
            try await save(AppleHealthPlanner.plan(workout, version: version,
                                                   route: RouteStore.shared.route(start: workout.start)))
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
        // Only what the person allowed: a refused type would fail the lot.
        let allowed = { (type: HKQuantityTypeIdentifier) in
            self.healthStore.authorizationStatus(for: HKQuantityType(type)) == .sharingAuthorized
        }
        var samples: [HKSample] = !allowed(.heartRate) ? [] : plan.heartRates.map {
            HKQuantitySample(type: HKQuantityType(.heartRate), quantity: HKQuantity(unit: perMinute, doubleValue: $0.bpm),
                             start: $0.at, end: $0.at)
        }
        if plan.activeKcal > 0, allowed(.activeEnergyBurned) {
            samples.append(HKQuantitySample(type: HKQuantityType(.activeEnergyBurned),
                                            quantity: HKQuantity(unit: .kilocalorie(), doubleValue: plan.activeKcal),
                                            start: plan.start, end: plan.end))
        }
        if let type = plan.distanceType, plan.meters > 0, allowed(type) {
            samples.append(HKQuantitySample(type: HKQuantityType(type), quantity: HKQuantity(unit: .meter(), doubleValue: plan.meters),
                                            start: plan.start, end: plan.end))
        }
        if !samples.isEmpty { try await builder.addSamples(samples) }
        var metadata: [String: Any] = [HKMetadataKeySyncIdentifier: plan.syncID, HKMetadataKeySyncVersion: plan.version,
                                       HKMetadataKeyIndoorWorkout: plan.indoor]
        if let gain = plan.elevationGain, gain > 0 {
            metadata[HKMetadataKeyElevationAscended] = HKQuantity(unit: .meter(), doubleValue: gain)
        }
        try await builder.addMetadata(metadata)
        try await builder.endCollection(at: plan.end)
        guard let workout = try await builder.finishWorkout() else { return }
        versions[plan.syncID] = plan.version
        // The route is extra too: Fitness draws the map from it.
        if plan.route.count >= 2,
           healthStore.authorizationStatus(for: HKSeriesType.workoutRoute()) == .sharingAuthorized {
            do {
                let routeBuilder = HKWorkoutRouteBuilder(healthStore: healthStore, device: .local())
                for start in stride(from: 0, to: plan.route.count, by: 500) {
                    try await routeBuilder.insertRouteData(Array(plan.route[start..<min(plan.route.count, start + 500)]))
                }
                try await routeBuilder.finishRoute(with: workout, metadata: nil)
            } catch {
                JcLog.dropped(JcLog.devices, "apple health route", error)
            }
        }
        // Effort is extra: its failing leaves the workout saved.
        if #available(iOS 18.0, *), let effort = plan.effort, allowed(.workoutEffortScore) {
            do {
                let sample = HKQuantitySample(type: HKQuantityType(.workoutEffortScore),
                                              quantity: HKQuantity(unit: .appleEffortScore(), doubleValue: Double(effort)),
                                              start: plan.start, end: plan.end)
                try await healthStore.save(sample)
                try await healthStore.relateWorkoutEffortSample(sample, with: workout, activity: nil)
            } catch {
                JcLog.dropped(JcLog.devices, "apple health effort", error)
            }
        }
    }
}

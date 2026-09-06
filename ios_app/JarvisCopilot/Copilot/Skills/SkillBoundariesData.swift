import Contacts
import CoreLocation
import EventKit
import Foundation
#if canImport(HealthKit)
import HealthKit
#endif

/// Production implementations of the personal-data boundaries: location,
/// contacts, calendars and health.

// MARK: - Location

/// One-shot GPS fix.
///
/// The Flutter client capped the attempt and fell back to the last known
/// position so this returns in seconds instead of hanging to the server's 30 s
/// invoke timeout when a fresh fix is slow (indoors / cold start). Same shape
/// here: request → wait up to `timeout` → fall back to
/// `CLLocationManager.location`.
final class DefaultLocationFixer: NSObject, CLLocationManagerDelegate, LocationFixing, @unchecked Sendable {
    private let manager = CLLocationManager()
    private var pending: CheckedContinuation<CLLocation, Error>?
    private let lock = NSLock()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func oneShot(timeout: TimeInterval) async throws -> LocationFix {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            throw SkillError.permissionDenied("location")
        default:
            break
        }
        do {
            let location = try await withThrowingTaskGroup(of: CLLocation.self) { group in
                group.addTask { try await self.request() }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw SkillError.unavailable("location fix timed out")
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
            return Self.fix(location)
        } catch {
            // Falling back to whatever iOS already has beats failing the invoke.
            if let last = manager.location { return Self.fix(last) }
            throw SkillError.unavailable("no location fix available (try again outdoors)")
        }
    }

    private func request() async throws -> CLLocation {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if pending != nil {
                lock.unlock()
                continuation.resume(throwing: SkillError.failed("a location request is already running"))
                return
            }
            pending = continuation
            lock.unlock()
            manager.requestLocation()
        }
    }

    private func finish(_ result: Result<CLLocation, Error>) {
        lock.lock()
        let continuation = pending
        pending = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    private static func fix(_ location: CLLocation) -> LocationFix {
        LocationFix(latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    accuracyMeters: location.horizontalAccuracy,
                    timestamp: location.timestamp)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            finish(.failure(SkillError.unavailable("no location in update")))
            return
        }
        finish(.success(location))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(.failure(error))
    }
}

// MARK: - Contacts

final class DefaultContactsStore: ContactsStore {
    private let keys: [CNKeyDescriptor] = [
        CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
        CNContactPhoneNumbersKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor,
    ]

    func requestAccess() async throws -> Bool {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized:
            return true
        case .notDetermined:
            // A THROWN error here is not "the user said no" — it is a missing
            // usage description, a restricted device, or a CN failure — so it
            // propagates instead of reading as a denial.
            return try await CNContactStore().requestAccess(for: .contacts)
        default:
            // `.limited` (iOS 18) still lets us enumerate the shared subset.
            if #available(iOS 18.0, *),
               CNContactStore.authorizationStatus(for: .contacts) == .limited { return true }
            return false
        }
    }

    func contacts() async throws -> [ContactRecord] {
        let store = CNContactStore()
        let request = CNContactFetchRequest(keysToFetch: keys)
        var out: [ContactRecord] = []
        // enumerateContacts is synchronous and can be slow on a big address
        // book, so it runs off the main actor (this type is not isolated).
        try store.enumerateContacts(with: request) { contact, _ in
            let name = CNContactFormatter.string(from: contact, style: .fullName)
                ?? "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
            out.append(ContactRecord(
                name: name,
                phones: contact.phoneNumbers.map(\.value.stringValue),
                emails: contact.emailAddresses.map { $0.value as String }))
        }
        return out
    }
}

// MARK: - Calendars

final class DefaultCalendarAccess: CalendarAccessing {
    private let store = EKEventStore()

    func requestAccess() async throws -> Bool {
        // iOS 17 split read-only from write access; `add` needs write, so we ask
        // for full access once rather than prompting twice. A thrown error is
        // reported as itself rather than collapsing into "permission denied".
        try await store.requestFullAccessToEvents()
    }

    func events(from: Date, to: Date, limit: Int) async throws -> [CalendarEventRecord] {
        let calendars = store.calendars(for: .event)
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: calendars)
        return store.events(matching: predicate)
            .sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
            .prefix(max(1, limit))
            .map { event in
                CalendarEventRecord(
                    title: event.title ?? "",
                    notes: event.notes ?? "",
                    location: event.location ?? "",
                    start: event.startDate,
                    end: event.endDate,
                    allDay: event.isAllDay,
                    calendar: event.calendar?.title ?? "")
            }
    }

    func add(_ draft: CalendarEventDraft) async throws -> String {
        guard let calendar = store.defaultCalendarForNewEvents else {
            throw SkillError.unavailable("no writable calendar on this device")
        }
        let event = EKEvent(eventStore: store)
        event.title = draft.title
        event.notes = draft.notes.isEmpty ? nil : draft.notes
        event.location = draft.location.isEmpty ? nil : draft.location
        event.startDate = draft.start
        event.endDate = draft.end
        event.isAllDay = draft.allDay
        event.calendar = calendar
        try store.save(event, span: .thisEvent, commit: true)
        return event.eventIdentifier ?? ""
    }
}

// MARK: - Health

#if canImport(HealthKit)
/// Adapted from `mobile_client/ios/Runner/HealthKitBridge.swift`.
///
/// Authorization is requested lazily on the first read so the user only sees the
/// HealthKit prompt when the agent actually needs the data.
///
/// NOTE: this build does not carry the `com.apple.developer.healthkit`
/// entitlement (see JarvisCopilot.entitlements). HealthKit links and compiles
/// without it, and `isHealthDataAvailable()` / `requestAuthorization` then fail
/// cleanly, which the skill reports as `{error: …}` — the same graceful path the
/// Flutter client took on a device with Health disabled. Add the entitlement +
/// `NSHealthShareUsageDescription` to turn it on for real.
final class DefaultHealthReader: HealthReading {
    private let store = HKHealthStore()

    func read(metric: String, days: Int) async throws -> [HealthSample] {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw SkillError.unavailable("HealthKit unavailable")
        }
        guard let type = Self.sampleType(for: metric) else {
            throw SkillError.badArgument("unknown metric: \(metric)")
        }
        do {
            try await store.requestAuthorization(toShare: [], read: [type])
        } catch {
            throw SkillError.permissionDenied("health")
        }
        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -max(1, days), to: end) ?? end
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end,
                                                    options: .strictStartDate)
        let samples: [HKSample] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate,
                                      limit: 256, sortDescriptors: nil) { _, samples, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: samples ?? []) }
            }
            store.execute(query)
        }
        return samples.compactMap { Self.map($0, metric: metric) }
    }

    private static func sampleType(for metric: String) -> HKSampleType? {
        switch metric {
        case "steps":      return HKObjectType.quantityType(forIdentifier: .stepCount)
        case "heart_rate": return HKObjectType.quantityType(forIdentifier: .heartRate)
        case "sleep":      return HKObjectType.categoryType(forIdentifier: .sleepAnalysis)
        case "workouts":   return HKObjectType.workoutType()
        default:           return nil
        }
    }

    private static func map(_ sample: HKSample, metric: String) -> HealthSample? {
        if let workout = sample as? HKWorkout {
            return HealthSample(activity: "\(workout.workoutActivityType.rawValue)",
                                durationSeconds: workout.duration,
                                start: workout.startDate, end: workout.endDate)
        }
        if let quantity = sample as? HKQuantitySample {
            let unit: HKUnit = metric == "heart_rate"
                ? HKUnit.count().unitDivided(by: .minute())
                : .count()
            return HealthSample(value: quantity.quantity.doubleValue(for: unit),
                                unit: unit.unitString,
                                start: quantity.startDate, end: quantity.endDate)
        }
        if let category = sample as? HKCategorySample {
            return HealthSample(category: category.value,
                                start: category.startDate, end: category.endDate)
        }
        return nil
    }
}
#endif

/// Stand-in for a build without HealthKit (or without the entitlement), so the
/// skill catalogue shape never depends on the framework being present.
final class UnavailableHealthReader: HealthReading {
    func read(metric: String, days: Int) async throws -> [HealthSample] {
        throw SkillError.unavailable("HealthKit is not enabled in this build")
    }
}

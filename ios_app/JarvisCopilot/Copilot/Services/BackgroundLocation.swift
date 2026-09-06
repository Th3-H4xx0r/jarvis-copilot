import Foundation
#if canImport(CoreLocation)
import CoreLocation
#endif

/// The body `POST /api/devices/mobile/location` carries. Reuses the app's one
/// location value (`LocationFix`, declared next to the `get_location` skill's
/// boundary) so a fix means the same thing however it was obtained.
extension LocationFix {
    var locationJSON: [String: Any] {
        ["lat": latitude, "lng": longitude, "accuracy": accuracyMeters,
         "ts": timestamp.timeIntervalSince1970]
    }

    /// Equatable synthesis needs the declaring file, and this type lives in
    /// `SkillBoundaries.swift` — so the comparison the location service needs is
    /// spelled out here instead.
    func matches(_ other: LocationFix) -> Bool {
        latitude == other.latitude && longitude == other.longitude
            && accuracyMeters == other.accuracyMeters && timestamp == other.timestamp
    }
}

/// The CoreLocation boundary: ask for Always authorization and monitor
/// significant location changes.
///
/// Significant-change monitoring is the only mechanism that survives a
/// force-quit — iOS relaunches the app on ~500 m of movement even after the user
/// swiped it away — which is exactly why the Flutter client ran it natively
/// rather than through the Dart `geolocator` stream.
@MainActor
protocol LocationMonitoring: AnyObject {
    /// Whether the device can do significant-change monitoring at all.
    var isAvailable: Bool { get }
    /// Prompts if needed. False when the user refused (the caller must leave the
    /// switch off rather than claim the app is tracking).
    func requestAlwaysAuthorization() async -> Bool
    func startMonitoring()
    func stopMonitoring()
    var onFix: ((LocationFix) -> Void)? { get set }
}

/// Opt-in background location history.
///
/// Port of `services/background_location.dart` and the SLC half of the Flutter
/// `AppDelegate`. Two jobs:
///
///  1. push a fix to `/api/devices/mobile/location` every ~10 min, or sooner on
///     real movement, so the agent can answer "where was I on Tuesday";
///  2. keep the process alive in the background as a side effect of the
///     `location` background mode (this app's primary keepalive is the silent
///     audio session, so this one is a bonus rather than the mechanism).
///
/// Off by default: it costs Always-location, the status-bar indicator and
/// battery.
@MainActor
final class BackgroundLocationService: LocationTracking {

    /// The app's tracker. `AppServices` re-arms it at launch and the settings
    /// screen toggles it — both must reach the SAME object, or the switch would
    /// start a second CLLocationManager alongside the one already running.
    static let shared = BackgroundLocationService()

    /// Report at most this often on a stationary device…
    static let minInterval: TimeInterval = 10 * 60
    /// …unless the device moved at least this far, which reports immediately.
    static let minMeters: Double = 75

    private let api: JarvisAPI
    private let preferences: KeyValueStore
    private var monitor: any LocationMonitoring
    private let now: @MainActor () -> Date

    private(set) var enabled = false
    private(set) var lastReported: LocationFix?
    private var lastReportAt = Date(timeIntervalSince1970: 0)

    init(api: JarvisAPI = .shared,
         preferences: KeyValueStore = UserDefaults.standard,
         monitor: (any LocationMonitoring)? = nil,
         now: (@MainActor () -> Date)? = nil) {
        self.api = api
        self.preferences = preferences
        self.monitor = monitor ?? DefaultLocationMonitor()
        self.now = now ?? { Date() }
        self.monitor.onFix = { [weak self] fix in self?.received(fix) }
    }

    /// Re-arm on launch if the user left tracking on — including the launch iOS
    /// itself triggered for a location event after a force-quit.
    func startIfEnabled() {
        guard preferences.bool(SettingsStore.Keys.trackLocation) == true else { return }
        guard monitor.isAvailable else { return }
        enabled = true
        monitor.startMonitoring()
    }

    /// `LocationTracking`: the settings toggle. Returns whether tracking is on
    /// afterwards.
    @discardableResult
    func setEnabled(_ on: Bool) async -> Bool {
        guard on else {
            enabled = false
            monitor.stopMonitoring()
            return true
        }
        guard monitor.isAvailable else { return false }
        guard await monitor.requestAlwaysAuthorization() else { return false }
        enabled = true
        monitor.startMonitoring()
        return true
    }

    /// Decide whether a fix is worth a POST. Pure so the "10 minutes OR 75 m"
    /// rule can be asserted without a clock or a network.
    static func shouldReport(_ fix: LocationFix, lastReported: LocationFix?,
                             lastReportAt: Date, now: Date) -> Bool {
        guard let lastReported else { return true }
        if now.timeIntervalSince(lastReportAt) >= minInterval { return true }
        return distanceMeters(lastReported, fix) >= minMeters
    }

    /// Equirectangular approximation — at these distances (tens of metres) it is
    /// within a fraction of a percent of the haversine, and it keeps this pure
    /// and dependency-free.
    static func distanceMeters(_ a: LocationFix, _ b: LocationFix) -> Double {
        let earth = 6_371_000.0
        let toRadians = Double.pi / 180
        let meanLatitude = (a.latitude + b.latitude) / 2 * toRadians
        let x = (b.longitude - a.longitude) * toRadians * cos(meanLatitude)
        let y = (b.latitude - a.latitude) * toRadians
        return earth * (x * x + y * y).squareRoot()
    }

    private func received(_ fix: LocationFix) {
        guard enabled else { return }
        guard Self.shouldReport(fix, lastReported: lastReported,
                                lastReportAt: lastReportAt, now: now()) else { return }
        lastReported = fix
        lastReportAt = now()
        Task { await report(fix) }
    }

    /// `POST /api/devices/mobile/location`. A failure is not surfaced — the next
    /// fix tries again and a dropped history row is not worth a banner — but it
    /// is logged, so "why is my location history full of holes" is answerable.
    func report(_ fix: LocationFix) async {
        do {
            _ = try await api.post("/api/devices/mobile/location", json: fix.locationJSON)
        } catch {
            JcLog.dropped(JcLog.services, "location report", error)
        }
    }
}

#if canImport(CoreLocation)
/// `CLLocationManager` significant-change monitoring.
@MainActor
final class DefaultLocationMonitor: NSObject, LocationMonitoring, CLLocationManagerDelegate {
    var onFix: ((LocationFix) -> Void)?

    /// How long to wait for `locationManagerDidChangeAuthorization` before
    /// answering with whatever status can be read right now.
    ///
    /// iOS silently NO-OPS an authorization request it considers already
    /// answered — a second "Always" ask in the same launch, a Screen Time /
    /// MDM-restricted device, a prompt the user dismissed with a phone call.
    /// No delegate callback ever arrives in those cases, so without a deadline
    /// `SettingsStore.setTrackLocation` awaits forever (the toggle spins) and
    /// the continuation leaks.
    static let authorizationTimeout: TimeInterval = 10

    private let manager = CLLocationManager()
    private var authorizationWaiters: [CheckedContinuation<Bool, Never>] = []
    private var authorizationDeadline: Task<Void, Never>?
    private let authorizationTimeout: TimeInterval

    init(authorizationTimeout: TimeInterval = DefaultLocationMonitor.authorizationTimeout) {
        self.authorizationTimeout = authorizationTimeout
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        // SLC is already cell-tower cheap; let iOS apply its own power
        // heuristics rather than defeating them.
        manager.pausesLocationUpdatesAutomatically = true
    }

    var isAvailable: Bool {
        CLLocationManager.significantLocationChangeMonitoringAvailable()
    }

    func requestAlwaysAuthorization() async -> Bool {
        switch manager.authorizationStatus {
        case .authorizedAlways:
            return true
        case .denied, .restricted:
            return false
        case .authorizedWhenInUse:
            // iOS only offers "Always" as an upgrade prompt after When-In-Use has
            // been granted, so this is a second, separate ask.
            manager.requestAlwaysAuthorization()
            return await waitForAuthorization()
        default:
            manager.requestWhenInUseAuthorization()
            let granted = await waitForAuthorization()
            guard granted else { return false }
            manager.requestAlwaysAuthorization()
            return await waitForAuthorization()
        }
    }

    /// Park until the delegate reports a decision, the deadline expires, or
    /// monitoring is torn down. Never hangs. Not private so the deadline can be
    /// asserted without driving a real system prompt.
    func waitForAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            authorizationWaiters.append(continuation)
            armAuthorizationDeadline()
        }
    }

    private func armAuthorizationDeadline() {
        authorizationDeadline?.cancel()
        let seconds = authorizationTimeout
        authorizationDeadline = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.finishAuthorization(Self.isGranted(self.manager.authorizationStatus))
        }
    }

    /// Resume every parked waiter exactly once. Safe with none parked.
    private func finishAuthorization(_ granted: Bool) {
        authorizationDeadline?.cancel()
        authorizationDeadline = nil
        let waiters = authorizationWaiters
        authorizationWaiters = []
        for waiter in waiters { waiter.resume(returning: granted) }
    }

    /// Pure: which statuses count as "the app may use location".
    static func isGranted(_ status: CLAuthorizationStatus) -> Bool {
        status == .authorizedAlways || status == .authorizedWhenInUse
    }

    func startMonitoring() {
        // Requires the `location` background mode plus Always authorization to
        // deliver while backgrounded.
        manager.allowsBackgroundLocationUpdates = true
        manager.startMonitoringSignificantLocationChanges()
    }

    func stopMonitoring() {
        manager.stopMonitoringSignificantLocationChanges()
        manager.allowsBackgroundLocationUpdates = false
        // Tearing down while a prompt is parked (the user switched the toggle
        // back off) must not strand the waiter — it would leak its continuation.
        finishAuthorization(Self.isGranted(manager.authorizationStatus))
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        let fix = LocationFix(latitude: last.coordinate.latitude,
                              longitude: last.coordinate.longitude,
                              accuracyMeters: last.horizontalAccuracy,
                              timestamp: last.timestamp)
        Task { @MainActor [weak self] in self?.onFix?(fix) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            guard let self else { return }
            // `.notDetermined` means the prompt is still up — keep waiting.
            guard status != .notDetermined else { return }
            self.finishAuthorization(Self.isGranted(status))
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Nothing to do: a failed fix simply means no report this time.
    }
}
#else
@MainActor
final class DefaultLocationMonitor: LocationMonitoring {
    var onFix: ((LocationFix) -> Void)?
    var isAvailable: Bool { false }
    func requestAlwaysAuthorization() async -> Bool { false }
    func startMonitoring() {}
    func stopMonitoring() {}
}
#endif

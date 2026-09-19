import CoreLocation
import CoreMotion
import UIKit

/// Outdoor workouts' route, distance, pace and climbing from the phone's GPS
/// and barometer (and steps from its pedometer), only while one runs. The
/// judging of fixes lives in `RouteRecording`; this is the sensors around it.
/// The route is checkpointed to disk every ten seconds, so a relaunch in the
/// middle of a run carries on the same line.
@MainActor
final class WorkoutLocation: NSObject, WorkoutLocationTracking, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let altimeter = CMAltimeter()
    private let pedometer = CMPedometer()
    private var recording: RouteRecording?
    private var sport = 0
    private var update: ((RouteProgress) -> Void)?
    private var pressure: (altitude: Double, at: Date)?
    private var lastCheckpoint = Date.distantPast
    private var resigning: NSObjectProtocol?

    var heartRate: (() -> Int?)?
    private(set) var steps: Int?
    /// Steps a minute, from the pedometer.
    private(set) var cadence: Int?
    private(set) var lastFix: CLLocationCoordinate2D?
    /// The best accuracy any fix had (kept or not), to say why there's no route.
    private(set) var bestAccuracy: Double?

    struct Checkpoint: Codable {
        var sport: Int
        var recording: RouteRecording
    }

    static var checkpointURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Routes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("active.json")
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .fitness
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 2
        manager.pausesLocationUpdatesAutomatically = false
    }

    var route: WorkoutRoute? { recording?.route }
    var progress: RouteProgress { recording?.progress ?? RouteProgress() }

    func start(sport: Int, weightKg: Double, at start: Date, resuming: Bool,
               update: @escaping (RouteProgress) -> Void) {
        self.update = update
        self.sport = sport
        // Nothing carries over from the last workout.
        steps = nil
        cadence = nil
        lastFix = nil
        pressure = nil
        bestAccuracy = nil
        if resuming, let saved = Self.checkpoint(), saved.sport == sport,
           Date().timeIntervalSince(saved.recording.start) < 12 * 3600,
           saved.recording.start <= start.addingTimeInterval(5) {
            // Back after a relaunch: the same route, a new segment from here.
            recording = saved.recording
            recording?.pause()
            recording?.resume()
        } else {
            recording = RouteRecording(start: start, sport: sport, weightKg: weightKg)
            // At once: an earlier workout's route must not be the one a relaunch finds.
            checkpoint()
        }
        let from = recording?.start ?? start
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        askForPrecision()
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        if CMAltimeter.isAbsoluteAltitudeAvailable() {
            altimeter.startAbsoluteAltitudeUpdates(to: .main) { [weak self] data, _ in
                guard let data else { return }
                MainActor.assumeIsolated { self?.pressure = (data.altitude, Date()) }
            }
        }
        if CMPedometer.isStepCountingAvailable() {
            pedometer.startUpdates(from: from) { [weak self] data, _ in
                guard let data else { return }
                let steps = data.numberOfSteps.intValue
                let cadence = data.currentCadence.map { Int(($0.doubleValue * 60).rounded()) }
                Task { @MainActor in
                    self?.steps = steps
                    self?.cadence = cadence
                }
            }
        }
        resigning = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
                                                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkpoint() }
        }
        update(progress)
    }

    func pause() {
        recording?.pause()
        checkpoint()
        update?(progress)
    }

    func resume() {
        recording?.resume()
        update?(progress)
    }

    @discardableResult
    func stop() -> WorkoutRoute? {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        altimeter.stopAbsoluteAltitudeUpdates()
        pedometer.stopUpdates()
        if let resigning { NotificationCenter.default.removeObserver(resigning) }
        resigning = nil
        update = nil
        let route = recording?.route
        recording = nil
        try? FileManager.default.removeItem(at: Self.checkpointURL)
        guard let route, route.points.count >= 2 else { return nil }
        return route
    }

    /// Approximate location is ~1 km: no fix would ever count. Ask for precise
    /// for this workout (the person can still say no).
    private func askForPrecision() {
        guard recording != nil, manager.authorizationStatus == .authorizedWhenInUse
                || manager.authorizationStatus == .authorizedAlways,
              manager.accuracyAuthorization == .reducedAccuracy else { return }
        manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "WorkoutRoute")
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.askForPrecision() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in self.take(locations) }
    }

    func take(_ locations: [CLLocation], now: Date = Date()) {
        guard recording != nil else { return }
        var changed = false
        let baro = pressure.flatMap { now.timeIntervalSince($0.at) < 5 ? $0.altitude : nil }
        for location in locations {
            if location.horizontalAccuracy > 0 {
                bestAccuracy = min(bestAccuracy ?? .infinity, location.horizontalAccuracy)
            }
            let fix = RouteFix(time: location.timestamp, lat: location.coordinate.latitude,
                               lon: location.coordinate.longitude, horizontalAccuracy: location.horizontalAccuracy,
                               altitude: location.verticalAccuracy > 0 ? location.altitude : nil,
                               verticalAccuracy: location.verticalAccuracy,
                               speed: location.speed >= 0 ? location.speed : nil)
            if recording?.take(fix, heartRate: heartRate?(), pressureAltitude: baro, now: max(now, location.timestamp)) == true {
                changed = true
                lastFix = location.coordinate
            }
        }
        guard changed else { return }
        update?(progress)
        if now.timeIntervalSince(lastCheckpoint) >= 10 { checkpoint(now) }
    }

    /// Why a workout ended with no route, in the person's words (nil when it has one).
    var noRouteReason: String? {
        guard (recording?.route.points.count ?? 0) < 2 else { return nil }
        switch manager.authorizationStatus {
        case .denied, .restricted: return "Location was off for Jarvis, so no route was recorded."
        default: break
        }
        if manager.accuracyAuthorization == .reducedAccuracy {
            return "Precise Location was off, so no route was recorded."
        }
        guard let best = bestAccuracy else { return "The iPhone never got a GPS fix, so no route was recorded." }
        return "GPS was too vague to draw a route (±\(Int(best.rounded())) m at best — indoors?)."
    }

    private func checkpoint(_ now: Date = Date()) {
        guard let recording else { return }
        lastCheckpoint = now
        let data = try? JSONEncoder().encode(Checkpoint(sport: sport, recording: recording))
        try? data?.write(to: Self.checkpointURL, options: .atomic)
    }

    static func checkpoint() -> Checkpoint? {
        guard let data = try? Data(contentsOf: checkpointURL) else { return nil }
        return try? JSONDecoder().decode(Checkpoint.self, from: data)
    }
}

import CoreLocation

/// Outdoor workouts' distance and pace from the phone's GPS, only while one
/// runs. Fixes worse than 20 m, or jumps faster than a car, are ignored.
@MainActor
final class WorkoutLocation: NSObject, WorkoutLocationTracking, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var update: ((Double, Double?) -> Void)?
    private var last: CLLocation?
    private var distance: Double = 0
    /// (time, distance so far) — pace is the time the last kilometre took.
    private var marks: [(Date, Double)] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .fitness
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
    }

    func start(_ update: @escaping (Double, Double?) -> Void) {
        self.update = update
        distance = 0
        last = nil
        marks = []
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        update = nil
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in self.take(locations) }
    }

    private func take(_ locations: [CLLocation]) {
        for fix in locations where fix.horizontalAccuracy > 0 && fix.horizontalAccuracy <= 20 {
            if let last {
                let step = fix.distance(from: last)
                let seconds = fix.timestamp.timeIntervalSince(last.timestamp)
                guard seconds > 0, step / seconds < 40 else { continue }
                distance += step
            }
            last = fix
            marks.append((fix.timestamp, distance))
        }
        marks.removeAll { distance - $0.1 > 1000 && marks.count > 2 }
        var pace: Double?
        if let first = marks.first, let end = marks.last, end.1 - first.1 >= 200 {
            pace = end.0.timeIntervalSince(first.0) / ((end.1 - first.1) / 1000)
        }
        update?(distance, pace)
    }
}

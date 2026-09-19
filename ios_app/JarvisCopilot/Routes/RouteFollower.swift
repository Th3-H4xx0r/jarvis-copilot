import CoreLocation
import UIKit
import UserNotifications

/// A past route to follow: its line, how long it is, and how far along it
/// (and how far off it) any point is.
struct RouteGuide: Equatable, Identifiable {
    let id: String
    let title: String
    let sport: Int
    let lats: [Double]
    let lons: [Double]
    /// Metres along the guide to each vertex.
    let along: [Double]
    let preview: String

    var total: Double { along.last ?? 0 }
    var coordinates: [CLLocationCoordinate2D] { zip(lats, lons).map { CLLocationCoordinate2D(latitude: $0, longitude: $1) } }

    init(route: WorkoutRoute, title: String, sport: Int) {
        let points = RouteMath.simplify(route.points, tolerance: 3)
        id = RouteStore.key(route.start)
        self.title = title
        self.sport = sport
        lats = points.map(\.lat)
        lons = points.map(\.lon)
        var along = [0.0]
        for (a, b) in zip(points, points.dropFirst()) { along.append(along.last! + RouteMath.distance(a, b)) }
        self.along = points.isEmpty ? [] : along
        var outline = points
        var tolerance = 6.0
        while outline.count > 120 {
            outline = RouteMath.simplify(points, tolerance: tolerance)
            tolerance *= 1.6
        }
        preview = RouteMath.encode(outline.map { ($0.lat, $0.lon) })
    }

    /// The guide from `start` metres along to its end: what is still ahead.
    func coordinates(from start: Double) -> [CLLocationCoordinate2D] {
        guard start > 0, lats.count >= 2 else { return coordinates }
        guard let next = along.firstIndex(where: { $0 > start }) else { return [] }
        let i = max(0, next - 1)
        let span = along[next] - along[i]
        let t = span > 0 ? (start - along[i]) / span : 0
        let head = CLLocationCoordinate2D(latitude: lats[i] + (lats[next] - lats[i]) * t,
                                          longitude: lons[i] + (lons[next] - lons[i]) * t)
        return [head] + (next..<lats.count).map { CLLocationCoordinate2D(latitude: lats[$0], longitude: lons[$0]) }
    }

    /// The nearest point of the guide: how far along it, and how far off.
    /// Near `hint` (where you were along it) first, so a loop that passes
    /// close to itself doesn't jump you to the wrong lap.
    func project(lat: Double, lon: Double, near hint: Double? = nil) -> (along: Double, off: Double) {
        guard lats.count >= 2 else {
            return (0, lats.first.map { RouteMath.distance(lat, lon, $0, lons[0]) } ?? .infinity)
        }
        func search(_ range: Range<Int>) -> (along: Double, off: Double) {
            let kx = cos(lat * .pi / 180) * 111_320, ky = 110_540.0
            var best = (along: 0.0, off: Double.infinity)
            for i in range {
                let ax = (lons[i] - lon) * kx, ay = (lats[i] - lat) * ky
                let bx = (lons[i + 1] - lon) * kx, by = (lats[i + 1] - lat) * ky
                let dx = bx - ax, dy = by - ay
                let length = dx * dx + dy * dy
                let t = length > 0 ? max(0, min(1, -(ax * dx + ay * dy) / length)) : 0
                let px = ax + t * dx, py = ay + t * dy
                let off = sqrt(px * px + py * py)
                if off < best.off { best = (along[i] + t * (along[i + 1] - along[i]), off) }
            }
            return best
        }
        let all = 0..<(lats.count - 1)
        if let hint {
            let lo = along.firstIndex { $0 >= hint - 400 } ?? 0
            let hi = along.firstIndex { $0 > hint + 400 } ?? lats.count - 1
            let near = search(max(0, lo - 1)..<max(max(0, lo - 1) + 1, min(lats.count - 1, hi)))
            if near.off < 60 { return near }
        }
        return search(all)
    }
}

/// Tells when you have strayed from a guide (more than 40 m for 15 s) and
/// when you are back on it (within 25 m) — a buzz for each, not one for
/// every wobble of GPS.
struct OffRouteDetector: Equatable {
    enum Event: Equatable { case offRoute, backOnRoute }

    var offThreshold = 40.0
    var backThreshold = 25.0
    var dwell: TimeInterval = 15
    private(set) var isOff = false
    private var since: Date?

    mutating func update(off: Double, at time: Date) -> Event? {
        if isOff {
            guard off <= backThreshold else { return nil }
            isOff = false
            since = nil
            return .backOnRoute
        }
        guard off > offThreshold else {
            since = nil
            return nil
        }
        let began = since ?? time
        since = began
        guard time.timeIntervalSince(began) >= dwell else { return nil }
        isOff = true
        return .offRoute
    }
}

/// Straying from a followed route, said out loud: a buzz in the app, a
/// time-sensitive notification when the phone is in a pocket.
@MainActor
enum RouteAlerts {
    static func announce(_ event: OffRouteDetector.Event) {
        UINotificationFeedbackGenerator().notificationOccurred(event == .offRoute ? .warning : .success)
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = event == .offRoute ? "Off route" : "Back on route"
        content.body = event == .offRoute ? "You've left the route you're following." : "You're back on the route."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "jc.offroute", content: content, trigger: nil))
    }
}

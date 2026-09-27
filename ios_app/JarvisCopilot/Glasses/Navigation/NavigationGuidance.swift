import Foundation
import CoreLocation

/// Flat-earth helpers for the short distances turn-by-turn works in (metres, north/east).
enum NavigationGeo {
    static let metresPerDegree = 111_320.0
    static func offset(_ c: CLLocationCoordinate2D, north: Double, east: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: c.latitude + north / metresPerDegree,
                               longitude: c.longitude + east / (metresPerDegree * cos(c.latitude * .pi / 180)))
    }
    /// (east, north) metres of `c` relative to `origin`.
    static func local(_ c: CLLocationCoordinate2D, from origin: CLLocationCoordinate2D) -> (x: Double, y: Double) {
        ((c.longitude - origin.longitude) * metresPerDegree * cos(origin.latitude * .pi / 180), (c.latitude - origin.latitude) * metresPerDegree)
    }
    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let p = local(b, from: a); return (p.x * p.x + p.y * p.y).squareRoot()
    }
    /// Compass bearing a→b in degrees (0 = north, 90 = east).
    static func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let p = local(b, from: a); let d = atan2(p.x, p.y) * 180 / .pi; return d < 0 ? d + 360 : d
    }
}

/// Turn-by-turn as lens cards: the GO3 firmware has no navigation screen (the official
/// app only speaks directions), but it does draw notification cards. Basic arrow
/// characters only — the lens font may not carry emoji.
enum NavigationCards {
    static func turn(_ u: NavigationGuidance.Update, imperial: Bool) -> (title: String, body: String) {
        let title = u.guideType == 1 ? "Arrive · \(u.roadName)" : "\(arrow(u.guideType)) \(u.roadName)"
        return (title, "\(distance(Double(u.toManeuver), imperial: imperial)) · \(distance(Double(u.remaining), imperial: imperial)) left · ETA \(u.reachTime)")
    }
    static func arrow(_ type: Int) -> String {
        switch type {
        case 2: return "↶"
        case 10: return "↷"
        case 3, 4: return "↰"
        case 8, 9: return "↱"
        case 5, 11, 13, 15, 18: return "↖"
        case 7, 12, 14, 17, 19: return "↗"
        case 20, 22, 24...35: return "↺"
        case 21, 23, 36...47: return "↻"
        default: return "↑"
        }
    }
    static func distance(_ metres: Double, imperial: Bool) -> String {
        if imperial {
            let miles = metres / 1609.344
            return miles < 0.1 ? "\(Int((metres * 3.28084 / 10).rounded()) * 10) ft" : String(format: "%.1f mi", miles)
        }
        if metres >= 1000 { return String(format: "%.1f km", metres / 1000) }
        return metres < 100 ? "\(Int(metres.rounded())) m" : "\(Int((metres / 10).rounded()) * 10) m"
    }
    /// 0 = announce (a new next turn), 1 = close, 2 = turn now.
    static func stage(toManeuver: Int64, walking: Bool) -> Int {
        let (near, now): (Int64, Int64) = walking ? (60, 15) : (150, 30)
        return toManeuver <= now ? 2 : toManeuver <= near ? 1 : 0
    }
}

/// A planned route as MapKit hands it over: steps with an instruction and a polyline each.
/// The route's shape is the steps' polylines joined end to end.
struct NavigationRoute {
    struct Step { var instructions: String; var points: [CLLocationCoordinate2D] }
    var steps: [Step]
    var expectedTime: TimeInterval
    var points: [CLLocationCoordinate2D] {
        steps.flatMap(\.points).reduce(into: []) { out, p in
            if let last = out.last, NavigationGeo.distance(last, p) < 0.5 { return }
            out.append(p)
        }
    }
}

/// Turn-by-turn state for one route: where along it you are, the next maneuver and
/// what the lens should show. Pure (no sensors) so it can be tested with synthetic routes.
struct NavigationGuidance {
    struct Update: Equatable {
        var guideType: Int
        var roadName: String
        var toManeuver: Int64
        var remaining: Int64
        var remainingSeconds: Int64
        var reachTime: String
        var offRoute: Double
        var arrived: Bool
        var along: Double
    }
    let route: NavigationRoute
    let points: [CLLocationCoordinate2D]
    private let cumulative: [Double]
    /// Along-route distance where each step starts; step i's maneuver is at stepStart[i].
    private let stepStart: [Double]
    var total: Double { cumulative.last ?? 0 }
    private var progress: Double = 0

    init(route: NavigationRoute) {
        self.route = route
        points = route.points
        var sums: [Double] = [0]
        for i in points.indices.dropFirst() { sums.append(sums[i - 1] + NavigationGeo.distance(points[i - 1], points[i])) }
        cumulative = sums
        var starts: [Double] = []
        var walked = 0.0
        for step in route.steps {
            starts.append(walked)
            walked += zip(step.points, step.points.dropFirst()).reduce(0) { $0 + NavigationGeo.distance($1.0, $1.1) }
        }
        stepStart = starts
    }

    mutating func update(at location: CLLocationCoordinate2D, now: Date, timeZone: TimeZone = .current) -> Update {
        let (along, off) = project(location)
        // Don't slide backwards along the line on GPS jitter (loops excepted: a big jump back is real).
        progress = along >= progress - 30 ? max(along, progress - 5) : along
        let remaining = max(0, total - progress)
        let next = stepStart.indices.first { $0 > 0 && stepStart[$0] > progress + 1 }
        let isFinal = next == nil || next == route.steps.count - 1 || stepStart[next!] >= total - 1
        let guide: Int
        let road: String
        let toManeuver: Double
        if let i = next, !isFinal {
            guide = Self.guideType(turn: turnAngle(at: i), instructions: route.steps[i].instructions)
            road = Self.roadName(route.steps[i].instructions)
            toManeuver = stepStart[i] - progress
        } else {
            guide = 1
            road = Self.roadName(route.steps.last?.instructions ?? "")
            toManeuver = remaining
        }
        let seconds = total > 0 ? route.expectedTime * remaining / total : 0
        return Update(guideType: guide, roadName: road.isEmpty ? "Unnamed road" : road, toManeuver: Int64(toManeuver.rounded()),
                      remaining: Int64(remaining), remainingSeconds: Int64(seconds.rounded()),
                      reachTime: Self.reachTime(now.addingTimeInterval(seconds), timeZone: timeZone),
                      offRoute: off, arrived: remaining < 15 && off < 40, along: progress)
    }

    /// Nearest point on the route: (metres along it, metres away from it).
    private func project(_ c: CLLocationCoordinate2D) -> (Double, Double) {
        guard points.count > 1 else { return (0, points.first.map { NavigationGeo.distance($0, c) } ?? 0) }
        var best = (along: 0.0, off: Double.greatestFiniteMagnitude)
        for i in 0..<(points.count - 1) {
            let a = NavigationGeo.local(points[i], from: c), b = NavigationGeo.local(points[i + 1], from: c)
            let dx = b.x - a.x, dy = b.y - a.y, len2 = dx * dx + dy * dy
            let t = len2 > 0 ? max(0, min(1, -(a.x * dx + a.y * dy) / len2)) : 0
            let px = a.x + t * dx, py = a.y + t * dy
            let off = (px * px + py * py).squareRoot()
            if off < best.off { best = (cumulative[i] + t * (cumulative[i + 1] - cumulative[i]), off) }
        }
        return best
    }

    /// Signed turn at step i's start in degrees: + right, − left.
    private func turnAngle(at i: Int) -> Double {
        guard i > 0, let before = Self.lastBearing(route.steps[i - 1].points), let after = Self.firstBearing(route.steps[i].points) else { return 0 }
        var d = after - before
        while d > 180 { d -= 360 }
        while d <= -180 { d += 360 }
        return d
    }
    private static func firstBearing(_ p: [CLLocationCoordinate2D]) -> Double? {
        guard let a = p.first, let b = p.dropFirst().first(where: { NavigationGeo.distance(a, $0) > 3 }) else { return nil }
        return NavigationGeo.bearing(a, b)
    }
    private static func lastBearing(_ p: [CLLocationCoordinate2D]) -> Double? {
        guard let b = p.last, let a = p.dropLast().last(where: { NavigationGeo.distance($0, b) > 3 }) else { return nil }
        return NavigationGeo.bearing(a, b)
    }

    /// GO3 turn type (HERE ManeuverAction numbering) from the turn angle, with the
    /// instruction text deciding the cases geometry can't: roundabouts, U-turns, forks.
    static func guideType(turn: Double, instructions: String) -> Int {
        let t = instructions.lowercased()
        let right = turn > 0
        if t.contains("roundabout") || t.contains("traffic circle") || t.contains("rotary") { return right ? 21 : 20 }
        if t.contains("u-turn") || t.contains("u turn") || abs(turn) >= 165 { return right ? 10 : 2 }
        if t.contains("keep left") || t.contains("fork left") { return 15 }
        if t.contains("keep right") || t.contains("fork right") { return 17 }
        if t.contains("exit") && !t.contains("roundabout") { return right ? 12 : 11 }
        switch abs(turn) {
        case ..<20: return 6
        case ..<50: return right ? 7 : 5
        case ..<135: return right ? 8 : 4
        default: return right ? 9 : 3
        }
    }
    /// The road a maneuver leads onto, from MapKit's instruction text; else the text itself.
    static func roadName(_ instructions: String) -> String {
        let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        for marker in [" onto ", " on ", " toward ", " towards "] {
            if let r = trimmed.range(of: marker, options: .caseInsensitive) {
                let name = trimmed[r.upperBound...].trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { return name }
            }
        }
        return trimmed
    }
    static func reachTime(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}

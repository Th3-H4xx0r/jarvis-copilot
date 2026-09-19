import Foundation

/// One mile or kilometre of a route (the last one may be shorter).
struct RouteSplit: Equatable, Identifiable {
    var number: Int
    var meters: Double
    /// Moving seconds spent on it.
    var seconds: Double
    var gain: Double
    var loss: Double
    var hr: Int?
    var partial: Bool

    var id: Int { number }
    /// Seconds per metre.
    var pace: Double? { meters > 0 && seconds > 0 ? seconds / meters : nil }
}

/// A point of the route with how far along it is, for charts and the scrub.
struct RouteSample: Equatable {
    var distance: Double
    var t: Double
    var lat: Double
    var lon: Double
    var ele: Double?
    /// Smoothed over ±15 s, m/s.
    var speed: Double?
    var hr: Int?
}

/// Everything the route detail shows, worked out from the route.
struct RouteStats: Equatable {
    var distance: Double = 0
    /// First fix to last, pauses included.
    var elapsed: Double = 0
    /// Every segment's span, pauses excluded.
    var active: Double = 0
    /// Time actually moving (≥ 0.5 m/s).
    var moving: Double = 0
    var gain: Double?
    var loss: Double?
    var minEle: Double?
    var maxEle: Double?
    /// m/s over the fastest ten seconds.
    var maxSpeed: Double?
    var splits: [RouteSplit] = []
    /// The fastest full split's index in `splits`.
    var best: Int?
    var samples: [RouteSample] = []

    /// Seconds per metre while moving.
    var movingPace: Double? { distance > 0 && moving > 0 ? moving / distance : nil }
    /// m/s while moving.
    var averageSpeed: Double? { moving > 0 ? distance / moving : nil }
    var heartRateAverage: Int? {
        let hr = samples.compactMap(\.hr)
        return hr.isEmpty ? nil : hr.reduce(0, +) / hr.count
    }
    var heartRateMax: Int? { samples.compactMap(\.hr).max() }
}

/// The arithmetic of routes: distances, stats, splits, outlines.
enum RouteMath {
    static let earthRadius = 6_371_008.8
    /// Faster than this between fixes is moving; slower is standing.
    static let movingSpeed = 0.5

    /// Great-circle metres between two points.
    static func distance(_ a: RoutePoint, _ b: RoutePoint) -> Double {
        distance(a.lat, a.lon, b.lat, b.lon)
    }

    static func distance(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dp = p2 - p1, dl = (lon2 - lon1) * .pi / 180
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    /// Elevation steps smaller than this are noise, not climbing.
    static func hysteresis(_ route: WorkoutRoute) -> Double { route.elevationSource == "barometer" ? 3 : 5 }

    // MARK: Stats

    static func stats(_ route: WorkoutRoute, unit: DistanceUnit) -> RouteStats {
        var stats = RouteStats()
        let all = route.points
        guard let first = all.first, let last = all.last else { return stats }
        stats.elapsed = max(0, last.t - first.t)

        // Elevation: a climb counts once it clears the threshold from the
        // last turning point, and is credited to the split it happened in.
        let threshold = hysteresis(route)
        var reference: Double?
        var gain = 0.0, loss = 0.0
        let elevations = all.compactMap(\.ele)
        if elevations.count >= 2 {
            stats.minEle = elevations.min()
            stats.maxEle = elevations.max()
        }

        var split = RouteSplit(number: 1, meters: 0, seconds: 0, gain: 0, loss: 0, hr: nil, partial: false)
        var splitHR: [Int] = []
        var covered = 0.0
        func closeSplit(partial: Bool) {
            split.partial = partial
            split.hr = splitHR.isEmpty ? nil : splitHR.reduce(0, +) / splitHR.count
            stats.splits.append(split)
            split = RouteSplit(number: split.number + 1, meters: 0, seconds: 0, gain: 0, loss: 0, hr: nil, partial: false)
            splitHR = []
        }
        func climb(_ ele: Double?) {
            guard let ele else { return }
            guard let ref = reference else { reference = ele; return }
            if ele >= ref + threshold {
                gain += ele - ref; split.gain += ele - ref; reference = ele
            } else if ele <= ref - threshold {
                loss += ref - ele; split.loss += ref - ele; reference = ele
            }
        }

        for segment in route.segments {
            guard let head = segment.first else { continue }
            stats.active += max(0, (segment.last?.t ?? head.t) - head.t)
            stats.samples.append(RouteSample(distance: covered, t: head.t, lat: head.lat, lon: head.lon, ele: head.ele,
                                             speed: nil, hr: head.hr))
            climb(head.ele)
            if let hr = head.hr { splitHR.append(hr) }
            for (a, b) in zip(segment, segment.dropFirst()) {
                let step = distance(a, b)
                let dt = max(0, b.t - a.t)
                let moving = dt > 0 && step / dt >= movingSpeed ? dt : 0
                stats.distance += step
                stats.moving += moving
                var remaining = step, remainingTime = moving
                while split.meters + remaining >= unit.meters, remaining > 0 {
                    let part = unit.meters - split.meters
                    let share = part / remaining
                    split.meters += part
                    split.seconds += remainingTime * share
                    remainingTime -= remainingTime * share
                    remaining -= part
                    closeSplit(partial: false)
                }
                split.meters += remaining
                split.seconds += remainingTime
                covered += step
                climb(b.ele)
                if let hr = b.hr { splitHR.append(hr) }
                stats.samples.append(RouteSample(distance: covered, t: b.t, lat: b.lat, lon: b.lon, ele: b.ele,
                                                 speed: nil, hr: b.hr))
            }
        }
        if split.meters >= 10 {
            closeSplit(partial: true)
        } else if !stats.splits.isEmpty {
            // A few metres past the last split: its climbing still counts.
            stats.splits[stats.splits.count - 1].gain += split.gain
            stats.splits[stats.splits.count - 1].loss += split.loss
        }
        if elevations.count >= 2 { stats.gain = gain; stats.loss = loss }

        let full = stats.splits.enumerated().filter { !$0.element.partial && $0.element.seconds > 0 }
        stats.best = full.min { $0.element.seconds < $1.element.seconds }?.offset
        smoothSpeeds(&stats.samples, route: route)
        stats.maxSpeed = maxSpeed(route)
        return stats
    }

    /// Each sample's speed over the ±15 s around it, within its segment.
    private static func smoothSpeeds(_ samples: inout [RouteSample], route: WorkoutRoute) {
        var offset = 0
        for segment in route.segments {
            let range = offset..<(offset + segment.count)
            offset += segment.count
            guard range.count >= 2 else { continue }
            var lo = range.lowerBound, hi = range.lowerBound
            for i in range {
                while samples[lo].t < samples[i].t - 15 { lo += 1 }
                while hi + 1 < range.upperBound, samples[hi + 1].t <= samples[i].t + 15 { hi += 1 }
                let dt = samples[hi].t - samples[lo].t
                if dt >= 5 { samples[i].speed = (samples[hi].distance - samples[lo].distance) / dt }
            }
        }
    }

    /// The fastest ten seconds of any segment (gaps over 30 s don't count).
    /// Measured start to end of each window, not along the path, with each
    /// end averaged with its neighbours: a single wild fix goes out and comes
    /// back, and barely moves either end.
    static func maxSpeed(_ route: WorkoutRoute) -> Double? {
        var best: Double?
        for raw in route.segments where raw.count >= 2 {
            let segment = raw.indices.map { i -> RoutePoint in
                let around = raw[max(0, i - 1)...min(raw.count - 1, i + 1)]
                var p = raw[i]
                p.lat = around.map(\.lat).reduce(0, +) / Double(around.count)
                p.lon = around.map(\.lon).reduce(0, +) / Double(around.count)
                return p
            }
            var j = 0
            for i in segment.indices {
                if j < i { j = i }
                while j < segment.count - 1, segment[j].t - segment[i].t < 10 { j += 1 }
                let dt = segment[j].t - segment[i].t
                guard dt >= 10, dt <= 30 else { continue }
                let speed = distance(segment[i], segment[j]) / dt
                if speed < 40 { best = max(best ?? 0, speed) }
            }
        }
        return best
    }

    // MARK: Outlines

    /// Douglas–Peucker in metres: the points that keep the shape within `tolerance`.
    static func simplify(_ points: [RoutePoint], tolerance: Double) -> [RoutePoint] {
        guard points.count > 2 else { return points }
        let lat0 = points[0].lat * .pi / 180
        let xy = points.map { ($0.lon * cos(lat0) * 111_320, $0.lat * 110_540) }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack = [(0, points.count - 1)]
        while let (from, to) = stack.popLast() {
            guard to > from + 1 else { continue }
            let (ax, ay) = xy[from], (bx, by) = xy[to]
            let dx = bx - ax, dy = by - ay
            let length = max(1e-9, dx * dx + dy * dy)
            var worst = 0.0, index = from
            for i in (from + 1)..<to {
                let (px, py) = xy[i]
                let u = max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / length))
                let ex = ax + u * dx - px, ey = ay + u * dy - py
                let d = sqrt(ex * ex + ey * ey)
                if d > worst { worst = d; index = i }
            }
            if worst > tolerance {
                keep[index] = true
                stack.append((from, index))
                stack.append((index, to))
            }
        }
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }

    /// Google's encoded polyline (five decimals).
    static func encode(_ coordinates: [(lat: Double, lon: Double)]) -> String {
        var out = ""
        var lastLat = 0, lastLon = 0
        func add(_ value: Int) {
            var v = value < 0 ? ~(value << 1) : value << 1
            while v >= 0x20 {
                out.unicodeScalars.append(UnicodeScalar(UInt8((0x20 | (v & 0x1f)) + 63)))
                v >>= 5
            }
            out.unicodeScalars.append(UnicodeScalar(UInt8(v + 63)))
        }
        for c in coordinates {
            let lat = Int((c.lat * 1e5).rounded()), lon = Int((c.lon * 1e5).rounded())
            add(lat - lastLat)
            add(lon - lastLon)
            lastLat = lat
            lastLon = lon
        }
        return out
    }

    static func decode(_ text: String) -> [(lat: Double, lon: Double)] {
        let bytes = Array(text.utf8)
        var out: [(lat: Double, lon: Double)] = []
        var index = 0, lat = 0, lon = 0
        func next() -> Int? {
            var result = 0, shift = 0
            while index < bytes.count {
                let b = Int(bytes[index]) - 63
                index += 1
                result |= (b & 0x1f) << shift
                shift += 5
                if b < 0x20 { return (result & 1) != 0 ? ~(result >> 1) : result >> 1 }
            }
            return nil
        }
        while index < bytes.count {
            guard let dLat = next(), let dLon = next() else { break }
            lat += dLat
            lon += dLon
            out.append((Double(lat) / 1e5, Double(lon) / 1e5))
        }
        return out
    }

    /// Fewer points for the server: at least `minSpacing` apart, at most `maxPoints`.
    static func thin(_ route: WorkoutRoute, minSpacing: Double = 2, maxPoints: Int = 20_000) -> WorkoutRoute {
        var spacing = minSpacing
        var out = route
        for _ in 0..<40 {
            out.segments = route.segments.map { segment in
                guard segment.count > 2, let first = segment.first, let last = segment.last else { return segment }
                var kept = [first]
                for point in segment.dropFirst().dropLast() where distance(kept.last!, point) >= spacing {
                    kept.append(point)
                }
                kept.append(last)
                return kept
            }
            if out.points.count <= maxPoints { return out }
            spacing *= 1.5
        }
        return out
    }

    /// The summary a workout carries: totals and a small outline.
    static func summary(_ route: WorkoutRoute) -> RouteSummary {
        let stats = stats(route, unit: .km)
        let points = route.points
        var tolerance = 4.0
        var outline = simplify(points, tolerance: tolerance)
        while outline.count > 120 {
            tolerance *= 1.6
            outline = simplify(points, tolerance: tolerance)
        }
        let lats = points.map(\.lat), lons = points.map(\.lon)
        return RouteSummary(distanceMeters: stats.distance, movingSeconds: Int(stats.moving.rounded()),
                            gainMeters: stats.gain, lossMeters: stats.loss, minMeters: stats.minEle,
                            maxMeters: stats.maxEle, maxSpeed: stats.maxSpeed,
                            preview: encode(outline.map { ($0.lat, $0.lon) }),
                            bounds: points.isEmpty ? [] : [lats.min()!, lons.min()!, lats.max()!, lons.max()!])
    }
}

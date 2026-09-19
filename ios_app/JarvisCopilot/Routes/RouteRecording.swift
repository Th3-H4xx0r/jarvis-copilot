import Foundation

/// A GPS fix as CoreLocation hands it over, before it is judged.
struct RouteFix: Equatable {
    var time: Date
    var lat: Double
    var lon: Double
    var horizontalAccuracy: Double
    var altitude: Double?
    var verticalAccuracy: Double?
    var speed: Double?
}

/// What the live screen shows of the route so far.
struct RouteProgress: Equatable {
    var distance: Double = 0
    /// Seconds per km over the last few hundred metres.
    var pace: Double?
    var gain: Double = 0
    var elevation: Double?
    var kilocalories: Double = 0
    /// Bumps whenever the route gains a point (the map redraws on it).
    var revision = 0
}

/// A route being recorded: which fixes count, the segments between pauses,
/// distance, pace, climbing and (without a wearable) calories. Pure, so it
/// is tested fix by fix; CoreLocation lives in `WorkoutLocation`.
struct RouteRecording: Codable, Equatable {
    enum Kind: String, Codable { case walk, run, cycle }

    private(set) var start: Date
    private(set) var kind: Kind
    var weightKg: Double
    private(set) var segments: [[RoutePoint]] = [[]]
    private(set) var distance: Double = 0
    private(set) var paused = false
    private(set) var gain: Double = 0
    private(set) var kilocalories: Double = 0
    private(set) var usedBarometer = false
    private(set) var usedGPSAltitude = false
    /// The last climbing turning point (for the hysteresis).
    private var reference: Double?
    /// (seconds since start, distance) marks for the rolling pace.
    private var marks: [[Double]] = []
    private var last: RoutePoint?

    static let maxAccuracy = 20.0
    static let maxSpeed = 40.0

    init(start: Date, sport: Int, weightKg: Double) {
        self.start = start
        self.kind = [9].contains(sport) ? .cycle : [7, 42].contains(sport) ? .run : .walk
        self.weightKg = weightKg
    }

    var route: WorkoutRoute {
        WorkoutRoute(start: start, segments: segments.filter { !$0.isEmpty },
                     elevationSource: usedBarometer ? "barometer" : usedGPSAltitude ? "gps" : "none")
    }

    var progress: RouteProgress {
        RouteProgress(distance: distance, pace: pace, gain: gain, elevation: last?.ele, kilocalories: kilocalories,
                      revision: segments.reduce(0) { $0 + $1.count })
    }

    /// Seconds per km over the last ~400 m (at least 100 m of it).
    var pace: Double? {
        guard !paused, let end = marks.last, let first = marks.first(where: { end[1] - $0[1] <= 400 }),
              end[1] - first[1] >= 100 else { return nil }
        return (end[0] - first[0]) / ((end[1] - first[1]) / 1000)
    }

    /// Takes a fix if it is good enough; true when it joined the route.
    /// `pressureAltitude` is the barometer's absolute altitude, when fresh.
    /// A fix from before the start is the cached one CoreLocation opens
    /// with; later ones may arrive in a batch and still count.
    @discardableResult
    mutating func take(_ fix: RouteFix, heartRate: Int?, pressureAltitude: Double?, now: Date = Date()) -> Bool {
        guard !paused, fix.horizontalAccuracy > 0, fix.horizontalAccuracy <= Self.maxAccuracy,
              fix.time >= start else { return false }
        let ele: Double?
        if let pressureAltitude {
            ele = pressureAltitude
            usedBarometer = true
        } else if let altitude = fix.altitude, let v = fix.verticalAccuracy, v > 0, v <= 15 {
            ele = altitude
            usedGPSAltitude = true
        } else {
            ele = nil
        }
        let point = RoutePoint(t: fix.time.timeIntervalSince(start), lat: fix.lat, lon: fix.lon, ele: ele, hr: heartRate,
                               speed: fix.speed.flatMap { $0 >= 0 ? $0 : nil })
        if let previous = segments[segments.count - 1].last {
            let step = RouteMath.distance(previous, point)
            let dt = point.t - previous.t
            guard dt > 0, step / dt < Self.maxSpeed else { return false }
            // Standing still, fixes wander by a few metres. A step inside the
            // fix's own noise is not a move; nor is a small one while GPS's
            // Doppler speed says standing. Only a real move adds a point —
            // a stop shows later as a slow step, which is not moving time.
            let noise = max(3, fix.horizontalAccuracy)
            let standing = (point.speed ?? 1) < 0.4 && step < noise * 2
            guard step >= noise, !standing else { return false }
            distance += step
            burn(step: step, seconds: dt, from: previous.ele, to: ele)
        }
        climb(ele)
        segments[segments.count - 1].append(point)
        last = point
        marks.append([point.t, distance])
        if marks.count > 400 { marks.removeFirst(marks.count - 400) }
        return true
    }

    /// Stops the route: fixes are ignored until `resume`.
    mutating func pause() {
        paused = true
        marks = []
    }

    /// A new segment, so the line doesn't jump across where the pause went.
    mutating func resume() {
        guard paused else { return }
        paused = false
        if !(segments.last?.isEmpty ?? true) { segments.append([]) }
    }

    private mutating func climb(_ ele: Double?) {
        guard let ele else { return }
        let threshold = usedBarometer ? 3.0 : 5.0
        guard let ref = reference else { reference = ele; return }
        if ele >= ref + threshold {
            gain += ele - ref
            reference = ele
        } else if ele <= ref - threshold {
            reference = ele
        }
    }

    private mutating func burn(step: Double, seconds: Double, from: Double?, to: Double?) {
        guard seconds > 0, seconds < 120 else { return }
        var grade = 0.0
        if let from, let to, step > 5 { grade = max(-0.15, min(0.3, (to - from) / step)) }
        kilocalories += OutdoorCalories.kcal(kind: kind, metersPerSecond: step / seconds, grade: grade,
                                             seconds: seconds, weightKg: weightKg)
    }
}

/// Calories without a heart rate: ACSM's walking and running equations (with
/// the slope), and cycling by speed.
enum OutdoorCalories {
    /// ml O₂ per kg per minute.
    static func vo2(metersPerMinute v: Double, grade: Double, running: Bool) -> Double {
        let climb = max(0, grade)
        return running ? 0.2 * v + 0.9 * v * climb + 3.5 : 0.1 * v + 1.8 * v * climb + 3.5
    }

    static func kcal(kind: RouteRecording.Kind, metersPerSecond: Double, grade: Double, seconds: Double,
                     weightKg: Double) -> Double {
        let minutes = seconds / 60
        switch kind {
        case .cycle:
            let kmh = metersPerSecond * 3.6
            let met: Double = kmh < 16 ? 4 : kmh < 19 ? 6.8 : kmh < 22 ? 8 : kmh < 25 ? 10 : 12
            return met * 3.5 * weightKg / 200 * minutes
        case .walk, .run:
            let v = metersPerSecond * 60
            // Past ~8 km/h people run, whatever the workout is called.
            let running = kind == .run ? v > 100 : v > 134
            return vo2(metersPerMinute: v, grade: grade, running: running) * weightKg / 1000 * 5 * minutes
        }
    }
}

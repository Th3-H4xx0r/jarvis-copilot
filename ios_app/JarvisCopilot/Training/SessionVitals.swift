import Foundation

/// A heart-rate reading during a workout.
struct HeartSample: Codable, Equatable {
    var at: Date
    var bpm: Int
}

/// Who is lifting, for calories and effort: the ring's profile plus the
/// resting heart rate Jarvis Health measured.
struct VitalsProfile: Equatable {
    var age: Int
    var female: Bool
    var weightKg: Double?
    var heightCm: Double?
    var restingHR: Double

    static let fallback = VitalsProfile(age: 30, female: false, weightKg: nil, heightCm: nil, restingHR: 60)

    init(age: Int, female: Bool, weightKg: Double?, heightCm: Double?, restingHR: Double) {
        self.age = age
        self.female = female
        self.weightKg = weightKg
        self.heightCm = heightCm
        self.restingHR = restingHR
    }

    /// From the ring's settings (zeros mean "not set").
    init(ring: RingProfile?, restingHR: Double?) {
        age = (ring?.age ?? 0) > 0 ? ring!.age : 30
        female = ring?.sex == 1
        weightKg = (ring?.weightKg ?? 0) > 0 ? Double(ring!.weightKg) : nil
        heightCm = (ring?.heightCm ?? 0) > 0 ? Double(ring!.heightCm) : nil
        self.restingHR = restingHR ?? 60
    }
}

/// The resting heart rate `/now` last reported, kept for workouts started
/// with no signal.
enum HealthRestingHR {
    private static let key = "jc.health.restingHR"

    static var last: Double? {
        get { UserDefaults.standard.object(forKey: key) as? Double }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// Heart rate across a strength workout, cut into its sets and rests, and
/// what it says about the whole: calories and effort.
enum SessionVitals {
    struct Window: Equatable {
        var set: DateInterval
        var rest: DateInterval?
    }

    /// Each done set's window — from the end of the rest before it (or the
    /// set before it, or the start) to its tick — and the rest after it.
    static func windows(_ log: StrengthLog, end: Date) -> [UUID: Window] {
        let done = log.exercises.flatMap(\.sets).filter(\.isDone).sorted { $0.done! < $1.done! }
        var out: [UUID: Window] = [:]
        var boundary = log.started
        for set in done {
            let tick = set.done!
            let start = min(set.start ?? boundary, tick)
            var rest: DateInterval?
            if let restEnd = set.restEnd, restEnd > tick { rest = DateInterval(start: tick, end: min(restEnd, max(end, tick))) }
            out[set.id] = Window(set: DateInterval(start: start, end: tick), rest: rest)
            boundary = max(tick, set.restEnd ?? tick)
        }
        return out
    }

    private static func samples(_ all: [HeartSample], in interval: DateInterval) -> [HeartSample] {
        all.filter { $0.at >= interval.start && $0.at <= interval.end }
    }

    /// The log as it is saved: each done set's start, heart rate and
    /// estimated max; the totals; time in sets and between them.
    static func annotate(_ log: StrengthLog, samples all: [HeartSample], end: Date) -> StrengthLog {
        var out = log
        let windows = windows(log, end: end)
        var active = 0.0
        for e in out.exercises.indices {
            let kind = out.exercises[e].kind
            for s in out.exercises[e].sets.indices {
                var set = out.exercises[e].sets[s]
                guard let window = windows[set.id], let tick = set.done else { continue }
                set.start = window.set.start
                active += window.set.duration
                let inside = samples(all, in: window.set)
                if !inside.isEmpty {
                    set.hrAvg = Int((Double(inside.map(\.bpm).reduce(0, +)) / Double(inside.count)).rounded())
                    set.hrMax = inside.map(\.bpm).max()
                }
                let atTick = samples(all, in: DateInterval(start: tick.addingTimeInterval(-10), end: tick)).map(\.bpm).max()
                if let rest = window.rest, let peak = atTick, let low = samples(all, in: rest).map(\.bpm).min(), peak > low {
                    set.hrDrop = peak - low
                }
                if kind == .weightReps, set.tag != .warmup, let kg = set.kg, let reps = set.reps {
                    set.e1rm = TrainingMath.e1RM(kg: kg, reps: reps).map { ($0 * 10).rounded() / 10 }
                }
                out.exercises[e].sets[s] = set
            }
        }
        let totals = TrainingMath.totals(out)
        out.volumeKg = totals.volumeKg
        out.sets = totals.sets
        out.reps = totals.reps
        out.activeSeconds = Int(active.rounded())
        out.restSeconds = max(0, Int(end.timeIntervalSince(log.started).rounded()) - out.activeSeconds)
        return out
    }

    /// Seconds each reading stands for: up to the next one, at most 5.
    private static func spans(_ samples: [HeartSample]) -> [(HeartSample, Double)] {
        samples.enumerated().map { i, sample in
            let next = i + 1 < samples.count ? samples[i + 1].at.timeIntervalSince(sample.at) : 1
            return (sample, min(max(next, 0), 5))
        }
    }

    /// Active calories and where they came from. Heart rate (Keytel, less
    /// resting burn) when the ring covered most of the workout and weight is
    /// known; else the ring's own count; else a MET estimate.
    static func activeCalories(samples: [HeartSample], start: Date, end: Date, profile: VitalsProfile,
                               ringKcal: Double?) -> (kcal: Double, source: String) {
        let duration = max(1, end.timeIntervalSince(start))
        let spans = spans(samples.sorted { $0.at < $1.at })
        let covered = spans.reduce(0) { $0 + $1.1 }
        if let weight = profile.weightKg, covered / duration >= 0.6 {
            let a = Double(profile.age)
            let bmrPerDay = profile.heightCm.map { 10 * weight + 6.25 * $0 - 5 * a + (profile.female ? -161 : 5) } ?? 24 * weight
            let restingPerSecond = bmrPerDay / 86_400
            var kcal = 0.0
            for (sample, seconds) in spans {
                let hr = Double(sample.bpm)
                let perMinute = profile.female
                    ? (-20.4022 + 0.4472 * hr - 0.1263 * weight + 0.074 * a) / 4.184
                    : (-55.0969 + 0.6309 * hr + 0.1988 * weight + 0.2017 * a) / 4.184
                kcal += max(0, perMinute / 60 - restingPerSecond) * seconds
            }
            return (kcal * duration / covered, "heart_rate")
        }
        if let ringKcal, ringKcal > 0 { return (ringKcal, "ring") }
        return (4.0 * (profile.weightKg ?? 70) * duration / 3600, "estimate")
    }

    /// Banister's training impulse: minutes weighted by how far into the
    /// heart-rate reserve they were.
    static func trimp(samples: [HeartSample], profile: VitalsProfile) -> Double {
        guard !samples.isEmpty else { return 0 }
        let maxHR = max(Double(220 - profile.age), Double(samples.map(\.bpm).max() ?? 0))
        let reserve = max(1, maxHR - profile.restingHR)
        var total = 0.0
        for (sample, seconds) in spans(samples.sorted { $0.at < $1.at }) {
            let x = min(1, max(0, (Double(sample.bpm) - profile.restingHR) / reserve))
            let weight = profile.female ? 0.86 * exp(1.67 * x) : 0.64 * exp(1.92 * x)
            total += seconds / 60 * x * weight
        }
        return total
    }

    /// 1–10, the way Apple's workout effort reads: 1–3 easy, 4–6 moderate,
    /// 7–8 hard, 9–10 all out.
    static func effort(trimp: Double) -> Int {
        let bands: [Double] = [10, 20, 35, 50, 70, 95, 125, 160, 200]
        return (bands.firstIndex { trimp < $0 } ?? bands.count) + 1
    }

    /// Mean heart rate per 5 s from the start, 0 where there was none — the
    /// series Body Battery and the charts already read.
    static func series5s(samples: [HeartSample], start: Date, end: Date) -> [Int] {
        let count = max(0, Int((end.timeIntervalSince(start) / 5).rounded(.up)))
        var sums = [Int](repeating: 0, count: count), counts = [Int](repeating: 0, count: count)
        for sample in samples {
            let slot = Int(sample.at.timeIntervalSince(start) / 5)
            guard slot >= 0, slot < count else { continue }
            sums[slot] += sample.bpm
            counts[slot] += 1
        }
        return zip(sums, counts).map { $1 == 0 ? 0 : Int((Double($0) / Double($1)).rounded()) }
    }

    /// Seconds in heart-rate zones 1–5.
    static func zoneSeconds(samples: [HeartSample], age: Int) -> [Int] {
        var out = [0.0, 0, 0, 0, 0]
        for (sample, seconds) in spans(samples.sorted { $0.at < $1.at }) {
            out[RingWorkoutController.zone(sample.bpm, age: age) - 1] += seconds
        }
        return out.map { Int($0.rounded()) }
    }
}

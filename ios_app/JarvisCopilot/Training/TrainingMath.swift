import Foundation

/// The arithmetic of lifting: estimated maxes, records, plates, warm-ups,
/// what was done last time, and whether a template changed. Pure — every
/// screen and the summary read the same numbers from here.
enum TrainingMath {
    // MARK: One-rep max

    /// Brzycki's estimate. Past 12 reps it stops meaning anything, so nil.
    static func e1RM(kg: Double, reps: Int) -> Double? {
        guard kg > 0, (1...12).contains(reps) else { return nil }
        return reps == 1 ? kg : kg * 36 / Double(37 - reps)
    }

    /// What that estimated max says is liftable for `reps`.
    static func predicted(from e1RM: Double, reps: Int) -> Double {
        e1RM * Double(37 - reps) / 36
    }

    // MARK: Totals

    /// Done and not a warm-up: the sets that count.
    static func counts(_ set: LoggedSet) -> Bool { set.isDone && set.tag != .warmup }

    /// Weight × reps for the kinds that lift a weight. Weighted bodyweight
    /// counts the added weight; assisted counts nothing.
    static func volume(_ set: LoggedSet, kind: ExerciseKind) -> Double {
        guard counts(set), kind == .weightReps || kind == .weightedBodyweight else { return 0 }
        return (set.kg ?? 0) * Double(set.reps ?? 0)
    }

    static func totals(_ log: StrengthLog) -> (volumeKg: Double, sets: Int, reps: Int) {
        var volume = 0.0, sets = 0, reps = 0
        for exercise in log.exercises {
            for set in exercise.sets where counts(set) {
                volume += self.volume(set, kind: exercise.kind)
                sets += 1
                reps += set.reps ?? 0
            }
        }
        return (volume, sets, reps)
    }

    // MARK: Last time

    /// The set at the same position last time — counting warm-ups and
    /// working sets separately — from the newest log that did this exercise.
    /// `history` is newest first.
    static func previous(exerciseID: String, index: Int, warmup: Bool, in history: [StrengthLog]) -> LoggedSet? {
        for log in history {
            guard let exercise = log.exercises.first(where: { $0.exerciseID == exerciseID && $0.sets.contains(where: \.isDone) })
            else { continue }
            let same = exercise.sets.filter { $0.isDone && ($0.tag == .warmup) == warmup }
            return same.indices.contains(index) ? same[index] : nil
        }
        return nil
    }

    // MARK: Plates and warm-ups

    /// The nearest weight plates make, in the person's unit.
    static func roundToPlates(_ kg: Double, unit: TrainingUnit) -> Double {
        let shown = unit.show(kg)
        return unit.kilograms((shown / unit.step).rounded() * unit.step)
    }

    static func plateSizes(_ unit: TrainingUnit) -> [Double] {
        unit == .kg ? [25, 20, 15, 10, 5, 2.5, 1.25] : [45, 35, 25, 10, 5, 2.5]
    }

    /// The plates for one side, heaviest first, in the unit; and what is left
    /// over per side that no plate makes.
    static func plates(total kg: Double, bar barKg: Double, unit: TrainingUnit) -> (perSide: [Double], remainder: Double) {
        var left = (unit.show(kg) - unit.show(barKg)) / 2
        guard left > 1e-6 else { return ([], 0) }
        var out: [Double] = []
        for plate in plateSizes(unit) {
            while left + 1e-6 >= plate {
                out.append(plate)
                left -= plate
            }
        }
        return (out, left < 1e-6 ? 0 : left)
    }

    /// The empty bar for 10, then 40 %, 60 % and 80 % of the working weight
    /// for 5, 3 and 2 — rounded to plates, and none that is not heavier than
    /// the bar or the one before.
    static func warmups(working kg: Double, bar: Double?, unit: TrainingUnit) -> [LoggedSet] {
        let bar = bar ?? 0
        var out: [LoggedSet] = []
        if bar > 0, bar < kg { out.append(LoggedSet(tag: .warmup, kg: bar, reps: 10)) }
        for (share, reps) in [(0.4, 5), (0.6, 3), (0.8, 2)] {
            let weight = roundToPlates(kg * share, unit: unit)
            guard weight > bar + 1e-6, weight < kg - 1e-6, weight > (out.last?.kg ?? 0) + 1e-6 else { continue }
            out.append(LoggedSet(tag: .warmup, kg: weight, reps: reps))
        }
        return out
    }

    // MARK: Records

    struct RepRecord: Equatable {
        var actual: Double?
        var predicted: Double?
    }

    struct Records: Equatable {
        var e1RM: Double?
        var maxWeight: Double?
        var maxSetVolume: Double?
        var maxSessionVolume: Double?
        var maxReps: Int?
        var maxSeconds: Int?
        /// 1–12 reps: the heaviest actually lifted, and what the best
        /// estimated max predicts.
        var byReps: [Int: RepRecord] = [:]
    }

    static func records(exerciseID: String, in logs: [StrengthLog]) -> Records {
        var r = Records()
        var repBest: [Int: Double] = [:]
        for log in logs {
            for exercise in log.exercises where exercise.exerciseID == exerciseID {
                var session = 0.0
                for set in exercise.sets where counts(set) {
                    let volume = self.volume(set, kind: exercise.kind)
                    session += volume
                    if volume > 0 { r.maxSetVolume = max(r.maxSetVolume ?? 0, volume) }
                    if let reps = set.reps, reps > 0 { r.maxReps = max(r.maxReps ?? 0, reps) }
                    if let seconds = set.seconds, seconds > 0 { r.maxSeconds = max(r.maxSeconds ?? 0, seconds) }
                    guard exercise.kind == .weightReps || exercise.kind == .weightedBodyweight,
                          let kg = set.kg, kg > 0 else { continue }
                    r.maxWeight = max(r.maxWeight ?? 0, kg)
                    guard exercise.kind == .weightReps, let reps = set.reps else { continue }
                    if let e = e1RM(kg: kg, reps: reps) { r.e1RM = max(r.e1RM ?? 0, e) }
                    if (1...12).contains(reps) { repBest[reps] = max(repBest[reps] ?? 0, kg) }
                }
                if session > 0 { r.maxSessionVolume = max(r.maxSessionVolume ?? 0, session) }
            }
        }
        if r.e1RM != nil || !repBest.isEmpty {
            for reps in 1...12 {
                r.byReps[reps] = RepRecord(actual: repBest[reps], predicted: r.e1RM.map { predicted(from: $0, reps: reps) })
            }
        }
        return r
    }

    /// Set id → the all-time bests it sets over `history`. An exercise done
    /// for the first time sets none: a record needs something to beat.
    static func newRecords(in log: StrengthLog, history: [StrengthLog]) -> [UUID: [String]] {
        var out: [UUID: [String]] = [:]
        for exercise in log.exercises {
            let before = records(exerciseID: exercise.exerciseID, in: history)
            guard before != Records() else { continue }
            let sets = exercise.sets.filter(counts)
            func mark(_ name: String, _ value: (LoggedSet) -> Double?, best: Double?) {
                guard let top = sets.max(by: { (value($0) ?? 0) < (value($1) ?? 0) }), let v = value(top), v > 0,
                      v > (best ?? 0) + 1e-9 else { return }
                out[top.id, default: []].append(name)
            }
            if exercise.kind == .weightReps {
                mark("e1rm", { set in set.kg.flatMap { kg in set.reps.flatMap { e1RM(kg: kg, reps: $0) } } }, best: before.e1RM)
            }
            if exercise.kind == .weightReps || exercise.kind == .weightedBodyweight {
                mark("weight", { $0.kg }, best: before.maxWeight)
                mark("volume", { volume($0, kind: exercise.kind) }, best: before.maxSetVolume)
            }
            if exercise.kind == .repsOnly { mark("reps", { $0.reps.map(Double.init) }, best: before.maxReps.map(Double.init)) }
            if exercise.kind.usesSeconds { mark("seconds", { $0.seconds.map(Double.init) }, best: before.maxSeconds.map(Double.init)) }
        }
        return out
    }

    // MARK: Templates

    enum TemplateChange: Equatable { case none, valuesOnly, structure }

    private static func shape(_ exercises: [LoggedExercise]) -> [String] {
        exercises.map { e in "\(e.exerciseID)|\(e.superset.map(String.init) ?? "-")|" + e.sets.map(\.tag.rawValue).joined(separator: ",") }
    }

    /// What finishing `log` would change in the template it came from:
    /// nothing, only the numbers, or the exercises and sets themselves.
    static func change(from template: WorkoutTemplate, to log: StrengthLog) -> TemplateChange {
        // Exercises are grouped by position, so renumbered supersets still match.
        func normalised(_ list: [LoggedExercise]) -> [LoggedExercise] {
            var map: [Int: Int] = [:]
            return list.map { e in
                var e = e
                if let group = e.superset {
                    if map[group] == nil { map[group] = map.count + 1 }
                    e.superset = map[group]
                }
                return e
            }
        }
        if shape(normalised(template.exercises)) != shape(normalised(log.exercises)) { return .structure }
        for (planned, done) in zip(template.exercises, log.exercises) {
            for (target, set) in zip(planned.sets, done.sets) where set.isDone {
                if target.kg != set.kg || target.reps != set.reps || target.seconds != set.seconds || target.meters != set.meters {
                    return .valuesOnly
                }
            }
        }
        return .none
    }

    private static func cleared(_ set: LoggedSet) -> LoggedSet {
        LoggedSet(tag: set.tag, kg: set.kg, reps: set.reps, seconds: set.seconds, meters: set.meters)
    }

    /// A template from what was done: every exercise, its done sets as the
    /// targets (all its sets when none was done).
    static func template(from log: StrengthLog, id: String, name: String, order: Int) -> WorkoutTemplate {
        let exercises = log.exercises.map { e -> LoggedExercise in
            let done = e.sets.filter(\.isDone)
            return LoggedExercise(exerciseID: e.exerciseID, name: e.name, kind: e.kind, note: e.note, superset: e.superset,
                                  sets: (done.isEmpty ? e.sets : done).map(cleared))
        }
        return WorkoutTemplate(id: id, name: name, note: log.note, order: order, exercises: exercises)
    }

    /// The template as it was, with what was lifted written into it.
    static func updatingValues(_ template: WorkoutTemplate, from log: StrengthLog) -> WorkoutTemplate {
        var out = template
        out.updated = Date()
        for (i, exercise) in out.exercises.enumerated() where log.exercises.indices.contains(i) {
            let done = log.exercises[i]
            guard done.exerciseID == exercise.exerciseID else { continue }
            for (j, set) in done.sets.enumerated() where set.isDone && exercise.sets.indices.contains(j) {
                out.exercises[i].sets[j].kg = set.kg
                out.exercises[i].sets[j].reps = set.reps
                out.exercises[i].sets[j].seconds = set.seconds
                out.exercises[i].sets[j].meters = set.meters
            }
        }
        return out
    }

    // MARK: Charts

    enum ChartMetric: String, CaseIterable, Identifiable {
        case e1RM, heaviest, volume, reps, seconds
        var id: String { rawValue }

        var label: String {
            switch self {
            case .e1RM: return "Estimated 1RM"
            case .heaviest: return "Heaviest weight"
            case .volume: return "Session volume"
            case .reps: return "Most reps"
            case .seconds: return "Longest set"
            }
        }

        static func available(for kind: ExerciseKind) -> [ChartMetric] {
            switch kind {
            case .weightReps: return [.e1RM, .heaviest, .volume]
            case .weightedBodyweight: return [.heaviest, .volume, .reps]
            case .repsOnly, .assistedBodyweight: return [.reps]
            case .duration, .distanceDuration: return [.seconds]
            }
        }
    }

    /// One point per workout that did the exercise, oldest first.
    static func chart(_ metric: ChartMetric, exerciseID: String, logs: [StrengthLog]) -> [(date: Date, value: Double)] {
        var out: [(Date, Double)] = []
        for log in logs {
            let entries = log.exercises.filter { $0.exerciseID == exerciseID }
            guard !entries.isEmpty else { continue }
            let sets = entries.flatMap { e in e.sets.filter(counts).map { (e.kind, $0) } }
            let value: Double?
            switch metric {
            case .e1RM: value = sets.compactMap { _, s in s.kg.flatMap { kg in s.reps.flatMap { e1RM(kg: kg, reps: $0) } } }.max()
            case .heaviest: value = sets.compactMap { $0.1.kg }.max()
            case .volume: value = sets.reduce(0) { $0 + volume($1.1, kind: $1.0) }
            case .reps: value = sets.compactMap { $0.1.reps.map(Double.init) }.max()
            case .seconds: value = sets.compactMap { $0.1.seconds.map(Double.init) }.max()
            }
            if let value, value > 0 { out.append((log.started, value)) }
        }
        return out.sorted { $0.0 < $1.0 }
    }
}

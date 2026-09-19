import Foundation

/// Which number a keypad is typing.
enum SetField: Equatable {
    case weight, reps, seconds, meters
}

/// The cell the keypad is typing into.
struct SetFocus: Equatable {
    var exercise: UUID
    var set: UUID
    var field: SetField
}

/// A rest between sets.
struct RestState: Equatable {
    var started: Date
    var ends: Date
    /// Seconds it was set for (±15 s changes it).
    var total: Int
    /// The set it follows.
    var after: UUID

    func remaining(at now: Date) -> Int { max(0, Int(ends.timeIntervalSince(now).rounded(.up))) }
}

/// A strength workout being edited: live at the gym, a template being
/// planned, or a finished workout being corrected. Every change to the
/// exercises and sets goes through here; the live one also runs the rest
/// timer.
@MainActor
final class StrengthSession: ObservableObject {
    enum Mode { case live, template, editing }

    @Published var log: StrengthLog {
        didSet {
            guard log != oldValue else { return }
            // A keypad on a set that is gone (its exercise removed, its
            // warm-ups replaced) closes rather than typing into nothing.
            if let focus, !log.exercises.contains(where: { $0.id == focus.exercise && $0.sets.contains { $0.id == focus.set } }) {
                self.focus = nil
            }
            onChange?()
        }
    }
    @Published private(set) var rest: RestState? {
        didSet { if rest != oldValue { onChange?() } }
    }
    @Published var focus: SetFocus?
    let mode: Mode
    /// Autosave and the Live Activity.
    var onChange: (() -> Void)?

    let store: TrainingStore
    let library: ExerciseLibrary
    private let alerts: RestAlerting?
    private let now: () -> Date
    private var restTimer: Task<Void, Never>?

    init(log: StrengthLog, mode: Mode, store: TrainingStore, library: ExerciseLibrary, alerts: RestAlerting? = nil,
         now: @escaping () -> Date = Date.init) {
        self.log = log
        self.mode = mode
        self.store = store
        self.library = library
        self.alerts = alerts
        self.now = now
    }

    var unit: TrainingUnit { TrainingUnit.current }

    /// A fresh workout from a template: new ids, nothing done.
    static func log(from template: WorkoutTemplate, at date: Date) -> StrengthLog {
        StrengthLog(name: template.name, templateID: template.id, note: template.note, started: date,
                    exercises: template.exercises.map { e in
                        LoggedExercise(exerciseID: e.exerciseID, name: e.name, kind: e.kind, note: e.note,
                                       superset: e.superset,
                                       sets: e.sets.map { LoggedSet(tag: $0.tag, kg: $0.kg, reps: $0.reps,
                                                                    seconds: $0.seconds, meters: $0.meters) })
                    })
    }

    /// A template opened for editing, as a log the same views can show.
    static func log(editing template: WorkoutTemplate) -> StrengthLog {
        StrengthLog(name: template.name, templateID: template.id, note: template.note, started: .distantPast,
                    exercises: template.exercises)
    }

    /// The log written back into its template.
    func template(from base: WorkoutTemplate) -> WorkoutTemplate {
        var out = base
        out.name = log.name.trimmingCharacters(in: .whitespacesAndNewlines)
        out.note = log.note
        out.exercises = log.exercises.map { e in
            var e = e
            e.sets = e.sets.map { LoggedSet(id: $0.id, tag: $0.tag, kg: $0.kg, reps: $0.reps, seconds: $0.seconds, meters: $0.meters) }
            return e
        }
        return out
    }

    // MARK: Lookups

    func exercise(for logged: LoggedExercise) -> Exercise? {
        library.exercise(logged.exerciseID, custom: store.customExercises, settings: store.settings)
    }

    private func index(of exercise: UUID) -> Int? { log.exercises.firstIndex { $0.id == exercise } }

    private func indices(of set: UUID, in exercise: UUID) -> (Int, Int)? {
        guard let e = index(of: exercise), let s = log.exercises[e].sets.firstIndex(where: { $0.id == set }) else { return nil }
        return (e, s)
    }

    /// Last time's set at this one's place (warm-ups and working sets counted apart).
    func previous(_ set: UUID, in exercise: UUID) -> LoggedSet? {
        guard let (e, s) = indices(of: set, in: exercise) else { return nil }
        let entry = log.exercises[e]
        let warmup = entry.sets[s].tag == .warmup
        let position = entry.sets[..<s].filter { ($0.tag == .warmup) == warmup }.count
        return TrainingMath.previous(exerciseID: entry.exerciseID, index: position, warmup: warmup, in: store.logs)
    }

    func restSeconds(for exercise: LoggedExercise, warmup: Bool) -> Int {
        let settings = store.settings(for: exercise.exerciseID)
        // Warm-ups rest only when the exercise asks them to.
        return warmup ? settings.warmupRestSeconds ?? 0 : settings.restSeconds ?? 120
    }

    // MARK: Exercises

    func addExercises(_ ids: [String], asSuperset: Bool) {
        let group = asSuperset && ids.count > 1 ? (log.exercises.compactMap(\.superset).max() ?? 0) + 1 : nil
        for id in ids {
            guard let exercise = library.exercise(id, custom: store.customExercises, settings: store.settings) else { continue }
            // As many sets as last time (one when it is new), up to six.
            let lastTime = store.logs.lazy.compactMap { $0.exercises.first { $0.exerciseID == id } }.first
            let count = lastTime?.sets.filter { $0.isDone && $0.tag != .warmup }.count ?? 1
            let sets = (0..<min(6, max(1, count))).map { _ in LoggedSet() }
            log.exercises.append(LoggedExercise(exerciseID: id, name: exercise.name, kind: exercise.kind,
                                                superset: group, sets: sets))
        }
    }

    func remove(_ exercise: UUID) {
        if let rest, log.exercises.first(where: { $0.id == exercise })?.sets.contains(where: { $0.id == rest.after }) == true {
            cancelRest()
        }
        log.exercises.removeAll { $0.id == exercise }
        tidySupersets()
    }

    func move(from source: IndexSet, to destination: Int) {
        log.exercises.move(fromOffsets: source, toOffset: destination)
        tidySupersets()
    }

    /// Another exercise in this one's place: its sets' numbers stay, undone.
    func replace(_ exercise: UUID, with id: String) {
        guard let e = index(of: exercise),
              let found = library.exercise(id, custom: store.customExercises, settings: store.settings) else { return }
        log.exercises[e].exerciseID = id
        log.exercises[e].name = found.name
        log.exercises[e].kind = found.kind
        log.exercises[e].sets = log.exercises[e].sets.map { var s = $0; s.done = nil; s.start = nil; s.restEnd = nil; return s }
    }

    /// Put `exercise` in a superset with `other`, right after it.
    func superset(_ exercise: UUID, with other: UUID) {
        guard exercise != other, let a = index(of: exercise), index(of: other) != nil else { return }
        let group = log.exercises.first { $0.id == other }?.superset ?? (log.exercises.compactMap(\.superset).max() ?? 0) + 1
        var moving = log.exercises.remove(at: a)
        moving.superset = group
        guard let b = index(of: other) else { return }
        log.exercises[b].superset = group
        let lastInGroup = log.exercises.lastIndex { $0.superset == group } ?? b
        log.exercises.insert(moving, at: lastInGroup + 1)
        tidySupersets()
    }

    func unlink(_ exercise: UUID) {
        guard let e = index(of: exercise) else { return }
        log.exercises[e].superset = nil
        tidySupersets()
    }

    /// A superset is two or more exercises next to each other.
    private func tidySupersets() {
        var runs: [Int: [Int]] = [:]
        for (i, e) in log.exercises.enumerated() { if let g = e.superset { runs[g, default: []].append(i) } }
        for (_, members) in runs {
            let contiguous = members.count > 1 && members.last! - members.first! == members.count - 1
            if !contiguous { for i in members { log.exercises[i].superset = nil } }
        }
    }

    func setNote(_ text: String, for exercise: UUID) {
        guard let e = index(of: exercise) else { return }
        log.exercises[e].note = text
    }

    func setPinnedNote(_ text: String?, for exerciseID: String) {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        store.updateSettings(exerciseID) { $0.pinnedNote = trimmed?.isEmpty == false ? trimmed : nil }
        objectWillChange.send()
    }

    // MARK: Sets

    func addSet(_ exercise: UUID) {
        guard let e = index(of: exercise) else { return }
        let last = log.exercises[e].sets.last
        log.exercises[e].sets.append(LoggedSet(tag: last?.tag == .warmup ? .working : (last?.tag ?? .working),
                                               kg: last?.kg, reps: last?.reps, seconds: last?.seconds, meters: last?.meters))
    }

    func removeSet(_ set: UUID, in exercise: UUID) {
        guard let (e, s) = indices(of: set, in: exercise) else { return }
        if rest?.after == set { cancelRest() }
        if focus?.set == set { focus = nil }
        log.exercises[e].sets.remove(at: s)
    }

    /// The same tag again takes it off.
    func setTag(_ tag: SetTag, set: UUID, in exercise: UUID) {
        guard let (e, s) = indices(of: set, in: exercise) else { return }
        log.exercises[e].sets[s].tag = log.exercises[e].sets[s].tag == tag ? .working : tag
    }

    /// Distance is typed in km (or miles in pounds country).
    var distanceScale: Double { unit == .kg ? 1000 : 1609.344 }

    /// A value as typed (weight in the person's unit).
    func setValue(_ value: Double?, field: SetField, set: UUID, in exercise: UUID) {
        guard let (e, s) = indices(of: set, in: exercise) else { return }
        switch field {
        case .weight: log.exercises[e].sets[s].kg = value.map { unit.kilograms($0) }
        case .reps: log.exercises[e].sets[s].reps = value.map { Int($0.rounded()) }
        case .seconds: log.exercises[e].sets[s].seconds = value.map { Int($0.rounded()) }
        case .meters: log.exercises[e].sets[s].meters = value.map { $0 * distanceScale }
        }
    }

    /// The value a cell shows, in the person's units.
    func value(_ field: SetField, of set: LoggedSet) -> Double? {
        switch field {
        case .weight: return set.kg.map { unit.show($0) }
        case .reps: return set.reps.map(Double.init)
        case .seconds: return set.seconds.map(Double.init)
        case .meters: return set.meters.map { $0 / distanceScale }
        }
    }

    func setRPE(_ rpe: Double?, set: UUID, in exercise: UUID) {
        guard let (e, s) = indices(of: set, in: exercise) else { return }
        log.exercises[e].sets[s].rpe = rpe
    }

    func copyPrevious(_ set: UUID, in exercise: UUID) {
        guard let (e, s) = indices(of: set, in: exercise), let before = previous(set, in: exercise) else { return }
        log.exercises[e].sets[s].kg = before.kg
        log.exercises[e].sets[s].reps = before.reps
        log.exercises[e].sets[s].seconds = before.seconds
        log.exercises[e].sets[s].meters = before.meters
    }

    /// Warm-ups worked out from the first working set, in place of any not yet done.
    func addWarmups(_ exercise: UUID) {
        guard let e = index(of: exercise) else { return }
        let entry = log.exercises[e]
        let firstWorking = entry.sets.first { $0.tag != .warmup }
        guard let working = firstWorking?.kg ?? firstWorking.flatMap({ previous($0.id, in: exercise)?.kg }), working > 0
        else { return }
        let bar = store.settings(for: entry.exerciseID).barKg ?? self.exercise(for: entry)?.equipment.defaultBar(unit)
        let warmups = TrainingMath.warmups(working: working, bar: bar, unit: unit)
        log.exercises[e].sets.removeAll { $0.tag == .warmup && !$0.isDone }
        log.exercises[e].sets.insert(contentsOf: warmups, at: 0)
    }

    /// Tick a set (or untick it). An empty value takes last time's, then the
    /// set above's; a set with nothing to count opens the keypad instead. A
    /// live tick starts the rest — unless a superset's round goes on, or a
    /// drop set follows.
    func toggleDone(_ set: UUID, in exercise: UUID) {
        guard mode != .template, let (e, s) = indices(of: set, in: exercise) else { return }
        if log.exercises[e].sets[s].isDone {
            log.exercises[e].sets[s].done = nil
            log.exercises[e].sets[s].start = nil
            log.exercises[e].sets[s].restEnd = nil
            if rest?.after == set { cancelRest() }
            return
        }
        let kind = log.exercises[e].kind
        var entry = log.exercises[e].sets[s]
        let fallback = previous(set, in: exercise) ?? (s > 0 ? log.exercises[e].sets[s - 1] : nil)
        if entry.kg == nil, kind.usesWeight { entry.kg = fallback?.kg }
        if entry.reps == nil, kind.usesReps { entry.reps = fallback?.reps }
        if entry.seconds == nil, kind.usesSeconds { entry.seconds = fallback?.seconds }
        if entry.meters == nil, kind.usesMeters { entry.meters = fallback?.meters }
        let missing: SetField? = kind.usesReps && entry.reps == nil ? .reps
            : kind.usesSeconds && entry.seconds == nil && entry.meters == nil ? .seconds : nil
        if let missing {
            log.exercises[e].sets[s] = entry
            focus = SetFocus(exercise: exercise, set: set, field: missing)
            return
        }
        guard mode == .live else {
            entry.done = lastBoundary() ?? log.started
            log.exercises[e].sets[s] = entry
            if focus?.set == set { focus = nil }
            return
        }
        let time = now()
        if let running = rest {
            // Ticked before the rest ran out: the set began a set's length
            // ago (about three seconds a rep), and the rest ended there —
            // never before the tick it followed.
            let length = TimeInterval(max(15, (entry.reps ?? 8) * 3))
            finishRest(at: max(running.started, time.addingTimeInterval(-length)), running)
            alerts?.cancel()
        }
        entry.start = min(lastBoundary() ?? log.started, time)
        entry.done = time
        log.exercises[e].sets[s] = entry
        if focus?.set == set { focus = nil }
        if continuesRound(exercise: e, set: s) { return }
        if log.exercises[e].sets.indices.contains(s + 1), log.exercises[e].sets[s + 1].tag == .drop { return }
        let seconds = restSeconds(for: log.exercises[e], warmup: entry.tag == .warmup)
        if seconds > 0 { startRest(seconds: seconds, after: set) }
    }

    /// When the latest done set's rest ended (or it was ticked).
    private func lastBoundary() -> Date? {
        log.exercises.flatMap(\.sets).compactMap { set in set.done.map { max($0, set.restEnd ?? $0) } }.max()
    }

    /// Another exercise in this superset still has this round's set to do.
    private func continuesRound(exercise e: Int, set s: Int) -> Bool {
        guard let group = log.exercises[e].superset else { return false }
        return log.exercises.indices.contains { i in
            i > e && log.exercises[i].superset == group && log.exercises[i].sets.indices.contains(s)
                && !log.exercises[i].sets[s].isDone
        }
    }

    /// Every set in the order it is done: exercise by exercise, a superset
    /// round by round.
    var orderedSets: [(exercise: UUID, set: UUID)] {
        var out: [(UUID, UUID)] = []
        var i = 0
        while i < log.exercises.count {
            var members = [i]
            if let group = log.exercises[i].superset {
                while members.last! + 1 < log.exercises.count, log.exercises[members.last! + 1].superset == group {
                    members.append(members.last! + 1)
                }
            }
            let rounds = members.map { log.exercises[$0].sets.count }.max() ?? 0
            for round in 0..<rounds {
                for m in members where log.exercises[m].sets.indices.contains(round) {
                    out.append((log.exercises[m].id, log.exercises[m].sets[round].id))
                }
            }
            i = members.last! + 1
        }
        return out
    }

    /// The next set to do, superset rounds in order.
    var nextUp: (exercise: LoggedExercise, set: LoggedSet, number: Int)? {
        var i = 0
        while i < log.exercises.count {
            let group = log.exercises[i].superset
            var members = [i]
            if let group {
                while members.last! + 1 < log.exercises.count, log.exercises[members.last! + 1].superset == group {
                    members.append(members.last! + 1)
                }
            }
            let rounds = members.map { log.exercises[$0].sets.count }.max() ?? 0
            for round in 0..<rounds {
                for m in members where log.exercises[m].sets.indices.contains(round) && !log.exercises[m].sets[round].isDone {
                    return (log.exercises[m], log.exercises[m].sets[round], round + 1)
                }
            }
            i = members.last! + 1
        }
        return nil
    }

    /// "Bench Press · set 3 · 60 kg × 8" — what comes next.
    var detail: String? {
        guard let next = nextUp else { return nil }
        var parts = ["\(next.exercise.name) · set \(next.number)"]
        let values = next.set.kg != nil || next.set.reps != nil ? next.set
            : (previous(next.set.id, in: next.exercise.id) ?? next.set)
        var what: [String] = []
        if next.exercise.kind.usesWeight, let kg = values.kg { what.append("\(unit.format(kg)) \(unit.symbol)") }
        if next.exercise.kind.usesReps, let reps = values.reps { what.append("\(reps)") }
        if !what.isEmpty { parts.append(what.joined(separator: " × ")) }
        return parts.joined(separator: " · ")
    }

    // MARK: Rest

    func startRest(seconds: Int, after set: UUID) {
        let start = now()
        rest = RestState(started: start, ends: start.addingTimeInterval(Double(seconds)), total: seconds, after: set)
        armRest()
    }

    /// ±15 s. Taking it to zero ends it.
    func adjustRest(by seconds: Int) {
        guard var current = rest else { return }
        current.ends = current.ends.addingTimeInterval(Double(seconds))
        current.total = max(0, current.total + seconds)
        if current.ends <= now() { return skipRest() }
        rest = current
        armRest()
    }

    func skipRest() {
        guard let rest else { return }
        finishRest(at: now(), rest)
        alerts?.cancel()
    }

    /// The timer ran out with the app open: a tap and a chime.
    func restDidEnd() {
        guard let rest else { return }
        finishRest(at: rest.ends, rest)
        alerts?.arrived()
    }

    /// Catch up after the app was away: a rest that ran out meanwhile ends,
    /// quietly — its notification already said so, and is cleared.
    func resync() {
        guard let rest, rest.ends <= now() else { return }
        finishRest(at: rest.ends, rest)
        alerts?.cancel()
    }

    func cancelRest() {
        restTimer?.cancel()
        rest = nil
        alerts?.cancel()
    }

    private func finishRest(at time: Date, _ state: RestState) {
        restTimer?.cancel()
        for e in log.exercises.indices {
            if let s = log.exercises[e].sets.firstIndex(where: { $0.id == state.after }) {
                log.exercises[e].sets[s].restEnd = min(time, state.ends)
            }
        }
        rest = nil
    }

    private func armRest() {
        guard let rest else { return }
        alerts?.schedule(at: rest.ends, title: "Rest's over", body: detail.map { "Next: \($0)" } ?? "Time for the next set.")
        restTimer?.cancel()
        let wait = rest.ends.timeIntervalSince(now())
        restTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, wait)))
            guard !Task.isCancelled, let self, self.rest == rest else { return }
            self.restDidEnd()
        }
    }
}

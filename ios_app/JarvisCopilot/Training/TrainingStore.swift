import Foundation

/// A change the server has not seen yet.
enum TrainingOp: Codable, Equatable {
    case putTemplate(WorkoutTemplate)
    case deleteTemplate(String)
    case putExercise(Exercise)
    case deleteExercise(String)
    case putSettings([String: ExerciseSettings?])
    case deleteWorkout(Date, device: String?, deviceID: String?)

    /// The template or exercise it is about, so a newer change replaces it.
    var subject: String? {
        switch self {
        case .putTemplate(let t): return "template:\(t.id)"
        case .deleteTemplate(let id): return "template:\(id)"
        case .putExercise(let e): return "exercise:\(e.id)"
        case .deleteExercise(let id): return "exercise:\(id)"
        case .putSettings, .deleteWorkout: return nil
        }
    }
}

/// Strength training on the phone first: gyms have poor signal, so
/// templates, custom exercises, each exercise's settings, the strength
/// history and the workout in progress live in files here, and every change
/// goes to Jarvis Health through a queue that survives a failed send.
@MainActor
final class TrainingStore: ObservableObject {
    static let shared = TrainingStore(sync: HealthTrainingSync())

    @Published private(set) var templates: [WorkoutTemplate] = []
    @Published private(set) var customExercises: [Exercise] = []
    @Published private(set) var settings: [String: ExerciseSettings] = [:]
    /// Saved strength workouts, newest first.
    @Published private(set) var history: [RingWorkout] = [] {
        didSet { logs = history.compactMap(\.strength) }
    }
    /// The saved workouts' logs, newest first (kept, not rebuilt per read:
    /// every set row asks for last time's numbers).
    private(set) var logs: [StrengthLog] = []
    /// A strength workout finished but not yet saved or thrown away — the
    /// summary comes back after a relaunch rather than the workout running on.
    private(set) var finishedWorkout: RingWorkout?
    /// Bumped by every change made on the phone, so a refresh can tell its
    /// snapshot went stale while it was fetched.
    private var revision = 0
    /// The workout under way, written on every change so a crash loses nothing.
    private(set) var activeLog: StrengthLog?
    private(set) var queue: [TrainingOp] = []
    /// Send each change as it is made; tests turn this off to drive `flush`.
    var sendsAtOnce = true

    private let directory: URL
    private let sync: TrainingSyncing?
    private var flushing: Task<Void, Never>?

    init(directory: URL? = nil, sync: TrainingSyncing?) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Training", isDirectory: true)
        self.sync = sync
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        templates = read([WorkoutTemplate].self, "templates") ?? []
        customExercises = read([Exercise].self, "exercises") ?? []
        settings = read([String: ExerciseSettings].self, "settings") ?? [:]
        history = read([RingWorkout].self, "history") ?? []
        logs = history.compactMap(\.strength)
        activeLog = read(StrengthLog.self, "active")
        finishedWorkout = read(RingWorkout.self, "finished")
        queue = read([TrainingOp].self, "queue") ?? []
    }

    // MARK: Templates

    func saveTemplate(_ template: WorkoutTemplate) {
        var template = template
        template.updated = Date()
        if let i = templates.firstIndex(where: { $0.id == template.id }) {
            templates[i] = template
        } else {
            template.order = (templates.map(\.order).max() ?? -1) + 1
            templates.append(template)
        }
        templates.sort { $0.order < $1.order }
        write(templates, "templates")
        enqueue(.putTemplate(template))
    }

    func deleteTemplate(id: String) {
        templates.removeAll { $0.id == id }
        write(templates, "templates")
        enqueue(.deleteTemplate(id))
    }

    func moveTemplates(from source: IndexSet, to destination: Int) {
        templates.move(fromOffsets: source, toOffset: destination)
        for i in templates.indices where templates[i].order != i {
            templates[i].order = i
            enqueue(.putTemplate(templates[i]))
        }
        write(templates, "templates")
    }

    @discardableResult
    func duplicateTemplate(id: String) -> WorkoutTemplate? {
        guard var copy = templates.first(where: { $0.id == id }) else { return nil }
        copy.id = WorkoutTemplate.newID()
        copy.name += " Copy"
        copy.exercises = copy.exercises.map { e in
            var e = e
            e.id = UUID()
            e.sets = e.sets.map { var s = $0; s.id = UUID(); return s }
            return e
        }
        saveTemplate(copy)
        return templates.first { $0.id == copy.id }
    }

    /// When a template was last done, from the saved workouts.
    func lastPerformed(templateID: String) -> Date? {
        history.first { $0.strength?.templateID == templateID }?.start
    }

    // MARK: Exercises and their settings

    func saveExercise(_ exercise: Exercise) {
        var exercise = exercise
        exercise.custom = true
        if let i = customExercises.firstIndex(where: { $0.id == exercise.id }) {
            customExercises[i] = exercise
        } else {
            customExercises.append(exercise)
        }
        write(customExercises, "exercises")
        enqueue(.putExercise(exercise))
    }

    func deleteExercise(id: String) {
        customExercises.removeAll { $0.id == id }
        write(customExercises, "exercises")
        enqueue(.deleteExercise(id))
    }

    func settings(for exerciseID: String) -> ExerciseSettings { settings[exerciseID] ?? ExerciseSettings() }

    func updateSettings(_ exerciseID: String, _ change: (inout ExerciseSettings) -> Void) {
        var value = settings(for: exerciseID)
        change(&value)
        if value.isEmpty {
            settings.removeValue(forKey: exerciseID)
            let cleared: [String: ExerciseSettings?] = [exerciseID: Optional<ExerciseSettings>.none]
            enqueue(.putSettings(cleared))
        } else {
            settings[exerciseID] = value
            enqueue(.putSettings([exerciseID: value]))
        }
        write(settings, "settings")
    }

    /// Exercises done lately, most recent first.
    func recentExerciseIDs(limit: Int) -> [String] {
        var seen: [String] = []
        for log in logs {
            for exercise in log.exercises where !seen.contains(exercise.exerciseID) {
                seen.append(exercise.exerciseID)
                if seen.count == limit { return seen }
            }
        }
        return seen
    }

    // MARK: Workouts

    /// A saved strength workout: new, or an edit of one with the same start.
    func record(_ workout: RingWorkout) {
        guard workout.strength != nil else { return }
        history.removeAll { abs($0.start.timeIntervalSince(workout.start)) < 1 }
        history.append(workout)
        history.sort { $0.start > $1.start }
        write(history, "history")
    }

    /// Take a workout out of the history and off the server. `device` is the
    /// key the server filed it under, when known; `deviceID` rebuilds it.
    func removeWorkout(start: Date, device: String?, deviceID: String?) {
        history.removeAll { abs($0.start.timeIntervalSince(start)) < 1 }
        write(history, "history")
        enqueue(.deleteWorkout(start, device: device, deviceID: deviceID))
    }

    /// The workout in progress (nil once it is saved or thrown away).
    func saveActive(_ log: StrengthLog?) {
        activeLog = log
        if let log { write(log, "active") } else { try? FileManager.default.removeItem(at: url("active")) }
    }

    /// The finished workout waiting on Save or Discard (nil once it has one).
    func saveFinished(_ workout: RingWorkout?) {
        finishedWorkout = workout
        if let workout { write(workout, "finished") } else { try? FileManager.default.removeItem(at: url("finished")) }
    }

    // MARK: Sync

    private func enqueue(_ op: TrainingOp) {
        revision += 1
        if let subject = op.subject { queue.removeAll { $0.subject == subject } }
        queue.append(op)
        write(queue, "queue")
        if sendsAtOnce { Task { await flush() } }
    }

    /// Send what is waiting, in order; stop at the first failure and keep the rest.
    func flush() async {
        if let flushing { return await flushing.value }
        let task = Task { await sendQueued() }
        flushing = task
        await task.value
        flushing = nil
    }

    private func sendQueued() async {
        guard let sync else { return }
        while let op = queue.first {
            do {
                switch op {
                case .putTemplate(let t): try await sync.put(template: t)
                case .deleteTemplate(let id): try await sync.deleteTemplate(id: id)
                case .putExercise(let e): try await sync.put(exercise: e)
                case .deleteExercise(let id): try await sync.deleteExercise(id: id)
                case .putSettings(let s): try await sync.putSettings(s)
                case .deleteWorkout(let start, let device, let deviceID):
                    try await sync.deleteWorkout(start: start, device: device, deviceID: deviceID)
                }
            } catch {
                JcLog.dropped(JcLog.devices, "training sync", error)
                return
            }
            // Only this loop removes, so the first is still the one just sent.
            if queue.first == op { queue.removeFirst() }
            write(queue, "queue")
        }
    }

    /// Send what is waiting, then take the server's copy — unless something
    /// could not be sent, when the phone's copy stands. History is fetched
    /// when there is none (a reinstall) or when asked.
    func refresh(history wanted: Bool = false) async {
        guard let sync else { return }
        await flush()
        guard queue.isEmpty else { return }
        let before = revision
        // Nothing changed here while it was fetched: only then is the
        // server's copy newer than the phone's.
        if let snapshot = try? await sync.trainingSnapshot(), revision == before, queue.isEmpty {
            templates = snapshot.templates.sorted { $0.order < $1.order }
            customExercises = snapshot.exercises.map { var e = $0; e.custom = true; return e }
            settings = snapshot.settings
            write(templates, "templates")
            write(customExercises, "exercises")
            write(settings, "settings")
        }
        guard wanted || history.isEmpty, let server = try? await sync.strengthWorkouts() else { return }
        var merged = server
        for local in history where !server.contains(where: { abs($0.start.timeIntervalSince(local.start)) < 1 }) {
            merged.append(local)
        }
        history = merged.sorted { $0.start > $1.start }
        write(history, "history")
    }

    // MARK: Files

    private func url(_ name: String) -> URL { directory.appendingPathComponent("\(name).json") }

    private func read<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    private func write<T: Encodable>(_ value: T, _ name: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(value).write(to: url(name), options: .atomic)
        } catch {
            JcLog.dropped(JcLog.devices, "training file", error)
        }
    }
}

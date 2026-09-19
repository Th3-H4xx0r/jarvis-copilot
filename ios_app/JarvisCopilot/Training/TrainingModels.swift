import Foundation

// Strength training, as Strong keeps it: a workout is exercises in order, each
// a list of sets. Weights are kilograms everywhere below; only the screen
// speaks pounds.

/// The unit weights are shown and typed in.
enum TrainingUnit: String, Codable, CaseIterable {
    case kg, lb

    static let poundsPerKilogram = 2.2046226218
    private static let key = "jc.training.unit"

    /// What the phone's region uses.
    static var regional: TrainingUnit { Locale.current.measurementSystem == .us ? .lb : .kg }

    /// The person's choice, else the region's.
    static var current: TrainingUnit {
        get { UserDefaults.standard.string(forKey: key).flatMap(TrainingUnit.init(rawValue:)) ?? regional }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    /// Kilograms in this unit.
    func show(_ kg: Double) -> Double { self == .kg ? kg : kg * Self.poundsPerKilogram }

    /// A value in this unit, as kilograms.
    func kilograms(_ value: Double) -> Double { self == .kg ? value : value / Self.poundsPerKilogram }

    /// The smallest change a plate makes, in this unit.
    var step: Double { self == .kg ? 2.5 : 5 }

    var symbol: String { rawValue }

    /// "60", "62.5", "135" — at most two decimals, none when whole.
    func format(_ kg: Double) -> String { Self.number(show(kg)) }

    /// An estimate (a predicted max), to the nearest half: "80.5", not "80.69".
    func estimate(_ kg: Double) -> String { Self.number((show(kg) * 2).rounded() / 2) }

    static func number(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return rounded.formatted(.number.precision(.fractionLength(0...2)).grouping(.never))
    }
}

/// What a set records, and so which columns an exercise shows.
enum ExerciseKind: String, Codable, CaseIterable, Identifiable {
    case weightReps = "weight_reps"
    case repsOnly = "reps_only"
    /// Bodyweight plus a belt or vest: the added weight is logged.
    case weightedBodyweight = "weighted_bodyweight"
    /// A machine or band takes weight off: the help is logged.
    case assistedBodyweight = "assisted_bodyweight"
    case duration
    case distanceDuration = "distance_duration"

    var id: String { rawValue }

    var usesWeight: Bool { [.weightReps, .weightedBodyweight, .assistedBodyweight].contains(self) }
    var usesReps: Bool { [.weightReps, .repsOnly, .weightedBodyweight, .assistedBodyweight].contains(self) }
    var usesSeconds: Bool { self == .duration || self == .distanceDuration }
    var usesMeters: Bool { self == .distanceDuration }

    var label: String {
        switch self {
        case .weightReps: return "Weight & reps"
        case .repsOnly: return "Reps only"
        case .weightedBodyweight: return "Weighted bodyweight"
        case .assistedBodyweight: return "Assisted bodyweight"
        case .duration: return "Duration"
        case .distanceDuration: return "Distance & time"
        }
    }

    /// The weight column's heading ("kg", "+kg", "−kg").
    func weightHeading(_ unit: TrainingUnit) -> String {
        switch self {
        case .weightedBodyweight: return "+\(unit.symbol)"
        case .assistedBodyweight: return "−\(unit.symbol)"
        default: return unit.symbol
        }
    }
}

enum Equipment: String, Codable, CaseIterable, Identifiable {
    case barbell, dumbbell, machine, cable, kettlebell, bodyweight, band
    case ezBar = "ez_bar"
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .barbell: return "Barbell"
        case .dumbbell: return "Dumbbell"
        case .machine: return "Machine"
        case .cable: return "Cable"
        case .kettlebell: return "Kettlebell"
        case .bodyweight: return "Bodyweight"
        case .band: return "Band"
        case .ezBar: return "EZ bar"
        case .other: return "Other"
        }
    }

    /// The bar a plate calculator starts from, when there is one.
    var defaultBarKg: Double? {
        switch self {
        case .barbell: return 20
        case .ezBar: return 10
        default: return nil
        }
    }

    /// A stand-in picture while (or when there is no) photo.
    var symbol: String {
        switch self {
        case .barbell, .ezBar: return "figure.strengthtraining.traditional"
        case .dumbbell, .kettlebell: return "dumbbell.fill"
        case .machine, .cable: return "figure.strengthtraining.functional"
        case .bodyweight: return "figure.core.training"
        case .band: return "figure.flexibility"
        case .other: return "figure.mixed.cardio"
        }
    }
}

/// An exercise from the library, or one the person made.
struct Exercise: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var equipment: Equipment
    var kind: ExerciseKind
    var primaryMuscles: [String] = []
    var secondaryMuscles: [String] = []
    var instructions: [String] = []
    /// Paths inside the free-exercise-db repository ("Plank/0.jpg").
    var images: [String] = []
    var category: String = "strength"
    var level: String? = nil
    var mechanic: String? = nil
    var custom = false

    enum CodingKeys: String, CodingKey {
        case id, name, equipment, kind, instructions, images, category, level, mechanic, custom
        case primaryMuscles = "primary_muscles"
        case secondaryMuscles = "secondary_muscles"
    }

    /// "Chest · Barbell".
    var subtitle: String {
        ([primaryMuscles.first?.capitalized].compactMap { $0 } + [equipment.label]).joined(separator: " · ")
    }
}

/// Warm-ups prepare; drop sets follow without rest; failure means one more
/// rep was tried and missed. Warm-ups never count toward records or volume.
enum SetTag: String, Codable, CaseIterable {
    case working, warmup, drop, failure

    /// What the set badge shows instead of its number.
    var badge: String? {
        switch self {
        case .working: return nil
        case .warmup: return "W"
        case .drop: return "D"
        case .failure: return "F"
        }
    }

    var label: String {
        switch self {
        case .working: return "Working set"
        case .warmup: return "Warm-up"
        case .drop: return "Drop set"
        case .failure: return "Failure"
        }
    }
}

/// One set: what was planned or done, when, and — once the workout is
/// saved — how the heart took it.
struct LoggedSet: Identifiable, Codable, Equatable {
    var id = UUID()
    var tag: SetTag = .working
    var kg: Double?
    var reps: Int?
    var seconds: Int?
    var meters: Double?
    /// 6–10 in halves.
    var rpe: Double?
    /// When it was ticked; nil until then.
    var done: Date?
    /// When it began: the end of the rest before it, if there was one.
    var start: Date?
    /// When the rest after it ended (ran out or skipped).
    var restEnd: Date?
    var hrAvg: Int?
    var hrMax: Int?
    /// How far heart rate fell in the rest after it.
    var hrDrop: Int?
    var e1rm: Double?
    /// All-time bests it set: "e1rm", "weight", "volume", "reps", "seconds".
    var records: [String] = []

    var isDone: Bool { done != nil }

    enum CodingKeys: String, CodingKey {
        case id, tag, kg, reps, seconds, meters, rpe, done, start, e1rm, records
        case restEnd = "rest_end"
        case hrAvg = "hr_avg"
        case hrMax = "hr_max"
        case hrDrop = "hr_drop"
    }

    init(id: UUID = UUID(), tag: SetTag = .working, kg: Double? = nil, reps: Int? = nil, seconds: Int? = nil,
         meters: Double? = nil, rpe: Double? = nil, done: Date? = nil, start: Date? = nil, restEnd: Date? = nil,
         hrAvg: Int? = nil, hrMax: Int? = nil, hrDrop: Int? = nil, e1rm: Double? = nil, records: [String] = []) {
        self.id = id
        self.tag = tag
        self.kg = kg
        self.reps = reps
        self.seconds = seconds
        self.meters = meters
        self.rpe = rpe
        self.done = done
        self.start = start
        self.restEnd = restEnd
        self.hrAvg = hrAvg
        self.hrMax = hrMax
        self.hrDrop = hrDrop
        self.e1rm = e1rm
        self.records = records
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        tag = try c.decodeIfPresent(SetTag.self, forKey: .tag) ?? .working
        kg = try c.decodeIfPresent(Double.self, forKey: .kg)
        reps = try c.decodeIfPresent(Int.self, forKey: .reps)
        seconds = try c.decodeIfPresent(Int.self, forKey: .seconds)
        meters = try c.decodeIfPresent(Double.self, forKey: .meters)
        rpe = try c.decodeIfPresent(Double.self, forKey: .rpe)
        done = try c.decodeIfPresent(Date.self, forKey: .done)
        start = try c.decodeIfPresent(Date.self, forKey: .start)
        restEnd = try c.decodeIfPresent(Date.self, forKey: .restEnd)
        hrAvg = try c.decodeIfPresent(Int.self, forKey: .hrAvg)
        hrMax = try c.decodeIfPresent(Int.self, forKey: .hrMax)
        hrDrop = try c.decodeIfPresent(Int.self, forKey: .hrDrop)
        e1rm = try c.decodeIfPresent(Double.self, forKey: .e1rm)
        records = try c.decodeIfPresent([String].self, forKey: .records) ?? []
    }
}

/// An exercise in a workout or template, with its sets.
struct LoggedExercise: Identifiable, Codable, Equatable {
    var id = UUID()
    var exerciseID: String
    var name: String
    var kind: ExerciseKind
    var note = ""
    /// Exercises sharing a number are a superset, done in rounds.
    var superset: Int?
    var sets: [LoggedSet]

    enum CodingKeys: String, CodingKey {
        case id, name, kind, note, superset, sets
        case exerciseID = "exercise_id"
    }

    init(id: UUID = UUID(), exerciseID: String, name: String, kind: ExerciseKind, note: String = "",
         superset: Int? = nil, sets: [LoggedSet]) {
        self.id = id
        self.exerciseID = exerciseID
        self.name = name
        self.kind = kind
        self.note = note
        self.superset = superset
        self.sets = sets
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        exerciseID = try c.decode(String.self, forKey: .exerciseID)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? exerciseID
        kind = try c.decodeIfPresent(ExerciseKind.self, forKey: .kind) ?? .weightReps
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        superset = try c.decodeIfPresent(Int.self, forKey: .superset)
        sets = try c.decodeIfPresent([LoggedSet].self, forKey: .sets) ?? []
    }
}

/// A strength workout: live while it runs (autosaved on every change) and
/// the record it leaves once saved, totals and heart rate filled in.
struct StrengthLog: Codable, Equatable {
    var name: String
    var templateID: String?
    var note = ""
    var started: Date
    var exercises: [LoggedExercise]
    var volumeKg = 0.0
    var sets = 0
    var reps = 0
    /// Seconds inside sets, and between them.
    var activeSeconds = 0
    var restSeconds = 0

    enum CodingKeys: String, CodingKey {
        case name, note, started, exercises, sets, reps
        case templateID = "template_id"
        case volumeKg = "volume_kg"
        case activeSeconds = "active_seconds"
        case restSeconds = "rest_seconds"
    }

    init(name: String, templateID: String? = nil, note: String = "", started: Date, exercises: [LoggedExercise],
         volumeKg: Double = 0, sets: Int = 0, reps: Int = 0, activeSeconds: Int = 0, restSeconds: Int = 0) {
        self.name = name
        self.templateID = templateID
        self.note = note
        self.started = started
        self.exercises = exercises
        self.volumeKg = volumeKg
        self.sets = sets
        self.reps = reps
        self.activeSeconds = activeSeconds
        self.restSeconds = restSeconds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Workout"
        templateID = try c.decodeIfPresent(String.self, forKey: .templateID)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        started = try c.decodeIfPresent(Date.self, forKey: .started) ?? .distantPast
        exercises = try c.decodeIfPresent([LoggedExercise].self, forKey: .exercises) ?? []
        volumeKg = try c.decodeIfPresent(Double.self, forKey: .volumeKg) ?? 0
        sets = try c.decodeIfPresent(Int.self, forKey: .sets) ?? 0
        reps = try c.decodeIfPresent(Int.self, forKey: .reps) ?? 0
        activeSeconds = try c.decodeIfPresent(Int.self, forKey: .activeSeconds) ?? 0
        restSeconds = try c.decodeIfPresent(Int.self, forKey: .restSeconds) ?? 0
    }

    /// A workout started with nothing in it.
    static func empty(at date: Date) -> StrengthLog {
        StrengthLog(name: Self.defaultName(at: date), started: date, exercises: [])
    }

    /// "Morning Workout", "Evening Workout" — Strong's names for an empty one.
    static func defaultName(at date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: return "Morning Workout"
        case 12..<17: return "Afternoon Workout"
        case 17..<22: return "Evening Workout"
        default: return "Night Workout"
        }
    }
}

/// A routine to start from: exercises and target sets, never done.
struct WorkoutTemplate: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var note = ""
    var order = 0
    var updated = Date()
    var exercises: [LoggedExercise]

    enum CodingKeys: String, CodingKey { case id, name, note, order, updated, exercises }

    init(id: String = WorkoutTemplate.newID(), name: String, note: String = "", order: Int = 0,
         updated: Date = Date(), exercises: [LoggedExercise]) {
        self.id = id
        self.name = name
        self.note = note
        self.order = order
        self.updated = updated
        self.exercises = exercises
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Template"
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
        updated = try c.decodeIfPresent(Date.self, forKey: .updated) ?? .distantPast
        exercises = try c.decodeIfPresent([LoggedExercise].self, forKey: .exercises) ?? []
    }

    /// Lowercase: it becomes part of a registry key on the server.
    static func newID() -> String { UUID().uuidString.lowercased() }
}

/// What the person set for one exercise, wherever it appears.
struct ExerciseSettings: Codable, Equatable {
    var restSeconds: Int?
    var warmupRestSeconds: Int?
    var barKg: Double?
    var kind: ExerciseKind?
    var pinnedNote: String?

    enum CodingKeys: String, CodingKey {
        case kind
        case restSeconds = "rest_s"
        case warmupRestSeconds = "warmup_rest_s"
        case barKg = "bar_kg"
        case pinnedNote = "pinned_note"
    }

    var isEmpty: Bool { self == ExerciseSettings() }
}

extension Date {
    /// Whole seconds: what survives the server's timestamp format, so a
    /// workout found again by its start still matches.
    var wholeSeconds: Date { Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.down)) }
}

import Foundation

/// Every exercise the app knows: the bundled library plus the person's own.
///
/// The library is free-exercise-db (github.com/yuhonas/free-exercise-db,
/// public domain under the Unlicense): 870-odd exercises with muscles,
/// equipment, steps and two photos each. The text ships in the app
/// (`exercises.json`); the photos are fetched when first shown.
@MainActor
final class ExerciseLibrary: ObservableObject {
    static let shared = ExerciseLibrary()

    let builtIn: [Exercise]
    private let byID: [String: Exercise]

    init(data: Data? = nil) {
        let raw = data ?? Bundle.main.url(forResource: "exercises", withExtension: "json").flatMap { try? Data(contentsOf: $0) }
        builtIn = raw.map(Self.decode) ?? []
        byID = Dictionary(builtIn.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The dataset's own shape, mapped onto `Exercise`.
    private struct Raw: Decodable {
        var id: String
        var name: String
        var equipment: String?
        var category: String?
        var level: String?
        var mechanic: String?
        var primaryMuscles: [String]?
        var secondaryMuscles: [String]?
        var instructions: [String]?
        var images: [String]?
    }

    nonisolated static func decode(_ data: Data) -> [Exercise] {
        guard let raws = try? JSONDecoder().decode([Raw].self, from: data) else { return [] }
        return raws.map { raw in
            let equipment = equipment(raw.equipment)
            let category = raw.category ?? "strength"
            return Exercise(id: raw.id, name: raw.name, equipment: equipment,
                            kind: kind(category: category, equipment: equipment, name: raw.name),
                            primaryMuscles: raw.primaryMuscles ?? [], secondaryMuscles: raw.secondaryMuscles ?? [],
                            instructions: raw.instructions ?? [], images: raw.images ?? [], category: category,
                            level: raw.level, mechanic: raw.mechanic)
        }
    }

    nonisolated static func equipment(_ raw: String?) -> Equipment {
        switch raw?.lowercased() {
        case "barbell": return .barbell
        case "dumbbell": return .dumbbell
        case "machine": return .machine
        case "cable": return .cable
        case "kettlebells": return .kettlebell
        case "body only": return .bodyweight
        case "bands": return .band
        case "e-z curl bar": return .ezBar
        default: return .other
        }
    }

    /// Stretches are held, cardio is covered, bodyweight and band work is
    /// counted in reps; everything else is weight × reps. The person can
    /// change any of these per exercise.
    nonisolated static func kind(category: String, equipment: Equipment, name: String = "") -> ExerciseKind {
        let lowered = name.lowercased()
        if category == "stretching" || lowered.contains("plank") || lowered.hasSuffix(" hold") { return .duration }
        if category == "cardio" { return .distanceDuration }
        if equipment == .bodyweight || equipment == .band { return .repsOnly }
        return .weightReps
    }

    nonisolated static func imageURL(_ path: String) -> URL? {
        URL(string: "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/\(path)")
    }

    /// The dataset's muscles, in the order a filter lists them.
    nonisolated static let muscles = ["chest", "shoulders", "triceps", "biceps", "forearms", "lats", "middle back",
                                      "lower back", "traps", "neck", "abdominals", "quadriceps", "hamstrings", "glutes",
                                      "calves", "adductors", "abductors"]

    /// Built-in and custom together, each with the person's kind override,
    /// sorted by name.
    func all(custom: [Exercise], settings: [String: ExerciseSettings]) -> [Exercise] {
        (builtIn + custom)
            .map { exercise in
                var exercise = exercise
                if let kind = settings[exercise.id]?.kind { exercise.kind = kind }
                return exercise
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func exercise(_ id: String, custom: [Exercise], settings: [String: ExerciseSettings]) -> Exercise? {
        guard var found = byID[id] ?? custom.first(where: { $0.id == id }) else { return nil }
        if let kind = settings[id]?.kind { found.kind = kind }
        return found
    }

    /// Every word has to match the name, a muscle or the equipment; names
    /// that start with what was typed come first.
    nonisolated static func search(_ list: [Exercise], text: String, muscle: String?, equipment: Equipment?) -> [Exercise] {
        let words = text.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "-" }).map(String.init)
        let filtered = list.filter { exercise in
            if let muscle, !exercise.primaryMuscles.contains(muscle) && !exercise.secondaryMuscles.contains(muscle) {
                return false
            }
            if let equipment, exercise.equipment != equipment { return false }
            guard !words.isEmpty else { return true }
            let haystack = ([exercise.name] + exercise.primaryMuscles + [exercise.equipment.label])
                .joined(separator: " ")
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            return words.allSatisfy { haystack.contains($0) }
        }
        guard !words.isEmpty else { return filtered }
        let typed = text.lowercased().trimmingCharacters(in: .whitespaces)
        return filtered.sorted { a, b in
            let an = a.name.lowercased(), bn = b.name.lowercased()
            let pa = an.hasPrefix(typed), pb = bn.hasPrefix(typed)
            if pa != pb { return pa }
            let ca = an.contains(typed), cb = bn.contains(typed)
            if ca != cb { return ca }
            return an.count < bn.count
        }
    }
}

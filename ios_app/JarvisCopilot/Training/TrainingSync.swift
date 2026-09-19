import Foundation

/// What the server keeps of strength training.
struct TrainingSnapshot: Equatable {
    var templates: [WorkoutTemplate]
    var exercises: [Exercise]
    var settings: [String: ExerciseSettings]
}

/// The server side of `TrainingStore`, so tests can stand in for it.
@MainActor
protocol TrainingSyncing: AnyObject {
    func trainingSnapshot() async throws -> TrainingSnapshot
    func put(template: WorkoutTemplate) async throws
    func deleteTemplate(id: String) async throws
    func put(exercise: Exercise) async throws
    func deleteExercise(id: String) async throws
    func putSettings(_ settings: [String: ExerciseSettings?]) async throws
    func strengthWorkouts() async throws -> [RingWorkout]
    func deleteWorkout(start: Date, device: String?, deviceID: String?) async throws
}

/// Jarvis Health's training endpoints (`/health/training/*`, `/health/workouts`).
@MainActor
final class HealthTrainingSync: TrainingSyncing {
    private let client: HealthClient

    init(client: HealthClient = HealthClient(spaceID: HealthSpace.shared)) {
        self.client = client
    }

    private var base: String { client.base }

    func trainingSnapshot() async throws -> TrainingSnapshot {
        let object = try await client.api.get("\(base)/training").object()
        let templates = try HealthClient.decode([WorkoutTemplate].self, from: object["templates"] ?? [])
        let exercises = try HealthClient.decode([Exercise].self, from: object["exercises"] ?? [])
        let settings = try HealthClient.decode([String: ExerciseSettings].self, from: object["settings"] ?? [:])
        return TrainingSnapshot(templates: templates, exercises: exercises, settings: settings)
    }

    func put(template: WorkoutTemplate) async throws {
        _ = try await client.api.post("\(base)/training/templates", json: ["template": try HealthClient.serverJSON(template)])
    }

    func deleteTemplate(id: String) async throws {
        _ = try await client.api.post("\(base)/training/templates/delete", json: ["id": id])
    }

    func put(exercise: Exercise) async throws {
        _ = try await client.api.post("\(base)/training/exercises", json: ["exercise": try HealthClient.serverJSON(exercise)])
    }

    func deleteExercise(id: String) async throws {
        _ = try await client.api.post("\(base)/training/exercises/delete", json: ["id": id])
    }

    func putSettings(_ settings: [String: ExerciseSettings?]) async throws {
        var body: [String: Any] = [:]
        for (id, value) in settings {
            body[id] = try value.map { try HealthClient.serverJSON($0) } ?? NSNull()
        }
        _ = try await client.api.post("\(base)/training/settings", json: ["settings": body])
    }

    func strengthWorkouts() async throws -> [RingWorkout] {
        let object = try await client.api.get("\(base)/workouts", query: ["kind": "strength"]).object()
        return try HealthClient.decode([RingWorkout].self, from: object["workouts"] ?? [])
    }

    func deleteWorkout(start: Date, device: String?, deviceID: String?) async throws {
        _ = try await client.api.post("\(base)/workouts/delete",
                                      json: ["start": HealthClient.instant.string(from: start), "device": device ?? "",
                                             "device_id": deviceID ?? ""])
    }
}

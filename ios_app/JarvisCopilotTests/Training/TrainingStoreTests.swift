import XCTest
@testable import JarvisCopilot

/// A stand-in for Jarvis Health's training endpoints.
@MainActor
final class FakeTrainingSync: TrainingSyncing {
    var calls: [String] = []
    var failing = false
    var snapshot = TrainingSnapshot(templates: [], exercises: [], settings: [:])
    var workouts: [RingWorkout] = []

    private func call(_ name: String) throws {
        if failing { throw URLError(.notConnectedToInternet) }
        calls.append(name)
    }

    func trainingSnapshot() async throws -> TrainingSnapshot { try call("snapshot"); return snapshot }
    func put(template: WorkoutTemplate) async throws { try call("put template \(template.name)") }
    func deleteTemplate(id: String) async throws { try call("delete template \(id)") }
    func put(exercise: Exercise) async throws { try call("put exercise \(exercise.name)") }
    func deleteExercise(id: String) async throws { try call("delete exercise \(id)") }
    func putSettings(_ settings: [String: ExerciseSettings?]) async throws { try call("settings \(settings.keys.sorted())") }
    func strengthWorkouts() async throws -> [RingWorkout] { try call("workouts"); return workouts }
    func deleteWorkout(start: Date, deviceID: String?) async throws { try call("delete workout") }
}

/// Strength training kept on the phone first, and sent when it can be.
@MainActor
final class TrainingStoreTests: XCTestCase {
    private var directory: URL!
    private var sync: FakeTrainingSync!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("TrainingStoreTests-\(UUID().uuidString)")
        sync = FakeTrainingSync()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store() -> TrainingStore {
        let store = TrainingStore(directory: directory, sync: sync)
        store.sendsAtOnce = false
        return store
    }

    private func template(_ name: String) -> WorkoutTemplate {
        WorkoutTemplate(name: name, exercises: [LoggedExercise(exerciseID: "Bench", name: "Bench", kind: .weightReps,
                                                               sets: [LoggedSet(kg: 60, reps: 8)])])
    }

    private func strength(at start: Date, templateID: String? = nil) -> RingWorkout {
        RingWorkout(sport: 88, sportName: "Push", start: start, end: start.addingTimeInterval(3600), activeSeconds: 3600,
                    steps: 0, distanceMeters: 0, distanceSource: "ring", kilocalories: 200, heartRateAverage: nil,
                    heartRateMax: nil, heartRates: [], zoneSeconds: [0, 0, 0, 0, 0],
                    strength: StrengthLog(name: "Push", templateID: templateID, started: start, exercises: [
                        LoggedExercise(exerciseID: "Bench", name: "Bench", kind: .weightReps, sets: [])]))
    }

    func testTheWorkoutInProgressSurvivesARelaunch() {
        let log = StrengthLog(name: "Push", started: Date().wholeSeconds, exercises: [])
        store().saveActive(log)
        XCTAssertEqual(store().activeLog, log)
        store().saveActive(nil)
        XCTAssertNil(store().activeLog)
    }

    func testChangesQueueAndFlushInOrder() async {
        let s = store()
        s.saveTemplate(template("Push"))
        s.saveTemplate(template("Pull"))
        s.updateSettings("Bench") { $0.restSeconds = 90 }
        XCTAssertEqual(s.queue.count, 3)
        await s.flush()
        XCTAssertEqual(sync.calls, ["put template Push", "put template Pull", "settings [\"Bench\"]"])
        XCTAssertTrue(s.queue.isEmpty)
        XCTAssertEqual(s.templates.map(\.order), [0, 1])
    }

    func testAFailedSendKeepsTheQueueForNextTime() async {
        let s = store()
        sync.failing = true
        s.saveTemplate(template("Push"))
        await s.flush()
        XCTAssertEqual(s.queue.count, 1)
        XCTAssertEqual(store().queue.count, 1, "the queue is on disk")
        sync.failing = false
        await s.flush()
        XCTAssertTrue(s.queue.isEmpty)
    }

    func testANewerEditReplacesAQueuedOne() {
        let s = store()
        var t = template("Push")
        s.saveTemplate(t)
        t.name = "Push A"
        s.saveTemplate(t)
        s.deleteTemplate(id: t.id)
        XCTAssertEqual(s.queue, [.deleteTemplate(t.id)])
    }

    func testRefreshTakesTheServersCopyOnlyWhenNothingWaits() async {
        let s = store()
        sync.snapshot = TrainingSnapshot(templates: [template("Legs")], exercises: [], settings: ["Squat": ExerciseSettings(restSeconds: 180)])
        sync.failing = true
        s.saveTemplate(template("Push"))
        await s.refresh()
        XCTAssertEqual(s.templates.map(\.name), ["Push"], "an unsent edit is not overwritten")
        sync.failing = false
        await s.refresh()
        XCTAssertEqual(s.templates.map(\.name), ["Legs"])
        XCTAssertEqual(s.settings(for: "Squat").restSeconds, 180)
    }

    func testRefreshPullsHistoryWhenThereIsNone() async {
        let s = store()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        sync.workouts = [strength(at: start)]
        await s.refresh()
        XCTAssertEqual(s.history.map(\.start), [start])
        XCTAssertTrue(sync.calls.contains("workouts"))
    }

    func testRecordingReplacesByStartAndRemembersTemplates() {
        let s = store()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        s.record(strength(at: start, templateID: "t1"))
        s.record(strength(at: start.addingTimeInterval(0.4), templateID: "t1"))
        s.record(strength(at: start.addingTimeInterval(-86_400)))
        XCTAssertEqual(s.history.count, 2)
        XCTAssertEqual(s.lastPerformed(templateID: "t1"), start.addingTimeInterval(0.4))
        XCTAssertEqual(s.recentExerciseIDs(limit: 5), ["Bench"])
        s.removeWorkout(start: start, deviceID: "ring")
        XCTAssertEqual(s.history.count, 1)
        XCTAssertEqual(s.queue.last, .deleteWorkout(start, "ring"))
    }

    func testDuplicatingAndReorderingTemplates() {
        let s = store()
        let push = template("Push")
        s.saveTemplate(push)
        s.saveTemplate(template("Pull"))
        let copy = s.duplicateTemplate(id: push.id)
        XCTAssertEqual(copy?.name, "Push Copy")
        XCTAssertNotEqual(copy?.exercises.first?.id, push.exercises.first?.id)
        s.moveTemplates(from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(s.templates.map(\.name), ["Push Copy", "Push", "Pull"])
        XCTAssertEqual(s.templates.map(\.order), [0, 1, 2])
    }
}

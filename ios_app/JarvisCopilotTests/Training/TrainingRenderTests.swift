import SwiftUI
import XCTest
@testable import JarvisCopilot

/// The strength screens, drawn before they reach a phone.
@MainActor
final class TrainingRenderTests: XCTestCase {
    private let size = CGSize(width: 402, height: 874)
    private let library = ExerciseLibrary()
    private var store: TrainingStore!
    private let bench = "Barbell_Bench_Press_-_Medium_Grip"
    private let row = "Bent_Over_Barbell_Row"
    private let squat = "Barbell_Squat"
    private let t0 = Date(timeIntervalSince1970: 1_789_900_000)

    override func setUp() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TrainingRender-\(UUID().uuidString)")
        store = TrainingStore(directory: dir, sync: nil)
        store.sendsAtOnce = false
        TrainingUnit.current = .kg
    }

    private func sets(_ values: [(Double, Int)], done: Date? = nil) -> [LoggedSet] {
        values.map { LoggedSet(kg: $0.0, reps: $0.1, done: done) }
    }

    private func seedTemplates() {
        store.saveTemplate(WorkoutTemplate(name: "Push Day", exercises: [
            LoggedExercise(exerciseID: bench, name: "Bench Press", kind: .weightReps, sets: sets([(60, 8), (60, 8), (60, 8)])),
            LoggedExercise(exerciseID: "Standing_Military_Press", name: "Overhead Press", kind: .weightReps, sets: sets([(40, 8)])),
            LoggedExercise(exerciseID: "Dips_-_Triceps_Version", name: "Dips", kind: .repsOnly, sets: [LoggedSet(reps: 12)])]))
        store.saveTemplate(WorkoutTemplate(name: "Pull Day", exercises: [
            LoggedExercise(exerciseID: row, name: "Barbell Row", kind: .weightReps, sets: sets([(60, 8)])),
            LoggedExercise(exerciseID: "Pullups", name: "Pull-ups", kind: .repsOnly, sets: [LoggedSet(reps: 8)])]))
        store.saveTemplate(WorkoutTemplate(name: "Legs", exercises: [
            LoggedExercise(exerciseID: squat, name: "Squat", kind: .weightReps, sets: sets([(100, 5)]))]))
    }

    private func seedHistory() {
        let start = Date().addingTimeInterval(-2 * 86_400)
        store.record(RingWorkout(sport: 88, sportName: "Push Day", start: start, end: start.addingTimeInterval(3600),
                                 activeSeconds: 3600, steps: 0, distanceMeters: 0, distanceSource: "ring", kilocalories: 280,
                                 heartRateAverage: 112, heartRateMax: 151, heartRates: [], zoneSeconds: [0, 0, 0, 0, 0],
                                 strength: StrengthLog(name: "Push Day", templateID: store.templates.first?.id, started: start, exercises: [
                                     LoggedExercise(exerciseID: bench, name: "Barbell Bench Press - Medium Grip", kind: .weightReps,
                                                    sets: sets([(60, 8), (62.5, 8), (62.5, 6)], done: start)),
                                     LoggedExercise(exerciseID: row, name: "Bent Over Barbell Row", kind: .weightReps,
                                                    sets: sets([(60, 10), (60, 10), (60, 8)], done: start))])))
    }

    func testThePickerWithTemplates() throws {
        seedTemplates()
        seedHistory()
        try RenderHarness.write(WorkoutPicker(store: store, library: library, onTemplate: { _ in }) { _ in },
                                size: size, name: "strength-picker")
    }

    func testThePickerWithNoTemplates() throws {
        try RenderHarness.write(WorkoutPicker(store: store, library: library, onTemplate: { _ in }) { _ in },
                                size: size, name: "strength-picker-empty")
    }

    func testTheTemplateEditor() throws {
        seedTemplates()
        var template = store.templates[0]
        template.exercises[0].superset = 1
        template.exercises[1].superset = 1
        try RenderHarness.write(TemplateEditor(template: template, store: store, library: library),
                                size: CGSize(width: 402, height: 1100), name: "strength-template-editor")
    }

    func testTheExercisePicker() throws {
        seedHistory()
        try RenderHarness.write(ExercisePicker(store: store, library: library) { _, _ in },
                                size: size, name: "strength-exercise-picker", settle: 4)
    }

    func testTheCustomExerciseForm() throws {
        try RenderHarness.write(CustomExerciseForm(store: store, name: "Zercher Squat") { _ in },
                                size: size, name: "strength-custom-exercise")
    }

    /// A live workout a few sets in, with a rest running.
    private func liveSession() -> (RingWorkoutController, StrengthSession) {
        seedHistory()
        let ring = RingSession(transport: makeRingTransport(FakeRingLink()), defaults: UserDefaults(suiteName: "TrainingRender")!)
        let controller = RingWorkoutController(session: ring, ensureConnected: { false }, training: store, library: library)
        controller.startStrength(template: WorkoutTemplate(name: "Push Day", exercises: [
            LoggedExercise(exerciseID: bench, name: "Barbell Bench Press - Medium Grip", kind: .weightReps,
                           sets: [LoggedSet(tag: .warmup, kg: 20, reps: 10)] + sets([(62.5, 8), (62.5, 8), (62.5, 8)])),
            LoggedExercise(exerciseID: row, name: "Bent Over Barbell Row", kind: .weightReps, sets: sets([(60, 10), (60, 10)])),
            LoggedExercise(exerciseID: "Pullups", name: "Pullups", kind: .repsOnly, sets: [LoggedSet(), LoggedSet()])]))
        let session = controller.strength!
        let e = session.log.exercises
        session.superset(e[2].id, with: e[1].id)
        session.toggleDone(e[0].sets[0].id, in: e[0].id)
        session.toggleDone(e[0].sets[1].id, in: e[0].id)
        session.setRPE(8, set: e[0].sets[1].id, in: e[0].id)
        return (controller, session)
    }

    func testTheLiveLogger() throws {
        let (controller, _) = liveSession()
        try RenderHarness.write(WorkoutLiveView(workout: controller), size: CGSize(width: 402, height: 1300),
                                name: "strength-live")
    }

    func testTheKeypad() throws {
        let (controller, session) = liveSession()
        let e = session.log.exercises[0]
        session.focus = SetFocus(exercise: e.id, set: e.sets[2].id, field: .weight)
        try RenderHarness.write(WorkoutLiveView(workout: controller), size: size, name: "strength-keypad")
    }

    func testTheRestTimer() throws {
        let (_, session) = liveSession()
        try RenderHarness.write(RestTimerView(session: session), size: size, name: "strength-rest")
    }

    func testTheSummary() throws {
        let (controller, session) = liveSession()
        let e = session.log.exercises
        for exercise in e {
            for set in exercise.sets where !set.isDone {
                if exercise.kind == .repsOnly { session.setValue(9, field: .reps, set: set.id, in: exercise.id) }
                session.toggleDone(set.id, in: exercise.id)
            }
        }
        controller.end()
        try RenderHarness.write(WorkoutLiveView(workout: controller), size: CGSize(width: 402, height: 1500),
                                name: "strength-summary")
    }

    func testTheExerciseDetail() throws {
        seedHistory()
        try RenderHarness.write(NavigationStack { ExerciseDetailView(exerciseID: bench, store: store, library: library) },
                                size: CGSize(width: 402, height: 1300), name: "strength-exercise-about", settle: 4)
    }

    /// Five bench sessions over five weeks, climbing.
    private func seedBenchWeeks() {
        for week in 0..<5 {
            let start = Date().addingTimeInterval(-Double(5 - week) * 7 * 86_400)
            let kg = 55 + Double(week) * 2.5
            store.record(RingWorkout(sport: 88, sportName: "Push Day", start: start, end: start.addingTimeInterval(3600),
                                     activeSeconds: 3600, steps: 0, distanceMeters: 0, distanceSource: "ring", kilocalories: 250,
                                     heartRateAverage: nil, heartRateMax: nil, heartRates: [], zoneSeconds: [0, 0, 0, 0, 0],
                                     strength: StrengthLog(name: "Push Day", started: start, exercises: [
                                         LoggedExercise(exerciseID: bench, name: "Bench", kind: .weightReps,
                                                        sets: [LoggedSet(kg: kg, reps: 8, done: start, e1rm: TrainingMath.e1RM(kg: kg, reps: 8)),
                                                               LoggedSet(kg: kg + 5, reps: 5, done: start, e1rm: TrainingMath.e1RM(kg: kg + 5, reps: 5),
                                                                         records: week == 4 ? ["e1rm"] : [])])])))
        }
    }

    func testTheExerciseHistoryChartsAndRecords() throws {
        seedBenchWeeks()
        for tab in [ExerciseDetailView.Tab.history, .charts, .records] {
            try RenderHarness.write(NavigationStack { ExerciseDetailView(exerciseID: bench, store: store, library: library, tab: tab) },
                                    size: CGSize(width: 402, height: 1100), name: "strength-exercise-\(tab.rawValue.lowercased())")
        }
    }

    /// A saved workout, as the Health tab opens it.
    private func savedWorkout() -> RingWorkout {
        let (controller, session) = liveSession()
        for exercise in session.log.exercises {
            for set in exercise.sets where !set.isDone {
                if exercise.kind == .repsOnly { session.setValue(9, field: .reps, set: set.id, in: exercise.id) }
                session.toggleDone(set.id, in: exercise.id)
            }
        }
        controller.end()
        guard case .finished(var workout) = controller.phase else { fatalError("not finished") }
        workout.heartRates = (0..<720).map { 100 + Int(30 * sin(Double($0) / 12)) }
        workout.effort = 6
        workout.kcalSource = "heart_rate"
        workout.kilocalories = 312
        workout.heartRateAverage = 118
        workout.heartRateMax = 152
        return workout
    }

    func testTheWorkoutDetail() throws {
        let workout = savedWorkout()
        try RenderHarness.write(NavigationStack { StrengthWorkoutDetail(workout: workout, store: store) },
                                size: CGSize(width: 402, height: 1500), name: "strength-detail")
    }

    func testTheEditView() throws {
        let workout = savedWorkout()
        try RenderHarness.write(StrengthEditView(workout: workout, store: store, library: library) { _ in },
                                size: CGSize(width: 402, height: 1100), name: "strength-edit")
    }

    func testTheWorkoutsSettingsCard() throws {
        try RenderHarness.write(ScrollView { HealthTabSettings(model: HealthTabModel()).workoutsCard.padding(.top, 20) },
                                size: CGSize(width: 402, height: 330), name: "workouts-settings")
    }

    func testTheAppleHealthSettingsCard() throws {
        try RenderHarness.write(ScrollView { HealthTabSettings(model: HealthTabModel()).appleHealthCard.padding(.top, 20) },
                                size: CGSize(width: 402, height: 300), name: "apple-health-off")
        UserDefaults.standard.set(true, forKey: "jc.health.appleHealth")
        defer { UserDefaults.standard.removeObject(forKey: "jc.health.appleHealth") }
        let writer = AppleHealthWriter()
        try RenderHarness.write(ScrollView { HealthTabSettings(model: HealthTabModel(), appleHealth: writer).appleHealthCard.padding(.top, 20) },
                                size: CGSize(width: 402, height: 900), name: "apple-health-on")
    }
}

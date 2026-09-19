import SwiftUI
import XCTest
@testable import JarvisCopilot

/// The screen before every workout: who will watch it, a preview, and Start.
@MainActor
final class WorkoutConfirmTests: XCTestCase {
    private let run = RingSport.withID(7)
    private let treadmill = RingSport.withID(40)

    private func ring(paired: Bool = true, state: ConnectionState = .ready, battery: RingBattery? = RingBattery(percent: 82, charging: false),
                      connecting: Bool = false) -> WorkoutMonitor.Ring {
        .init(paired: paired, name: "Colmi R12", state: state, battery: battery, connecting: connecting)
    }

    func testAConnectedRingIsReadyWithItsBattery() {
        let list = WorkoutMonitor.list(for: .sport(run), ring: ring(), appleHealth: true)
        XCTAssertEqual(list.map(\.id), ["ring", "phone", "health"])
        XCTAssertEqual(list[0].status, .ready("Connected · 82% battery"))
        XCTAssertTrue(list[1].tracks.contains("GPS"), "outdoors the phone brings GPS")
        XCTAssertEqual(list[2].status, .ready("Saves when you finish"))
    }

    func testIndoorsThePhoneOnlyKeepsTheTimer() {
        let list = WorkoutMonitor.list(for: .sport(treadmill), ring: ring(), appleHealth: false)
        XCTAssertFalse(list[1].tracks.contains("GPS"))
        XCTAssertTrue(list[0].tracks.contains("distance"), "indoors the ring measures distance")
        if case .off = list[2].status {} else { XCTFail("Apple Health off reads as off") }
    }

    func testTheRingsStates() {
        if case .connecting = WorkoutMonitor.list(for: .sport(run), ring: ring(state: .idle, connecting: true), appleHealth: true)[0].status {} else {
            XCTFail("connecting")
        }
        let charging = WorkoutMonitor.list(for: .sport(run), ring: ring(battery: RingBattery(percent: 40, charging: true)), appleHealth: true)
        XCTAssertEqual(charging[0].status, .unavailable("On its charger — take it off to record the workout."))
        let far = WorkoutMonitor.list(for: .strength(nil), ring: ring(state: .idle), appleHealth: true)
        if case .unavailable(let why) = far[0].status { XCTAssertTrue(why.contains("without heart rate")) } else { XCTFail("out of range") }
        let none = WorkoutMonitor.list(for: .sport(run), ring: ring(paired: false), appleHealth: true)
        if case .unavailable(let why) = none[0].status { XCTAssertTrue(why.contains("pair one")) } else { XCTFail("unpaired") }
    }

    func testTheStrengthTileIsAnEmptyStrengthWorkout() {
        XCTAssertEqual(WorkoutChoice.picked(RingSport.withID(RingSport.strengthID)), .strength(nil))
        XCTAssertEqual(WorkoutChoice.picked(run), .sport(run))
    }

    private func pushDay() -> WorkoutTemplate {
        WorkoutTemplate(name: "Push Day", exercises: [
            LoggedExercise(exerciseID: "Barbell_Bench_Press_-_Medium_Grip", name: "Barbell Bench Press - Medium Grip", kind: .weightReps,
                           sets: [LoggedSet(tag: .warmup, kg: 20, reps: 10), LoggedSet(kg: 60, reps: 8), LoggedSet(kg: 62.5, reps: 8),
                                  LoggedSet(kg: 62.5, reps: 6)]),
            LoggedExercise(exerciseID: "Bent_Over_Barbell_Row", name: "Bent Over Barbell Row", kind: .weightReps, superset: 1,
                           sets: [LoggedSet(kg: 60, reps: 10), LoggedSet(kg: 60, reps: 10)]),
            LoggedExercise(exerciseID: "Pullups", name: "Pullups", kind: .repsOnly, superset: 1,
                           sets: [LoggedSet(reps: 8), LoggedSet(reps: 8)]),
            LoggedExercise(exerciseID: "Plank", name: "Plank", kind: .duration, sets: [LoggedSet(seconds: 60)])])
    }

    func testTheTemplateSummaryAndEstimate() {
        TrainingUnit.current = .kg
        let t = pushDay()
        XCTAssertEqual(TemplateEstimate.summary(t.exercises[0], unit: .kg), "3 sets · 6–8 reps · 60–62.5 kg · +1 warm-up")
        XCTAssertEqual(TemplateEstimate.summary(t.exercises[2], unit: .kg), "2 sets · 8 reps")
        XCTAssertEqual(TemplateEstimate.summary(t.exercises[3], unit: .kg), "1 set · 1:00")
        // 9 working sets × (40 s + 2 min) + a warm-up's 40 s ≈ 22 min → 20.
        XCTAssertEqual(TemplateEstimate.minutes(t) { _ in ExerciseSettings() }, 20)
    }

    // MARK: Renders

    private func store() -> TrainingStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Confirm-\(UUID().uuidString)")
        let s = TrainingStore(directory: dir, sync: nil)
        s.sendsAtOnce = false
        return s
    }

    private func render(_ choice: WorkoutChoice, monitors: [WorkoutMonitor], name: String, height: CGFloat = 874) throws {
        let s = store()
        if case .strength(let t?) = choice { s.saveTemplate(t) }
        try RenderHarness.write(NavigationStack {
            WorkoutConfirmView(choice: choice, store: s, library: ExerciseLibrary(), monitors: monitors) { _ in }
        }, size: CGSize(width: 402, height: height), name: name, settle: 3)
    }

    func testTheStrengthTemplateScreen() throws {
        TrainingUnit.current = .kg
        try render(.strength(pushDay()), monitors: WorkoutMonitor.list(for: .strength(nil), ring: ring(), appleHealth: true),
                   name: "confirm-strength")
    }

    func testTheOutdoorRunScreenWhileTheRingConnects() throws {
        try render(.sport(run), monitors: WorkoutMonitor.list(for: .sport(run), ring: ring(state: .connecting, connecting: true), appleHealth: false),
                   name: "confirm-run")
    }

    func testTheEmptyStrengthScreenWithNoRing() throws {
        try render(.strength(nil), monitors: WorkoutMonitor.list(for: .strength(nil), ring: ring(paired: false), appleHealth: true),
                   name: "confirm-empty")
    }
}

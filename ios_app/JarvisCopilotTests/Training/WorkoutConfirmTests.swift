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
        XCTAssertEqual(list[0].status, .ready("82%"))
        XCTAssertEqual(list[0].battery, 82)
        XCTAssertEqual(list[1].status, .ready("GPS"), "outdoors the phone brings GPS")
        XCTAssertEqual(list[2].status, .ready("On"))
        XCTAssertNil(WorkoutMonitor.notes(list), "nothing wrong, no footnote")
    }

    func testIndoorsAndForStrengthThePhoneKeepsTheTimer() {
        XCTAssertEqual(WorkoutMonitor.list(for: .sport(treadmill), ring: ring(), appleHealth: false)[1].status, .ready("Timer"))
        XCTAssertEqual(WorkoutMonitor.list(for: .strength(nil), ring: ring(), appleHealth: false)[1].status, .ready("Rest timer"))
        XCTAssertEqual(WorkoutMonitor.list(for: .sport(treadmill), ring: ring(), appleHealth: false)[2].status, .off("Off"))
    }

    func testTheRingsStatesAndTheirFootnote() {
        XCTAssertEqual(WorkoutMonitor.list(for: .sport(run), ring: ring(state: .idle, connecting: true), appleHealth: true)[0].status,
                       .connecting)
        let charging = WorkoutMonitor.list(for: .sport(run), ring: ring(battery: RingBattery(percent: 40, charging: true)), appleHealth: true)
        XCTAssertEqual(charging[0].status, .problem("Charging", note: "Take the ring off its charger to record the workout."))
        XCTAssertEqual(WorkoutMonitor.notes(charging), "Take the ring off its charger to record the workout.")
        XCTAssertEqual(WorkoutMonitor.list(for: .strength(nil), ring: ring(state: .idle), appleHealth: true)[0].status,
                       .idle("Not connected"), "nothing connects until asked")
        let far = WorkoutMonitor.list(for: .strength(nil), ring: ring(state: .failed("timeout")), appleHealth: true)
        if case .problem(let short, let note) = far[0].status {
            XCTAssertEqual(short, "Not in range")
            XCTAssertTrue(note.contains("sets are logged"))
        } else { XCTFail("out of range") }
        let none = WorkoutMonitor.list(for: .sport(run), ring: ring(paired: false), appleHealth: true)
        XCTAssertEqual(none[0].name, "Ring")
        if case .problem(let short, _) = none[0].status { XCTAssertEqual(short, "Not paired") } else { XCTFail("unpaired") }
    }

    func testNoWearableIsAChoiceForStrengthOnly() {
        let lifting = WorkoutMonitor.list(for: .strength(nil), ring: ring(), ringChosen: false, appleHealth: true)
        XCTAssertEqual(lifting[0].name, "No wearable")
        XCTAssertEqual(lifting[0].status, .idle("Heart rate off"))
        XCTAssertTrue(WorkoutMonitor.canStart(.strength(nil), ringChosen: false, ringPaired: false))
        let running = WorkoutMonitor.list(for: .sport(run), ring: ring(), ringChosen: false, appleHealth: true)
        if case .problem(let short, _) = running[0].status { XCTAssertEqual(short, "None chosen") } else { XCTFail("a run needs the ring") }
        XCTAssertFalse(WorkoutMonitor.canStart(.sport(run), ringChosen: false, ringPaired: true))
        XCTAssertFalse(WorkoutMonitor.canStart(.sport(run), ringChosen: true, ringPaired: false))
        XCTAssertTrue(WorkoutMonitor.canStart(.sport(run), ringChosen: true, ringPaired: true))
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
        if case .strength(let t?) = choice {
            s.saveTemplate(t)
            // Last week's session, for the Previous column.
            let start = Date().addingTimeInterval(-6 * 86_400)
            s.record(RingWorkout(sport: 88, sportName: t.name, start: start, end: start.addingTimeInterval(3000), activeSeconds: 3000,
                                 steps: 0, distanceMeters: 0, distanceSource: "ring", kilocalories: 240, heartRateAverage: nil,
                                 heartRateMax: nil, heartRates: [], zoneSeconds: [0, 0, 0, 0, 0],
                                 strength: StrengthLog(name: t.name, templateID: t.id, started: start, exercises: [
                                     LoggedExercise(exerciseID: t.exercises[0].exerciseID, name: "Bench", kind: .weightReps,
                                                    sets: [LoggedSet(tag: .warmup, kg: 20, reps: 10, done: start),
                                                           LoggedSet(kg: 57.5, reps: 8, done: start), LoggedSet(kg: 60, reps: 8, done: start),
                                                           LoggedSet(kg: 60, reps: 7, done: start)]),
                                     LoggedExercise(exerciseID: "Pullups", name: "Pullups", kind: .repsOnly,
                                                    sets: [LoggedSet(reps: 7, done: start), LoggedSet(reps: 6, done: start)])])))
            s.updateSettings("Pullups") { $0.pinnedNote = "Full hang at the bottom" }
        }
        try RenderHarness.write(NavigationStack {
            WorkoutConfirmView(choice: choice, store: s, library: ExerciseLibrary(), monitors: monitors) { _ in }
        }, size: CGSize(width: 402, height: height), name: name, settle: 3)
    }

    func testTheStrengthTemplateScreen() throws {
        TrainingUnit.current = .kg
        try render(.strength(pushDay()), monitors: WorkoutMonitor.list(for: .strength(nil), ring: ring(), appleHealth: true),
                   name: "confirm-strength", height: 1500)
    }

    func testTheOutdoorRunScreenWhileTheRingConnects() throws {
        try render(.sport(run), monitors: WorkoutMonitor.list(for: .sport(run), ring: ring(state: .connecting, connecting: true), appleHealth: false),
                   name: "confirm-run")
    }

    func testEachWearablesModel() throws {
        let row = HStack(spacing: 16) {
            ForEach([WearableKeepAlive.ring, WearableKeepAlive.bottle, WearableKeepAlive.scale, WearableKeepAlive.esp32], id: \.self) {
                WearableModelView(kind: $0, size: 72, spins: false)
            }
        }
        .padding(20)
        try RenderHarness.write(row, size: CGSize(width: 402, height: 120), name: "wearable-models", settle: 3)
    }

    func testTheWearableSheet() throws {
        try RenderHarness.write(MonitorPicker(choice: .strength(nil), ring: WearablesHub.shared.ring, ringChosen: .constant(true)),
                                size: CGSize(width: 402, height: 520), name: "confirm-monitor-sheet")
    }

    func testARunWithNoWearableChosen() throws {
        try render(.sport(run), monitors: WorkoutMonitor.list(for: .sport(run), ring: ring(), ringChosen: false, appleHealth: true),
                   name: "confirm-run-none")
    }

    func testTheEmptyStrengthScreenWithNoRing() throws {
        try render(.strength(nil), monitors: WorkoutMonitor.list(for: .strength(nil), ring: ring(paired: false), appleHealth: true),
                   name: "confirm-empty")
    }
}

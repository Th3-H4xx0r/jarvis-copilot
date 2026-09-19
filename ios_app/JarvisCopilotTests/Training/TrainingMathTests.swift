import XCTest
@testable import JarvisCopilot

/// The lifting arithmetic every screen shares.
final class TrainingMathTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func log(_ exercises: [LoggedExercise], at offset: TimeInterval = 0) -> StrengthLog {
        StrengthLog(name: "x", started: t0.addingTimeInterval(offset), exercises: exercises)
    }

    private func bench(_ sets: [LoggedSet], id: String = "Bench") -> LoggedExercise {
        LoggedExercise(exerciseID: id, name: id, kind: .weightReps, sets: sets)
    }

    private func done(_ kg: Double, _ reps: Int, tag: SetTag = .working) -> LoggedSet {
        LoggedSet(tag: tag, kg: kg, reps: reps, done: t0)
    }

    func testBrzycki() throws {
        XCTAssertEqual(TrainingMath.e1RM(kg: 100, reps: 1), 100)
        XCTAssertEqual(try XCTUnwrap(TrainingMath.e1RM(kg: 100, reps: 5)), 112.5, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(TrainingMath.e1RM(kg: 60, reps: 8)), 74.48, accuracy: 0.01)
        XCTAssertNil(TrainingMath.e1RM(kg: 60, reps: 13))
        XCTAssertNil(TrainingMath.e1RM(kg: 0, reps: 5))
        XCTAssertEqual(TrainingMath.predicted(from: 112.5, reps: 5), 100, accuracy: 0.01)
    }

    func testWarmupsAndUndoneSetsDoNotCount() {
        let t = TrainingMath.totals(log([bench([done(20, 10, tag: .warmup), done(60, 8), LoggedSet(kg: 60, reps: 8)])]))
        XCTAssertEqual(t.volumeKg, 480)
        XCTAssertEqual(t.sets, 1)
        XCTAssertEqual(t.reps, 8)
        let assisted = LoggedExercise(exerciseID: "Dip", name: "Dip", kind: .assistedBodyweight, sets: [done(20, 10)])
        XCTAssertEqual(TrainingMath.totals(log([assisted])).volumeKg, 0, "help is not volume")
    }

    func testPlatesPerSide() {
        let p = TrainingMath.plates(total: 100, bar: 20, unit: .kg)
        XCTAssertEqual(p.perSide, [25, 15])
        XCTAssertEqual(p.remainder, 0)
        let lb = TrainingMath.plates(total: TrainingUnit.lb.kilograms(225), bar: TrainingUnit.lb.kilograms(45), unit: .lb)
        XCTAssertEqual(lb.perSide, [45, 45])
        XCTAssertEqual(lb.remainder, 0, accuracy: 0.01)
        XCTAssertEqual(TrainingMath.plates(total: 21, bar: 20, unit: .kg).remainder, 0.5, accuracy: 0.001)
        XCTAssertTrue(TrainingMath.plates(total: 15, bar: 20, unit: .kg).perSide.isEmpty)
    }

    func testWarmupCalculator() {
        let w = TrainingMath.warmups(working: 100, bar: 20, unit: .kg)
        XCTAssertEqual(w.map(\.kg), [20, 40, 60, 80])
        XCTAssertEqual(w.map(\.reps), [10, 5, 3, 2])
        XCTAssertTrue(w.allSatisfy { $0.tag == .warmup && !$0.isDone })
        XCTAssertEqual(TrainingMath.warmups(working: 30, bar: 20, unit: .kg).map(\.kg), [20, 25])
        XCTAssertEqual(TrainingMath.warmups(working: 30, bar: nil, unit: .kg).map(\.kg), [12.5, 17.5, 25])
    }

    func testPreviousIsTheSamePositionLastTime() {
        let older = log([bench([done(50, 10), done(55, 8)])], at: -86_400 * 7)
        let newer = log([bench([done(20, 10, tag: .warmup), done(60, 8), done(62.5, 6)])], at: -86_400)
        let history = [newer, older]
        XCTAssertEqual(TrainingMath.previous(exerciseID: "Bench", index: 1, warmup: false, in: history)?.kg, 62.5)
        XCTAssertEqual(TrainingMath.previous(exerciseID: "Bench", index: 0, warmup: true, in: history)?.kg, 20)
        XCTAssertNil(TrainingMath.previous(exerciseID: "Bench", index: 2, warmup: false, in: history))
        XCTAssertNil(TrainingMath.previous(exerciseID: "Squat", index: 0, warmup: false, in: history))
    }

    func testRecordsAndTheRepTable() throws {
        let records = TrainingMath.records(exerciseID: "Bench", in: [log([bench([done(100, 5), done(80, 10), done(20, 20, tag: .warmup)])])])
        XCTAssertEqual(try XCTUnwrap(records.e1RM), 112.5, accuracy: 0.01)
        XCTAssertEqual(records.maxWeight, 100)
        XCTAssertEqual(records.maxSetVolume, 800)
        XCTAssertEqual(records.maxSessionVolume, 1300)
        XCTAssertEqual(records.byReps[5]?.actual, 100)
        XCTAssertNil(records.byReps[3]?.actual)
        XCTAssertEqual(try XCTUnwrap(records.byReps[3]?.predicted), 112.5 * 34 / 36, accuracy: 0.01)
    }

    func testNewRecordsOnlyBeatHistory() {
        let history = [log([bench([done(100, 5)])], at: -86_400)]
        let better = log([bench([done(105, 5), done(90, 5)])])
        let marks = TrainingMath.newRecords(in: better, history: history)
        XCTAssertEqual(Set(marks[better.exercises[0].sets[0].id] ?? []), ["e1rm", "weight", "volume"])
        XCTAssertNil(marks[better.exercises[0].sets[1].id])
        XCTAssertTrue(TrainingMath.newRecords(in: log([bench([done(100, 5)])]), history: history).isEmpty)
        XCTAssertTrue(TrainingMath.newRecords(in: better, history: []).isEmpty, "a first time is not a record")
    }

    func testTemplateChange() {
        let template = WorkoutTemplate(name: "Push", exercises: [bench([LoggedSet(kg: 60, reps: 8), LoggedSet(kg: 60, reps: 8)])])
        var same = StrengthLog(name: "Push", templateID: template.id, started: t0, exercises: template.exercises)
        same.exercises[0].sets[0].done = t0
        XCTAssertEqual(TrainingMath.change(from: template, to: same), .none)
        var heavier = same
        heavier.exercises[0].sets[0].kg = 62.5
        XCTAssertEqual(TrainingMath.change(from: template, to: heavier), .valuesOnly)
        var more = same
        more.exercises[0].sets.append(LoggedSet(kg: 60, reps: 8))
        XCTAssertEqual(TrainingMath.change(from: template, to: more), .structure)
        let updated = TrainingMath.updatingValues(template, from: heavier)
        XCTAssertEqual(updated.exercises[0].sets.map(\.kg), [62.5, 60])
        XCTAssertEqual(updated.id, template.id)
    }

    func testATemplateFromAWorkoutKeepsWhatWasDone() {
        let workout = log([bench([done(60, 8), LoggedSet(kg: 60, reps: 8)]), bench([LoggedSet(kg: 40, reps: 12)], id: "Fly")])
        let t = TrainingMath.template(from: workout, id: "t1", name: "Chest", order: 2)
        XCTAssertEqual(t.exercises.map { $0.sets.count }, [1, 1])
        XCTAssertTrue(t.exercises.flatMap(\.sets).allSatisfy { !$0.isDone })
        XCTAssertEqual(t.order, 2)
    }

    func testChartIsOnePointPerWorkoutOldestFirst() {
        let logs = [log([bench([done(100, 5)])], at: 0), log([bench([done(90, 5)])], at: -86_400)]
        let points = TrainingMath.chart(.heaviest, exerciseID: "Bench", logs: logs)
        XCTAssertEqual(points.map(\.value), [90, 100])
        XCTAssertEqual(TrainingMath.ChartMetric.available(for: .repsOnly), [.reps])
    }
}

import XCTest
@testable import JarvisCopilot

/// Records what a session asked of the rest alert.
@MainActor
final class FakeRestAlerts: RestAlerting {
    var scheduled: [(Date, String)] = []
    var cancels = 0
    var arrivals = 0
    func schedule(at date: Date, title: String, body: String) { scheduled.append((date, body)) }
    func cancel() { cancels += 1 }
    func arrived() { arrivals += 1 }
}

/// Logging sets: previous values, ticking, supersets, drop sets and the rest timer.
@MainActor
final class StrengthSessionTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var store: TrainingStore!
    private var alerts: FakeRestAlerts!
    private let library = ExerciseLibrary()
    private let bench = "Barbell_Bench_Press_-_Medium_Grip"
    private let row = "Bent_Over_Barbell_Row"

    override func setUp() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("StrengthSessionTests-\(UUID().uuidString)")
        store = TrainingStore(directory: dir, sync: nil)
        store.sendsAtOnce = false
        alerts = FakeRestAlerts()
        TrainingUnit.current = .kg
    }

    private func session(_ mode: StrengthSession.Mode = .live, exercises: [String] = []) -> StrengthSession {
        let s = StrengthSession(log: .empty(at: clock), mode: mode, store: store, library: library, alerts: alerts,
                                now: { [unowned self] in self.clock })
        s.addExercises(exercises, asSuperset: false)
        return s
    }

    private func lastTime(_ id: String, _ sets: [(Double, Int)]) {
        let start = clock.addingTimeInterval(-86_400)
        store.record(RingWorkout(sport: 88, sportName: "Push", start: start, end: start.addingTimeInterval(3600),
                                 activeSeconds: 3600, steps: 0, distanceMeters: 0, distanceSource: "ring", kilocalories: 0,
                                 heartRateAverage: nil, heartRateMax: nil, heartRates: [], zoneSeconds: [0, 0, 0, 0, 0],
                                 strength: StrengthLog(name: "Push", started: start, exercises: [
                                     LoggedExercise(exerciseID: id, name: id, kind: .weightReps,
                                                    sets: sets.map { LoggedSet(kg: $0.0, reps: $0.1, done: start) })])))
    }

    func testATemplateBecomesAFreshLog() {
        let template = WorkoutTemplate(name: "Push", exercises: [LoggedExercise(exerciseID: bench, name: "Bench", kind: .weightReps,
                                                                                 sets: [LoggedSet(kg: 60, reps: 8, done: clock)])])
        let log = StrengthSession.log(from: template, at: clock)
        XCTAssertEqual(log.templateID, template.id)
        XCTAssertNotEqual(log.exercises[0].id, template.exercises[0].id)
        XCTAssertFalse(log.exercises[0].sets[0].isDone)
        XCTAssertEqual(log.exercises[0].sets[0].kg, 60)
    }

    func testAnExerciseStartsWithLastTimesSetCount() {
        lastTime(bench, [(60, 8), (60, 8), (60, 6)])
        let s = session(exercises: [bench, row])
        XCTAssertEqual(s.log.exercises.map { $0.sets.count }, [3, 1])
        XCTAssertEqual(s.log.exercises[0].name, "Barbell Bench Press - Medium Grip")
    }

    func testTickingFillsFromLastTimeAndStartsTheRest() {
        lastTime(bench, [(60, 8), (62.5, 6)])
        let s = session(exercises: [bench])
        let e = s.log.exercises[0]
        s.toggleDone(e.sets[1].id, in: e.id)
        XCTAssertEqual(s.log.exercises[0].sets[1].kg, 62.5)
        XCTAssertEqual(s.log.exercises[0].sets[1].reps, 6)
        XCTAssertEqual(s.log.exercises[0].sets[1].done, clock)
        XCTAssertEqual(s.rest?.total, 120)
        XCTAssertEqual(alerts.scheduled.first?.0, clock.addingTimeInterval(120))
    }

    func testASetWithNothingToCountOpensTheKeypad() {
        let s = session(exercises: [bench])
        let e = s.log.exercises[0]
        s.toggleDone(e.sets[0].id, in: e.id)
        XCTAssertFalse(s.log.exercises[0].sets[0].isDone)
        XCTAssertEqual(s.focus, SetFocus(exercise: e.id, set: e.sets[0].id, field: .reps))
        XCTAssertNil(s.rest)
    }

    func testWarmupsRestOnlyWhenAsked() {
        let s = session(exercises: [bench])
        let e = s.log.exercises[0]
        s.setTag(.warmup, set: e.sets[0].id, in: e.id)
        s.setValue(20, field: .weight, set: e.sets[0].id, in: e.id)
        s.setValue(10, field: .reps, set: e.sets[0].id, in: e.id)
        s.toggleDone(e.sets[0].id, in: e.id)
        XCTAssertNil(s.rest, "no warm-up rest unless the exercise has one")
        store.updateSettings(bench) { $0.warmupRestSeconds = 45 }
        s.toggleDone(e.sets[0].id, in: e.id)
        s.toggleDone(e.sets[0].id, in: e.id)
        XCTAssertEqual(s.rest?.total, 45)
    }

    func testTickingDuringARestEndsItWhereTheSetBegan() {
        let s = session(exercises: [bench])
        let e = s.log.exercises[0]
        s.addSet(e.id)
        let sets = s.log.exercises[0].sets
        s.setValue(8, field: .reps, set: sets[0].id, in: e.id)
        s.setValue(8, field: .reps, set: sets[1].id, in: e.id)
        s.toggleDone(sets[0].id, in: e.id)
        let firstTick = clock
        clock = clock.addingTimeInterval(100)  // the rest (2:00) still has 20 s to run
        s.toggleDone(sets[1].id, in: e.id)
        let done = s.log.exercises[0].sets
        XCTAssertEqual(done[0].restEnd, clock.addingTimeInterval(-24), "8 reps ≈ 24 s before the tick")
        XCTAssertEqual(done[1].start, done[0].restEnd, "the set begins where the rest ended — no overlap")
        XCTAssertGreaterThan(done[0].restEnd!, firstTick)
        XCTAssertEqual(alerts.cancels, 1, "the old rest's alert is taken back before the new one")
    }

    func testASupersetRoundCancelsTheRestItCutShort() {
        let s = session()
        s.addExercises([bench, row], asSuperset: true)
        let a = s.log.exercises[0], b = s.log.exercises[1]
        s.addSet(a.id)
        s.addSet(b.id)
        for exercise in s.log.exercises {
            for set in exercise.sets { s.setValue(10, field: .reps, set: set.id, in: exercise.id) }
        }
        let a2 = s.log.exercises[0].sets[1], b1 = s.log.exercises[1].sets[0], a1 = s.log.exercises[0].sets[0]
        s.toggleDone(a1.id, in: a.id)
        s.toggleDone(b1.id, in: b.id)
        XCTAssertNotNil(s.rest)
        clock = clock.addingTimeInterval(60)
        s.toggleDone(a2.id, in: a.id)
        XCTAssertNil(s.rest, "B2 comes next in the round")
        XCTAssertEqual(alerts.cancels, 1, "the rest's alert must not go off mid-set")
    }

    func testTheOrderOfSetsFollowsSupersetRounds() {
        let s = session()
        s.addExercises([bench, row], asSuperset: true)
        s.addSet(s.log.exercises[0].id)
        s.addSet(s.log.exercises[1].id)
        let a = s.log.exercises[0], b = s.log.exercises[1]
        XCTAssertEqual(s.orderedSets.map(\.set), [a.sets[0].id, b.sets[0].id, a.sets[1].id, b.sets[1].id])
    }

    func testAKeypadOnARemovedExerciseCloses() {
        let s = session(exercises: [bench, row])
        let e = s.log.exercises[1]
        s.focus = SetFocus(exercise: e.id, set: e.sets[0].id, field: .reps)
        s.remove(e.id)
        XCTAssertNil(s.focus)
    }

    func testASupersetRestsOnlyAfterTheRound() {
        let s = session()
        s.addExercises([bench, row], asSuperset: true)
        let a = s.log.exercises[0], b = s.log.exercises[1]
        XCTAssertNotNil(a.superset)
        XCTAssertEqual(a.superset, b.superset)
        for (exercise, set) in [(a, a.sets[0]), (b, b.sets[0])] {
            s.setValue(50, field: .weight, set: set.id, in: exercise.id)
            s.setValue(10, field: .reps, set: set.id, in: exercise.id)
        }
        s.toggleDone(a.sets[0].id, in: a.id)
        XCTAssertNil(s.rest, "B's set comes next, no rest")
        XCTAssertEqual(s.nextUp?.exercise.id, b.id)
        s.toggleDone(b.sets[0].id, in: b.id)
        XCTAssertNotNil(s.rest)
    }

    func testADropSetFollowsWithoutRest() {
        let s = session(exercises: [bench])
        let e = s.log.exercises[0]
        s.addSet(e.id)
        let sets = s.log.exercises[0].sets
        s.setTag(.drop, set: sets[1].id, in: e.id)
        s.setValue(10, field: .reps, set: sets[0].id, in: e.id)
        s.toggleDone(sets[0].id, in: e.id)
        XCTAssertNil(s.rest)
    }

    func testTheRestTimer() {
        let s = session(exercises: [bench])
        let e = s.log.exercises[0]
        s.setValue(8, field: .reps, set: e.sets[0].id, in: e.id)
        s.toggleDone(e.sets[0].id, in: e.id)
        s.adjustRest(by: 15)
        XCTAssertEqual(s.rest?.ends, clock.addingTimeInterval(135))
        XCTAssertEqual(alerts.scheduled.count, 2, "moving the end moves the alert")
        clock = clock.addingTimeInterval(40)
        s.skipRest()
        XCTAssertNil(s.rest)
        XCTAssertEqual(s.log.exercises[0].sets[0].restEnd, clock)
        XCTAssertEqual(alerts.cancels, 1)
    }

    func testARestThatRanOutWhileAwayEndsOnItsTime() {
        let s = session(exercises: [bench])
        let e = s.log.exercises[0]
        s.setValue(8, field: .reps, set: e.sets[0].id, in: e.id)
        s.toggleDone(e.sets[0].id, in: e.id)
        clock = clock.addingTimeInterval(600)
        s.resync()
        XCTAssertNil(s.rest)
        XCTAssertEqual(s.log.exercises[0].sets[0].restEnd, clock.addingTimeInterval(-480))
        XCTAssertEqual(alerts.arrivals, 0, "the notification already said so — no second chime")
        XCTAssertEqual(alerts.cancels, 1, "and it is cleared")
    }

    func testUntickingUndoesTheSetAndItsRest() {
        let s = session(exercises: [bench])
        let e = s.log.exercises[0]
        s.setValue(8, field: .reps, set: e.sets[0].id, in: e.id)
        s.toggleDone(e.sets[0].id, in: e.id)
        s.toggleDone(e.sets[0].id, in: e.id)
        XCTAssertFalse(s.log.exercises[0].sets[0].isDone)
        XCTAssertNil(s.rest)
    }

    func testPoundsAreStoredAsKilograms() {
        TrainingUnit.current = .lb
        defer { TrainingUnit.current = .kg }
        let s = session(exercises: [bench])
        let e = s.log.exercises[0]
        s.setValue(135, field: .weight, set: e.sets[0].id, in: e.id)
        XCTAssertEqual(s.log.exercises[0].sets[0].kg ?? 0, 61.235, accuracy: 0.001)
        XCTAssertEqual(s.value(.weight, of: s.log.exercises[0].sets[0]) ?? 0, 135, accuracy: 0.0001)
    }

    func testATemplateNeverTicksOrRests() {
        let s = session(.template, exercises: [bench])
        let e = s.log.exercises[0]
        s.setValue(8, field: .reps, set: e.sets[0].id, in: e.id)
        s.toggleDone(e.sets[0].id, in: e.id)
        XCTAssertFalse(s.log.exercises[0].sets[0].isDone)
        XCTAssertNil(s.rest)
    }

    func testWarmupCalculatorAndSupersetLinking() {
        let s = session(exercises: [bench, row, "Pullups"])
        let e = s.log.exercises[0]
        s.setValue(100, field: .weight, set: e.sets[0].id, in: e.id)
        s.addWarmups(e.id)
        XCTAssertEqual(s.log.exercises[0].sets.map(\.kg), [20, 40, 60, 80, 100])
        let pullups = s.log.exercises[2]
        s.superset(pullups.id, with: e.id)
        XCTAssertEqual(s.log.exercises.map(\.exerciseID), [bench, "Pullups", row])
        XCTAssertEqual(s.log.exercises[0].superset, s.log.exercises[1].superset)
        s.remove(s.log.exercises[1].id)
        XCTAssertNil(s.log.exercises[0].superset, "one exercise is not a superset")
    }

    func testTheNextSetReadsWell() {
        lastTime(bench, [(60, 8)])
        let s = session(exercises: [bench])
        XCTAssertEqual(s.detail, "Barbell Bench Press - Medium Grip · set 1 · 60 kg × 8")
    }
}

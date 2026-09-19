import XCTest
@testable import JarvisCopilot

/// Strength workouts on the controller: the phone's clock, the ring only for
/// heart rate, never a failure for want of a ring, and nothing lost to a relaunch.
@MainActor
final class StrengthWorkoutTests: XCTestCase {
    private var link: FakeRingLink!
    private var ring: RingSession!
    private var store: TrainingStore!
    private var directory: URL!
    private let library = ExerciseLibrary()
    private let bench = "Barbell_Bench_Press_-_Medium_Grip"
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        UserDefaults().removePersistentDomain(forName: "StrengthWorkoutTests")
        link = FakeRingLink()
        ring = RingSession(transport: makeRingTransport(link), defaults: UserDefaults(suiteName: "StrengthWorkoutTests")!)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("StrengthWorkout-\(UUID().uuidString)")
        store = TrainingStore(directory: directory, sync: nil)
        store.sendsAtOnce = false
    }

    private func controller(connected: Bool = true) -> RingWorkoutController {
        let c = RingWorkoutController(session: ring, ensureConnected: { connected }, training: store, library: library,
                                      alerts: FakeRestAlerts(),
                                      profile: { VitalsProfile(age: 30, female: false, weightKg: 80, heightCm: 180, restingHR: 60) },
                                      clock: { [unowned self] in self.clock })
        c.startTimeout = 0.3
        return c
    }

    private func template() -> WorkoutTemplate {
        WorkoutTemplate(name: "Push Day", exercises: [
            LoggedExercise(exerciseID: bench, name: "Bench", kind: .weightReps,
                           sets: [LoggedSet(kg: 60, reps: 8), LoggedSet(kg: 60, reps: 8)])])
    }

    private func tick(elapsed: Int, hr: UInt8, state: UInt8 = 2) -> [UInt8] {
        func be(_ v: Int, _ n: Int) -> [UInt8] { (0..<n).map { UInt8((v >> (8 * (n - 1 - $0))) & 0xFF) } }
        return [88, state] + be(elapsed, 2) + [hr] + be(0, 3) + be(0, 3) + be(12_000, 3)
    }

    private func deliver(_ payload: [UInt8]) { link.deliver(RingProtocol.frame(0x78, payload)) }

    func testStrengthRunsAtOnceAndWithoutARing() async throws {
        let c = controller(connected: false)
        c.start(RingSport.withID(RingSport.strengthID))
        XCTAssertEqual(c.phase, .running, "no countdown, no failure")
        XCTAssertNotNil(c.strength)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(c.vitalsNote, "No ring — logging sets only.")
        XCTAssertTrue(link.payloads(0x77).isEmpty)
    }

    func testTheRingIsAskedForAStrengthSession() async throws {
        let c = controller()
        c.startStrength(template: template())
        try await Task.sleep(nanoseconds: 1_800_000_000)
        XCTAssertEqual(link.payloads(0x77).first.map { Array($0.prefix(2)) }, [1, 88])
        XCTAssertEqual(c.strength?.log.name, "Push Day")
    }

    func testTicksAddHeartRateButNeverPause() async throws {
        let c = controller()
        c.startStrength(template: nil)
        for _ in 1...5 {
            clock = clock.addingTimeInterval(1)
            deliver(tick(elapsed: 3, hr: 120))  // the ring's clock standing still would pause a run
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(c.phase, .running)
        XCTAssertEqual(c.heartSamples.count, 5)
        XCTAssertEqual(c.elapsed(at: clock), 5)
    }

    func testFinishingBuildsTheWorkoutWithSetHeartRates() async throws {
        let c = controller()
        c.startStrength(template: template())
        let session = try XCTUnwrap(c.strength)
        let e = session.log.exercises[0]
        for second in 1...60 {
            clock = clock.addingTimeInterval(1)
            deliver(tick(elapsed: second, hr: 130))
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        session.toggleDone(e.sets[0].id, in: e.id)
        clock = clock.addingTimeInterval(60)
        c.end()
        guard case .finished(let workout) = c.phase else { return XCTFail("not finished: \(c.phase)") }
        XCTAssertEqual(workout.sport, 88)
        XCTAssertEqual(workout.sportName, "Push Day")
        XCTAssertEqual(workout.activeSeconds, 120)
        XCTAssertEqual(workout.strength?.exercises[0].sets[0].hrAvg, 130)
        XCTAssertEqual(workout.strength?.volumeKg, 480)
        XCTAssertNotNil(workout.effort)
        XCTAssertEqual(workout.kcalSource, "ring", "half the workout covered is not enough for heart-rate calories")
        XCTAssertEqual(workout.kilocalories, 12)
    }

    func testAWorkoutInProgressComesBackAfterARelaunch() {
        let first = controller(connected: false)
        first.startStrength(template: template())
        XCTAssertNotNil(store.activeLog)
        let again = controller(connected: false)
        XCTAssertEqual(again.phase, .running)
        XCTAssertEqual(again.strength?.log.name, "Push Day")
    }

    func testSavingRecordsHistoryAndClearsTheActiveLog() throws {
        let c = controller(connected: false)
        var saved: RingWorkout?
        c.onSave = { saved = $0 }
        c.startStrength(template: template())
        let session = try XCTUnwrap(c.strength)
        session.toggleDone(session.log.exercises[0].sets[0].id, in: session.log.exercises[0].id)
        c.end()
        c.close(save: true)
        XCTAssertNotNil(saved?.strength)
        XCTAssertEqual(store.history.count, 1)
        XCTAssertNil(store.activeLog)
        XCTAssertEqual(c.phase, .idle)
        XCTAssertNil(c.strength)
    }

    func testCancellingThrowsItAway() async throws {
        let c = controller()
        c.startStrength(template: template())
        try await Task.sleep(nanoseconds: 1_800_000_000)
        c.cancelStrength()
        XCTAssertEqual(c.phase, .idle)
        XCTAssertNil(store.activeLog)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(link.payloads(0x77).last.map { Array($0.prefix(2)) }, [4, 88], "the ring is told to stop")
    }

    func testAFinishedWorkoutComesBackAsItsSummary() throws {
        let first = controller(connected: false)
        first.startStrength(template: template())
        let session = try XCTUnwrap(first.strength)
        session.toggleDone(session.log.exercises[0].sets[0].id, in: session.log.exercises[0].id)
        first.end()
        XCTAssertNil(store.activeLog)
        let again = controller(connected: false)
        guard case .finished(let workout) = again.phase else { return XCTFail("not the summary: \(again.phase)") }
        XCTAssertEqual(workout.strength?.name, "Push Day")
        again.close(save: true)
        XCTAssertNil(store.finishedWorkout)
        XCTAssertEqual(store.history.count, 1)
    }

    func testStartingAnotherWorkoutSavesTheSummaryFirst() throws {
        let c = controller(connected: false)
        var saved: [RingWorkout] = []
        c.onSave = { saved.append($0) }
        c.startStrength(template: template())
        let session = try XCTUnwrap(c.strength)
        session.toggleDone(session.log.exercises[0].sets[0].id, in: session.log.exercises[0].id)
        c.end()
        c.startStrength(template: nil)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(c.phase, .running)
        XCTAssertTrue(c.heartSamples.isEmpty, "a new workout starts with no heart rate")
    }

    func testALeftoverRingSessionIsStoppedNotAdopted() async throws {
        let c = controller()
        deliver(tick(elapsed: 40, hr: 110))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(c.phase, .idle, "nothing was being logged")
        XCTAssertEqual(link.payloads(0x77).last.map { Array($0.prefix(2)) }, [4, 88])
    }

    func testAnotherSportsTicksAreIgnored() async throws {
        let c = controller(connected: false)
        c.startStrength(template: nil)
        var run = tick(elapsed: 5, hr: 150)
        run[0] = 7
        deliver(run)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(c.heartSamples.isEmpty)
    }

    func testNoWearableChosenMeansNoRingSession() async throws {
        WorkoutMonitorPreference.usesRing = false
        defer { WorkoutMonitorPreference.usesRing = true }
        let c = controller()
        c.startStrength(template: template())
        try await Task.sleep(nanoseconds: 1_800_000_000)
        XCTAssertTrue(link.payloads(0x77).isEmpty, "the ring is left alone")
        XCTAssertEqual(c.vitalsNote, "No wearable chosen — logging sets without heart rate.")
        XCTAssertEqual(c.phase, .running)
    }

    func testARunIsStillARun() async throws {
        let c = controller()
        c.countdownSeconds = 0
        c.start(RingSport.withID(7))
        XCTAssertNil(c.strength)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(link.payloads(0x77).first.map { Array($0.prefix(2)) }, [1, 7])
    }
}

import XCTest
@testable import JarvisCopilot

/// Workouts on the X5 through the shared workout controller: the start screen's pick, the
/// `19` commands, the `18` ticks in the R12's shape, the summary, the link hold, and a strength
/// workout's heart rate surviving the ring ending its own session.
@MainActor
final class X5WorkoutTests: XCTestCase {
    private var defaults: UserDefaults!
    private var r12Link: FakeRingLink!
    private var x5Link: X5FakeLink!
    private var x5Session: X5Session!
    private var x5: X5WorkoutWearable!
    private var controller: RingWorkoutController!
    private var store: TrainingStore!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "X5WorkoutTests-\(UUID().uuidString)")
        r12Link = FakeRingLink()
        let r12 = R12WorkoutWearable(session: RingSession(transport: makeRingTransport(r12Link), defaults: defaults),
                                     connect: { true }, deviceID: { "R12-0001" })
        x5Session = X5Session(defaults: defaults, calendar: X5Bytes.utc, now: { Date() },
                              timing: .init(reply: 0.3, packetGap: 0.3, bigDataGap: 0.3, idle: 0.3))
        x5Link = X5FakeLink()
        x5Link.transport = x5Session.transport
        x5Session.attach(x5Link)
        x5 = X5WorkoutWearable(session: x5Session, connect: { true }, deviceID: { "7CA38A40-X5" }, defaults: defaults)
        store = TrainingStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("X5Workout-\(UUID().uuidString)"), sync: nil)
        store.sendsAtOnce = false
        controller = RingWorkoutController(wearable: r12, age: { 30 }, training: store, library: ExerciseLibrary(),
                                           alerts: FakeRestAlerts(),
                                           profile: { VitalsProfile(age: 30, female: false, weightKg: 80, heightCm: 180, restingHR: 60) },
                                           clock: { [unowned self] in self.clock }, defaults: defaults)
        controller.add(x5)
        controller.countdownSeconds = 0
        controller.startTimeout = 0.6
        controller.endTimeout = 0.3
    }

    /// A 21-byte `18` tick: hr, steps u32, kcal f32, seconds u32, km f32 (little-endian), 3 spare.
    private func x5Tick(hr: Int, steps: Int, kcal: Float, seconds: Int, km: Float) -> Data {
        func u32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
        func f32(_ v: Float) -> [UInt8] { u32(Int(v.bitPattern)) }
        return Data([0x18, UInt8(hr)] + u32(steps) + f32(kcal) + u32(seconds) + f32(km) + [0, 0, 0])
    }

    private func settle(_ ms: UInt64 = 120) async throws { try await Task.sleep(nanoseconds: ms * 1_000_000) }

    private func startOnX5(_ sport: Int = 7) async throws {
        x5Link.script(X5Op.workout, [X5Bytes.frame("19 01")])
        controller.nextStartUsesRing = true
        controller.nextStartWearable = WearableKeepAlive.x5ring
        controller.start(RingSport.withID(sport))
        try await settle()
        x5Link.push(x5Tick(hr: 98, steps: 3, kcal: 0.4, seconds: 1, km: 0.002))
    }

    // MARK: Mapping

    func testATickReadsInTheR12sShape() {
        let tick = X5WorkoutWearable.tick(X5WorkoutTick(heartRate: 152, steps: 3412, kcal: 248.5, seconds: 754, km: 3.42),
                                          sport: 7)
        XCTAssertEqual(tick, RingSportTick(sport: 7, state: .running, elapsed: 754, heartRate: 152, steps: 3412,
                                           distanceMeters: 3420, kilocalories: 248.5))
        XCTAssertNil(X5WorkoutWearable.tick(X5WorkoutTick(heartRate: 0, seconds: 3), sport: 7).heartRate,
                     "no reading yet is not a heart rate of 0")
    }

    func testTheSharedSportsMapOntoTheX5s() {
        XCTAssertEqual(X5WorkoutWearable.x5Sport(for: 7), .run)
        XCTAssertEqual(X5WorkoutWearable.x5Sport(for: 40), .run, "treadmill")
        XCTAssertEqual(X5WorkoutWearable.x5Sport(for: 9), .cycling)
        XCTAssertEqual(X5WorkoutWearable.x5Sport(for: RingSport.strengthID), .workout)
        // Every sport the X5 has a shared entry for comes back as itself.
        for sport in X5Sport.allCases where sport != .workout {
            let shared = X5WorkoutWearable.sport(for: sport)
            if shared.id != RingSport.otherID { XCTAssertEqual(X5WorkoutWearable.x5Sport(for: shared.id), sport) }
        }
        XCTAssertEqual(X5WorkoutWearable.sport(for: .cricket).name, "Cricket", "an X5-only sport keeps its name")
    }

    func testThePreferredWearableIsTheLastPairedChoice() {
        let kinds = [WearableKeepAlive.ring, WearableKeepAlive.x5ring]
        let both: (String) -> Bool = { _ in true }
        let onlyX5: (String) -> Bool = { $0 == WearableKeepAlive.x5ring }
        XCTAssertEqual(WorkoutWearables.preferred(stored: "x5ring", health: "ring", kinds: kinds, isPaired: both), "x5ring")
        XCTAssertEqual(WorkoutWearables.preferred(stored: nil, health: "x5ring", kinds: kinds, isPaired: both), "x5ring")
        XCTAssertEqual(WorkoutWearables.preferred(stored: "ring", health: "ring", kinds: kinds, isPaired: onlyX5), "x5ring",
                       "a choice whose ring is no longer paired falls to one that is")
        XCTAssertEqual(WorkoutWearables.preferred(stored: nil, health: "ring", kinds: kinds, isPaired: { _ in false }), "ring")
    }

    // MARK: Controller

    func testAnX5WorkoutStartsOnTheX5AndRunsFromItsTicks() async throws {
        try await startOnX5()
        XCTAssertEqual(controller.phase, .running)
        XCTAssertEqual(controller.wearable.kind, WearableKeepAlive.x5ring)
        XCTAssertEqual(x5Link.payloads(X5Op.workout).first.map { Array($0.prefix(2)) }, [1, UInt8(X5Sport.run.rawValue)])
        XCTAssertTrue(r12Link.payloads(0x77).isEmpty, "the R12 is told nothing")
        XCTAssertEqual(controller.tick?.heartRate, 98)
        XCTAssertTrue(controller.holdsLink(for: WearableKeepAlive.x5ring))
        XCTAssertFalse(controller.holdsLink(for: WearableKeepAlive.ring))
    }

    func testPauseIsTheButtonsNotTheTicks() async throws {
        try await startOnX5()
        controller.pause()
        try await settle()
        XCTAssertEqual(x5Link.payloads(X5Op.workout).last?.first, 2)
        for s in 2...6 { x5Link.push(x5Tick(hr: 120, steps: 3, kcal: 0.4, seconds: s, km: 0.002)) }
        try await Task.sleep(nanoseconds: 2_700_000_000)
        x5Link.push(x5Tick(hr: 120, steps: 3, kcal: 0.4, seconds: 7, km: 0.002))
        XCTAssertEqual(controller.phase, .paused, "the X5's ticks carry no pause, so they never overrule the button")
        controller.resume()
        try await settle()
        XCTAssertEqual(controller.phase, .running)
        XCTAssertEqual(x5Link.payloads(X5Op.workout).last?.first, 3)
    }

    func testEndingSummarisesFromTheLastTickNotTheEmptyEndPacket() async throws {
        try await startOnX5()
        x5Link.push(x5Tick(hr: 150, steps: 180, kcal: 12, seconds: 60, km: 0.18))
        controller.end()
        try await settle()
        XCTAssertEqual(x5Link.payloads(X5Op.workout).last?.first, 4)
        x5Link.push(X5Bytes.frame("18 FF 01"))
        guard case .finished(let workout) = controller.phase else { return XCTFail("\(controller.phase)") }
        XCTAssertEqual(workout.activeSeconds, 60)
        XCTAssertEqual(workout.steps, 180)
        XCTAssertEqual(workout.kilocalories, 12, accuracy: 0.001)
        XCTAssertEqual(workout.distanceMeters, 180, accuracy: 0.5)
        XCTAssertEqual(workout.sport, 7)
        XCTAssertEqual(controller.deviceIDForSave, "7CA38A40-X5", "saved under the X5's own id")
        XCTAssertFalse(controller.holdsLink(for: WearableKeepAlive.x5ring))
    }

    func testTheRingEndingItselfAfterThirtyStillMinutesEndsTheWorkout() async throws {
        try await startOnX5()
        x5Link.push(x5Tick(hr: 90, steps: 40, kcal: 3, seconds: 1800, km: 0.03))
        x5Link.push(X5Bytes.frame("18 AA 01"))
        XCTAssertEqual(controller.phase, .running, "a 'no steps for 10 minutes' prompt is not an end")
        x5Link.push(X5Bytes.frame("18 FF 02"))
        guard case .finished(let workout) = controller.phase else { return XCTFail("\(controller.phase)") }
        XCTAssertEqual(workout.activeSeconds, 1800)
    }

    func testABusyX5EndsTheStraySessionAndStartsThisOne() async throws {
        x5Link.script(X5Op.workout, [X5Bytes.frame("19 00")])
        x5Link.script(X5Op.workout, [X5Bytes.frame("19 01")])
        x5Link.script(X5Op.workout, [X5Bytes.frame("19 01")])
        controller.nextStartUsesRing = true
        controller.nextStartWearable = WearableKeepAlive.x5ring
        controller.start(RingSport.withID(4))
        try await settle(250)
        XCTAssertEqual(x5Link.payloads(X5Op.workout).map(\.first), [1, 4, 1])
        x5Link.push(x5Tick(hr: 88, steps: 2, kcal: 0.1, seconds: 1, km: 0))
        XCTAssertEqual(controller.phase, .running)
    }

    func testAnX5ThatStaysBusyIsAFailureNotASilentStart() async throws {
        x5Link.script(X5Op.workout, [X5Bytes.frame("19 00")])
        x5Link.script(X5Op.workout, [X5Bytes.frame("19 01")])
        x5Link.script(X5Op.workout, [X5Bytes.frame("19 00")])
        controller.nextStartUsesRing = true
        controller.nextStartWearable = WearableKeepAlive.x5ring
        controller.start(RingSport.withID(4))
        try await settle(250)
        guard case .failed(let why) = controller.phase else { return XCTFail("\(controller.phase)") }
        XCTAssertTrue(why.contains("busy"))
    }

    func testTheOtherRingsTicksDoNotBelongToThisWorkout() async throws {
        try await startOnX5()
        // The R12 still sending a session of its own.
        r12Link.deliver(RingProtocol.frame(0x78, [7, 2, 0, 200, 170, 0, 0, 9, 0, 0, 0, 0, 0, 0]))
        XCTAssertEqual(controller.tick?.elapsed, 1)
        XCTAssertEqual(controller.wearable.kind, WearableKeepAlive.x5ring)
    }

    func testAnX5WorkoutKeptRunningWhileTheAppWasAwayIsPickedUp() async throws {
        defaults.set(9, forKey: X5WorkoutWearable.sportKey)   // a cycle, started before the relaunch
        x5Link.push(x5Tick(hr: 130, steps: 0, kcal: 40, seconds: 600, km: 4.2))
        XCTAssertEqual(controller.phase, .running)
        XCTAssertEqual(controller.sport?.id, 9)
        XCTAssertEqual(controller.wearable.kind, WearableKeepAlive.x5ring)
        XCTAssertTrue(controller.holdsLink(for: WearableKeepAlive.x5ring))
    }

    func testAStrengthWorkoutAsksTheX5AgainWhenItEndsItsOwnSession() async throws {
        x5Link.script(X5Op.workout, [X5Bytes.frame("19 01")])
        x5Link.script(X5Op.workout, [X5Bytes.frame("19 01")])
        controller.nextStartUsesRing = true
        controller.nextStartWearable = WearableKeepAlive.x5ring
        controller.startStrength(template: nil)
        try await Task.sleep(nanoseconds: 1_800_000_000)
        XCTAssertEqual(x5Link.payloads(X5Op.workout).map(\.first), [1])
        x5Link.push(x5Tick(hr: 110, steps: 0, kcal: 1, seconds: 5, km: 0))
        XCTAssertEqual(controller.tick?.heartRate, 110)
        x5Link.push(X5Bytes.frame("18 FF 02"))   // no steps for 30 minutes: the X5 stopped it
        try await settle()
        XCTAssertEqual(x5Link.payloads(X5Op.workout).map(\.first), [1, 1], "asked to start again")
        XCTAssertNil(controller.vitalsNote)
        XCTAssertEqual(controller.phase, .running)
    }

    // MARK: Review fixes

    func testABusyStartIgnoresTheOldSessionAndTheEndItAskedFor() async throws {
        // Busy: the old session is still sending; ending it sends its end packet.
        x5Link.script(X5Op.workout, [X5Bytes.frame("19 00"), x5Tick(hr: 140, steps: 900, kcal: 50, seconds: 300, km: 1)])
        x5Link.script(X5Op.workout, [X5Bytes.frame("19 01"), X5Bytes.frame("18 FF 01")])
        x5Link.script(X5Op.workout, [X5Bytes.frame("19 01")])
        controller.nextStartUsesRing = true
        controller.nextStartWearable = WearableKeepAlive.x5ring
        controller.start(RingSport.withID(4))
        try await settle(250)
        XCTAssertEqual(controller.phase, .starting, "neither failed by the old end nor running on the old session")
        XCTAssertEqual(x5.sportID, 4, "the sport survives the end it sent")
        x5Link.push(x5Tick(hr: 88, steps: 2, kcal: 0.1, seconds: 1, km: 0))
        XCTAssertEqual(controller.phase, .running)
        XCTAssertEqual(controller.tick?.elapsed, 1)
    }

    func testARelaunchMidStrengthPutsItBackOnTheX5() async throws {
        let saved = UserDefaults.standard.object(forKey: "jc.workout.monitor")
        UserDefaults.standard.removeObject(forKey: "jc.workout.monitor")
        defer { UserDefaults.standard.setValue(saved, forKey: "jc.workout.monitor") }
        store.saveActive(.empty(at: clock))
        defaults.setValue(WearableKeepAlive.x5ring, forKey: RingWorkoutController.wearableKey)
        x5Link.script(X5Op.workout, [X5Bytes.frame("19 01")])
        // The app builds the controller with the R12 and adds the X5 right after, as here.
        let r12 = R12WorkoutWearable(session: RingSession(transport: makeRingTransport(r12Link), defaults: defaults),
                                     connect: { true })
        let relaunched = RingWorkoutController(wearable: r12, training: store, library: ExerciseLibrary(),
                                               alerts: FakeRestAlerts(), clock: { [unowned self] in self.clock },
                                               defaults: defaults)
        relaunched.add(x5)
        XCTAssertEqual(relaunched.phase, .running)
        XCTAssertEqual(relaunched.wearable.kind, WearableKeepAlive.x5ring)
        try await Task.sleep(nanoseconds: 1_900_000_000)
        XCTAssertEqual(x5Link.payloads(X5Op.workout).map(\.first), [1], "heart rate is asked of the X5")
        XCTAssertTrue(r12Link.payloads(0x77).isEmpty, "not of the R12")
        XCTAssertTrue(relaunched.holdsLink(for: WearableKeepAlive.x5ring))
        relaunched.cancelStrength()
    }

    func testAPausedX5WorkoutComesBackPaused() {
        defaults.set(9, forKey: X5WorkoutWearable.sportKey)
        defaults.set(true, forKey: X5WorkoutWearable.pausedKey)
        x5Link.push(x5Tick(hr: 100, steps: 0, kcal: 40, seconds: 600, km: 4.2))
        XCTAssertEqual(controller.phase, .paused)
    }

    func testAStrengthRestartThatNeverComesBackSaysSo() async throws {
        x5Link.script(X5Op.workout, [X5Bytes.frame("19 01")])
        x5Link.script(X5Op.workout, [X5Bytes.frame("19 01")])
        controller.nextStartUsesRing = true
        controller.nextStartWearable = WearableKeepAlive.x5ring
        controller.startStrength(template: nil)
        try await Task.sleep(nanoseconds: 1_800_000_000)
        x5Link.push(x5Tick(hr: 110, steps: 0, kcal: 1, seconds: 5, km: 0))
        x5Link.push(X5Bytes.frame("18 FF 02"))
        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertEqual(controller.vitalsNote, "The ring stopped — logging sets only.")
    }

    func testRingWorkoutStartsOnTheR12AndLeavesAnX5WorkoutAlone() async throws {
        let backend = WorkoutsRingBackend(controller: controller)
        let ring = ColmiR12(backend: backend)
        controller.nextStartWearable = nil
        try await startOnX5()
        let paused = try await ring.invoke("ring_workout", args: ["action": "pause"])
        XCTAssertEqual(paused["note"] as? String, "the workout running is not on the R12")
        XCTAssertEqual(controller.phase, .running)
        controller.end()
        x5Link.push(X5Bytes.frame("18 FF 01"))
        controller.close(save: false)
        // Even with the X5 last chosen, the R12's skill starts on the R12.
        WorkoutMonitorPreference.wearable = WearableKeepAlive.x5ring
        defer { UserDefaults.standard.removeObject(forKey: "jc.workout.monitor") }
        _ = try await ring.invoke("ring_workout", args: ["action": "start", "sport": "run"])
        try await settle()
        XCTAssertEqual(controller.wearable.kind, WearableKeepAlive.ring)
    }
}

/// An R12 backend with the workout controller, for `ring_workout`.
@MainActor
private final class WorkoutsRingBackend: RingBackend {
    let deviceID: String? = "ring-test"
    let session = RingSession(transport: makeRingTransport(FakeRingLink()))
    lazy var sync = RingSync(session: session, store: { nil })
    let store: RingHistoryStore? = nil
    let workouts: RingWorkoutController?
    var isConnected: Bool { true }
    var connectionText: String { "Connected" }
    var displayName: String? { "R12_TEST" }

    init(controller: RingWorkoutController) { workouts = controller }

    func ensureConnected(timeout: TimeInterval) async -> Bool { true }
    func waitForSetup(timeout: TimeInterval) async {}
    func releaseIfIdle() {}
}

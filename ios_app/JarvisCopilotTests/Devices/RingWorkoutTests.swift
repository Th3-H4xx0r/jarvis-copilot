import XCTest
@testable import JarvisCopilot

/// Workouts on the ring: its once-a-second packet, and the controller that
/// starts, follows and ends a session from those packets.
@MainActor
final class RingWorkoutTests: XCTestCase {

    /// `[sport, state, elapsed, hr, steps, distance m, small calories]`, big-endian, as the firmware builds it.
    private func tick(sport: UInt8 = 7, state: UInt8 = 2, elapsed: Int, hr: UInt8 = 0, steps: Int = 0,
                      meters: Int = 0, calories: Int = 0) -> [UInt8] {
        func be(_ v: Int, _ n: Int) -> [UInt8] { (0..<n).map { UInt8((v >> (8 * (n - 1 - $0))) & 0xFF) } }
        return [sport, state] + be(elapsed, 2) + [hr] + be(steps, 3) + be(meters, 3) + be(calories, 3)
    }

    func testATickDecodes() throws {
        let t = try XCTUnwrap(RingDecode.sportTick(tick(elapsed: 754, hr: 152, steps: 3412, meters: 3420, calories: 248_000)))
        XCTAssertEqual(t.state, .running)
        XCTAssertEqual(t.elapsed, 754)
        XCTAssertEqual(t.heartRate, 152)
        XCTAssertEqual(t.steps, 3412)
        XCTAssertEqual(t.distanceMeters, 3420)
        XCTAssertEqual(t.kilocalories, 248, accuracy: 0.001, "the ring counts small calories")
    }

    func testANoReadingHeartRateIsNil() {
        XCTAssertNil(RingDecode.sportTick(tick(elapsed: 3, hr: 0))?.heartRate)
        XCTAssertNil(RingDecode.sportTick(tick(elapsed: 3, hr: 250))?.heartRate)
        XCTAssertNil(RingDecode.sportTick([7, 9] + Array(repeating: 0, count: 12)), "an unknown state is not a tick")
    }

    func testTheStartCommandCarriesTheSport() {
        XCTAssertEqual(RingRequest.phoneSport(.start, sport: 7), .command(0x77, [1, 7]))
        XCTAssertEqual(RingRequest.phoneSport(.stop, sport: 88), .command(0x77, [4, 88]))
    }

    func testSportsResolveByName() {
        XCTAssertEqual(RingSport.named("start a run")?.id, 7)
        XCTAssertEqual(RingSport.named("go for a jog")?.id, 7)
        XCTAssertEqual(RingSport.named("strength")?.id, 88)
        XCTAssertNil(RingSport.named("knitting"))
    }

    // MARK: Controller

    private var link: FakeRingLink!
    private var session: RingSession!
    private var controller: RingWorkoutController!
    private let suite = "RingWorkoutTests"

    override func setUp() async throws {
        UserDefaults().removePersistentDomain(forName: suite)
        link = FakeRingLink()
        session = RingSession(transport: makeRingTransport(link), defaults: UserDefaults(suiteName: suite)!)
        controller = RingWorkoutController(session: session, ensureConnected: { true }, age: { 30 })
        controller.countdownSeconds = 0
        controller.startTimeout = 0.3
        controller.endTimeout = 0.2
    }

    private func deliver(_ payload: [UInt8]) { link.deliver(RingProtocol.frame(0x78, payload)) }

    private func started() async throws {
        controller.start(RingSport.withID(7))
        try await Task.sleep(nanoseconds: 80_000_000)
        deliver(tick(elapsed: 1, hr: 98, steps: 3))
    }

    func testAStartRunsOnceTheRingSaysSo() async throws {
        try await started()
        XCTAssertEqual(controller.phase, .running)
        XCTAssertEqual(link.payloads(0x77).first.map { Array($0.prefix(2)) }, [1, 7])
        XCTAssertNotNil(controller.startedAt)
    }

    func testARefusedStartSaysTakeItOffTheCharger() async throws {
        controller.start(RingSport.withID(7))
        try await Task.sleep(nanoseconds: 80_000_000)
        deliver(tick(state: 3, elapsed: 0))
        guard case .failed(let why) = controller.phase else { return XCTFail("\(controller.phase)") }
        XCTAssertTrue(why.contains("charger"))
    }

    func testNoTicksAtAllIsAFailureToo() async throws {
        controller.start(RingSport.withID(7))
        try await Task.sleep(nanoseconds: 600_000_000)
        guard case .failed = controller.phase else { return XCTFail("\(controller.phase)") }
    }

    func testPauseResumeAndEndWithASummary() async throws {
        try await started()
        controller.pause()
        XCTAssertEqual(controller.phase, .paused)
        controller.resume()
        XCTAssertEqual(controller.phase, .running)
        for s in stride(from: 5, through: 60, by: 5) { deliver(tick(elapsed: s, hr: 150, steps: s * 3, meters: s * 3)) }
        controller.end()
        deliver(tick(state: 3, elapsed: 60, hr: 150, steps: 180, meters: 180, calories: 12_000))
        guard case .finished(let workout) = controller.phase else { return XCTFail("\(controller.phase)") }
        XCTAssertEqual(workout.activeSeconds, 60)
        XCTAssertEqual(workout.steps, 180)
        XCTAssertEqual(workout.kilocalories, 12, accuracy: 0.001)
        XCTAssertEqual(workout.heartRateAverage, 150)
        XCTAssertEqual(workout.distanceSource, "ring")
        try await Task.sleep(nanoseconds: 80_000_000)   // the commands go out on their own tasks
        XCTAssertEqual(link.payloads(0x77).map { $0.first }, [1, 2, 3, 4])
        var saved: RingWorkout?
        controller.onSave = { saved = $0 }
        controller.close(save: true)
        XCTAssertEqual(saved?.steps, 180)
        XCTAssertEqual(controller.phase, .idle)
    }

    func testAnEndTheRingNeverConfirmsStillSummarises() async throws {
        try await started()
        controller.end()
        try await Task.sleep(nanoseconds: 400_000_000)
        guard case .finished = controller.phase else { return XCTFail("\(controller.phase)") }
    }

    func testAWorkoutStillRunningOnTheRingIsPickedUp() async throws {
        deliver(tick(sport: 88, elapsed: 600, hr: 120, steps: 40))
        XCTAssertEqual(controller.phase, .running)
        XCTAssertEqual(controller.sport?.name, "Strength")
        XCTAssertEqual(controller.startedAt.map { Date().timeIntervalSince($0) } ?? 0, 600, accuracy: 2)
    }

    func testAStrayTickAfterTheSummaryIsIgnored() async throws {
        try await started()
        controller.end()
        deliver(tick(state: 3, elapsed: 5))
        deliver(tick(elapsed: 6))
        guard case .finished = controller.phase else { return XCTFail("\(controller.phase)") }
    }

    func testZonesAndCadence() async throws {
        XCTAssertEqual(RingWorkoutController.zone(100, age: 30), 1)   // 53%
        XCTAssertEqual(RingWorkoutController.zone(140, age: 30), 3)   // 74%
        XCTAssertEqual(RingWorkoutController.zone(180, age: 30), 5)   // 95%
        try await started()
        for s in 2...31 { deliver(tick(elapsed: s, hr: 140, steps: s * 3)) }
        XCTAssertEqual(controller.cadence, 180, "3 steps a second")
        XCTAssertEqual(controller.zoneSeconds[2], 30)
    }
}

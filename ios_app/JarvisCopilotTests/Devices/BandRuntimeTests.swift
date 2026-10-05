import XCTest
@testable import JarvisCopilot

/// A scripted band: each write pops the next reply queued for its opcode and delivers it the
/// way `BandManager` does — every notification straight into the transport.
@MainActor
final class BandFakeLink: BandLink {
    var isLinkReady = true
    weak var transport: BandTransport?
    private(set) var sent: [[UInt8]] = []
    private var scripts: [UInt8: [[String]]] = [:]

    func script(_ op: UInt8, _ replies: [String]) { scripts[op, default: []].append(replies) }

    func send(_ frame: [UInt8]) {
        sent.append(frame)
        guard let op = frame.first, var queue = scripts[op], !queue.isEmpty else { return }
        let reply = queue.removeFirst()
        scripts[op] = queue
        Task { @MainActor [weak self] in
            for hex in reply { self?.transport?.deliver(Self.bytes(hex)) }
        }
    }

    func push(_ hex: String) { transport?.deliver(Self.bytes(hex)) }

    var sentOps: [UInt8] { sent.compactMap(\.first) }

    static func bytes(_ hex: String) -> [UInt8] {
        let chars = Array(hex)
        return stride(from: 0, to: chars.count - 1, by: 2).map { UInt8(String(chars[$0...$0 + 1]), radix: 16)! }
    }
}

/// The band's runtime over a scripted link, replaying frames the real E910 sent: the
/// handshake and setup, the transport's reply collection, the skills' shapes, and the workout
/// adapter's ticks from the band's own sport status.
@MainActor
final class BandRuntimeTests: XCTestCase {
    /// The E910's real handshake reply: feature tables, alert and settings frames, then A1.
    static let handshake = [
        "a701000202020100061401020000000100060301", "a700030400030000030005010004020b05000102",
        "a702000100000105010000000100000401020203", "a702010000000000000000000001000000000004",
        "a700000001000001000000000000000000000005", "ad02010202020002020002020202020202000002",
        "ad02020202020002000000000000000000000010", "b802010101010000000002020200000002000000",
        "b802000002010002000201020101000000000001", "a10000060a99000702000001e73dc6402bea0000",
    ]
    static let battery = "a001000064016401181100000000000000000000"
    static let product = ["fc56504a31303710020019081c584d441a010101", "fc00000001000000000000000000000000000201",
                          "fc4a313037000000000000000000000000000301"]

    private var link: BandFakeLink!
    private var session: BandSession!

    override func setUp() async throws {
        link = BandFakeLink()
        session = BandSession()
        session.attach(link)
        link.transport = session.transport
    }

    private func scriptSetup() {
        link.script(BandOp.password, Self.handshake)
        link.script(BandOp.syncTime, ["a5010000000000000000000000000000000000"])
        link.script(BandOp.profile, ["a3010000000000000000000000000000000000"])
        link.script(BandOp.battery, [Self.battery])
        link.script(BandOp.product, Self.product)
    }

    // MARK: Setup

    func testSetupReadsTheRealHandshake() async throws {
        scriptSetup()
        try await session.runSetup(profile: BandProfile(heightCm: 178, weightKg: 75, age: 25, male: true,
                                                        stepGoal: 8000, sleepGoalMinutes: 480))
        XCTAssertTrue(session.isSetUp)
        XCTAssertEqual(session.handshake?.ok, true)
        XCTAssertEqual(session.handshake?.mac, "EA:2B:40:C6:3D:E7")
        XCTAssertEqual(session.battery, RingBattery(percent: 100, charging: true))
        XCTAssertEqual(session.features?.supports("DAMotionContrlType"), true)
        XCTAssertEqual(session.features?.supports("weatherFunctionType"), false)
        XCTAssertNotNil(session.alerts, "the handshake carries the phone-alert switches")
        XCTAssertNotNil(session.settings, "and the settings")
        XCTAssertEqual(link.sentOps.prefix(4), [BandOp.password, BandOp.syncTime, BandOp.profile, BandOp.battery])
        XCTAssertEqual(link.sent[2], BandRequest.profile(heightCm: 178, weightKg: 75, age: 25, male: true,
                                                         stepGoal: 8000, sleepGoalMinutes: 480))
    }

    func testARefusedHandshakeFailsSetup() async {
        link.script(BandOp.password, ["a10000020a99000702000001e73dc6402bea0000"])
        do {
            try await session.runSetup(profile: nil)
            XCTFail("a refused handshake must not set up")
        } catch {
            XCTAssertFalse(session.isSetUp)
        }
    }

    // MARK: Transport

    func testAReplyOfSeveralFramesIsCollectedAndTheRestIsUnsolicited() async throws {
        let transport = BandTransport(timeout: 0.5)
        let fake = BandFakeLink()
        transport.link = fake
        fake.transport = transport
        var unsolicited: [[UInt8]] = []
        transport.onFrame = { unsolicited.append($0) }
        fake.script(BandOp.product, Self.product)
        let frames = try await transport.perform(BandRequest.productInfo()) { $0.count == 3 }
        XCTAssertEqual(frames.count, 3)
        fake.push("b50b020000000000000000000000000000000000")
        XCTAssertEqual(unsolicited.first?.first, BandOp.find)
    }

    func testNoAnswerIsATimeoutAndPartOfOneIsAReply() async throws {
        let transport = BandTransport(timeout: 0.3)
        let fake = BandFakeLink()
        transport.link = fake
        fake.transport = transport
        do {
            _ = try await transport.perform(BandRequest.battery())
            XCTFail("nothing came back")
        } catch {
            XCTAssertEqual(error as? BandError, .timeout(BandOp.battery))
        }
        fake.script(BandOp.product, [Self.product[0]])
        let partial = try await transport.perform(BandRequest.productInfo()) { $0.count == 3 }
        XCTAssertEqual(partial.count, 1)
    }

    func testADroppedLinkFailsTheWaitingRequest() async {
        let transport = BandTransport(timeout: 5)
        let fake = BandFakeLink()
        transport.link = fake
        fake.transport = transport
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            transport.linkDropped()
        }
        do {
            _ = try await transport.perform(BandRequest.battery())
            XCTFail("the link dropped")
        } catch {
            XCTAssertEqual(error as? BandError, .notConnected)
        }
    }

    // MARK: Workout

    func testTheWorkoutAdapterTicksFromTheBandsOwnSportStatus() async throws {
        let now = Date()
        var clock = now
        let wearable = BandWorkoutWearable(session: session, connect: { true }, clock: { clock })
        wearable.statusInterval = 0.1
        wearable.stepInterval = 60
        var ticks: [RingSportTick] = []
        wearable.onTick = { ticks.append($0) }
        link.script(BandOp.sportControl, ["da0101"])
        link.script(BandOp.steps, ["d800d2040000e80300002c010000"])
        link.script(BandOp.sportControl, ["da020101a0020301a1020000a20101a301010000", "da020102a0020302a50458020000a70192a40100",
                                          "da020103a0020303a60420030000a8045a8a0100"])
        let accepted = await wearable.send(.start, sport: 7)
        XCTAssertTrue(accepted)
        clock = now.addingTimeInterval(30)
        try await Task.sleep(for: .milliseconds(1300))
        let last = try XCTUnwrap(ticks.last)
        XCTAssertEqual(last.sport, 7)
        XCTAssertEqual(last.state, .running)
        XCTAssertEqual(last.elapsed, 30, "the phone keeps the clock")
        XCTAssertEqual(last.heartRate, 146, "heart rate from the band's own status")
        XCTAssertEqual(last.distanceMeters, 800)
        XCTAssertEqual(last.kilocalories, 100.954, accuracy: 0.001, "the band counts small calories")
        link.script(BandOp.sportControl, ["da0101"])
        _ = await wearable.send(.stop, sport: 7)
        XCTAssertEqual(ticks.last?.state, .ended)
        XCTAssertEqual(ticks.last?.heartRate, 146, "the end keeps the last numbers")
    }

    func testARefusedStartIsReportedAsRefused() async {
        let wearable = BandWorkoutWearable(session: session, connect: { true })
        link.script(BandOp.sportControl, ["da0100"])   // the real reply while on the charger
        let accepted = await wearable.send(.start, sport: 7)
        XCTAssertFalse(accepted)
    }

    func testABusyStartEndsTheStraySportAndStartsAgain() async {
        let wearable = BandWorkoutWearable(session: session, connect: { true })
        wearable.statusInterval = 60
        wearable.stepInterval = 60
        link.script(BandOp.sportControl, ["da0100"])   // busy
        link.script(BandOp.sportControl, ["da0101"])   // the stop
        link.script(BandOp.sportControl, ["da0101"])   // the start, again
        let accepted = await wearable.send(.start, sport: 4)
        XCTAssertTrue(accepted)
        let ops = link.sent.filter { $0.first == BandOp.sportControl }.map { $0.count > 4 && $0[1] == 0x01 ? $0[4] : 0 }
        XCTAssertEqual(ops.prefix(3), [BandSportOp.start.rawValue, BandSportOp.stop.rawValue, BandSportOp.start.rawValue])
        _ = await wearable.send(.stop, sport: 4)
    }

    // MARK: Review fixes

    func testARefusedSettingIsAnErrorNotASilentSuccess() async {
        link.script(BandOp.sedentary, ["e1000000000000000000000000000000000000"])   // ack 0: refused
        do {
            try await session.setSedentary(BandSedentary(json: ["enabled": true, "interval_minutes": 60])!)
            XCTFail("the band said no")
        } catch {
            XCTAssertEqual(error as? BandError, .refused("The band refused that setting."))
        }
        XCTAssertNil(session.sedentary, "nothing is believed that the band refused")
    }

    func testASyncThatReachesNothingDoesNotCountAsSynced() async {
        let defaults = UserDefaults(suiteName: "BandSyncNothing-\(UUID().uuidString)")!
        let store = RingHistoryStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("BandSync-\(UUID().uuidString)"))
        let quiet = BandFakeLink()
        quiet.isLinkReady = false
        let lonely = BandSession()
        lonely.attach(quiet)
        let sync = BandSync(session: lonely, store: { store }, defaults: defaults)
        let changed = await sync.sync(days: 1)
        XCTAssertTrue(changed.isEmpty)
        XCTAssertFalse(sync.lastReached)
        XCTAssertNil(sync.lastSync, "the next connect tries again")
    }

    // MARK: Skills

    func testEverySkillIsABandSkillAndClearDataNeedsConfirmation() async {
        let backend = FakeBandBackend(session: session)
        let device = BandDevice(backend: backend)
        XCTAssertTrue(device.capabilities.allSatisfy { $0.name.hasPrefix("band_") })
        XCTAssertEqual(Set(device.capabilities.map(\.name)).count, device.capabilities.count)
        do {
            _ = try await device.invoke("band_clear_data", args: [:])
            XCTFail("a factory reset needs confirm: true")
        } catch {}
        let status = try? await device.invoke("band_get_status", args: [:])
        XCTAssertEqual(status?["model"] as? String, BandDevice.model)
        XCTAssertNotNil(status?["connected"])
    }
}

/// The band backend with no Bluetooth: always "connected", no history.
@MainActor
private final class FakeBandBackend: BandBackend {
    let deviceID: String? = "band-test"
    let isConnected = true
    let connectionText = "Connected"
    let displayName: String? = "E910"
    let session: BandSession
    let sync: BandSync
    let store: RingHistoryStore? = nil
    let workouts: RingWorkoutController? = nil

    init(session: BandSession) {
        self.session = session
        sync = BandSync(session: session, store: { nil }, defaults: UserDefaults(suiteName: "BandRuntimeTests")!)
    }

    func ensureConnected(timeout: TimeInterval) async -> Bool { true }
    func waitForSetup(timeout: TimeInterval) async {}
    func releaseIfIdle() {}
}

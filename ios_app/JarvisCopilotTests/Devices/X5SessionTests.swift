import XCTest
@testable import JarvisCopilot

/// The X5 session over a scripted ring: setup order, live data that never outlives the link,
/// spot measurements, gestures, the touch panel's timeout, and read-only probing.
@MainActor
final class X5SessionTests: XCTestCase {

    private var defaults: UserDefaults!
    private var link: X5FakeLink!
    private var session: X5Session!
    private var now = X5Bytes.date(2024, 8, 27, 12, 0)

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "X5SessionTests-\(UUID().uuidString)")
        session = X5Session(defaults: defaults, calendar: X5Bytes.utc, now: { [unowned self] in self.now },
                            timing: .init(reply: 0.3, packetGap: 0.3, bigDataGap: 0.3, idle: 0.3))
        link = X5FakeLink()
        link.transport = session.transport
        session.attach(link)
        session.wantedHID = { (true, .keys) }
    }

    private func scriptSetup(firstTime: Bool) {
        link.script(0x01, [X5Bytes.frame("01 F4")])
        link.script(0x42, [X5Bytes.frame("42 01 25 B4 4B 46 11 22 33 44 55 66")])
        link.script(0x13, [X5Bytes.frame("13 50 00 0F A0")])
        link.script(0x27, [X5Bytes.frame("27 01 00 00 05 24 08 27")])
        link.script(0x22, [X5Bytes.frame("22 11 22 33 44 55 66")])
        link.script(0x2B, [X5Bytes.frame("2B 02 00 00 23 59 7F 0A 00 01")])
        link.script(0x2B, [X5Bytes.frame("2B 02 22 00 08 00 7F 1E 00 02")])
        link.script(0x2B, [X5Bytes.frame("2B 02 00 00 23 59 7F 1E 00 04")])
        if firstTime {
            for _ in 0..<3 { link.script(0x2A, [X5Bytes.frame("2A")]) }
            link.script(0x4B, [X5Bytes.frame("4B 40 1F")])
            link.script(0x60, [X5Bytes.data("60 FF")])
            link.script(0x78, [X5Bytes.frame("F8")])
        }
        link.script(0x1C, [X5Bytes.frame("1C 00 01 00 10 0E 01")])
        link.script(0x1C, [X5Bytes.frame("1C 01 01 00 10 0E 01")])
    }

    func testFirstSetupReadsEverythingWritesDefaultsAndProbes() async throws {
        scriptSetup(firstTime: true)
        try await session.runSetup(deviceID: "ring-1")
        XCTAssertEqual(link.sentCommands,
                       [0x01, 0x42, 0x13, 0x27, 0x22, 0x2B, 0x2B, 0x2B, 0x2A, 0x2A, 0x2A, 0x1C, 0x1C, 0x4B, 0x60, 0x78])
        XCTAssertEqual(session.battery, RingBattery(percent: 80, charging: false))
        XCTAssertEqual(session.firmware?.version, "1.0.0.5")
        XCTAssertEqual(session.profile?.heightCm, 180)
        XCTAssertEqual(session.features, [.stepGoal, .manualSpO2])
        XCTAssertEqual(session.goal, 8000)
        // HR every 10 min all day, HRV every 30 all day, SpO2 every 30 overnight.
        let written = link.payloads(0x2A)
        XCTAssertEqual(written.map { $0[8] }, [1, 4, 2])
        XCTAssertEqual(written.map { $0[6] }, [10, 30, 30])
        XCTAssertEqual(Array(written[2].prefix(5)), [0x02, 0x22, 0x00, 0x08, 0x00])
        XCTAssertTrue(session.isSetUp)
    }

    func testASecondSetupDoesNotRewriteMonitoringOrReprobe() async throws {
        scriptSetup(firstTime: true)
        try await session.runSetup(deviceID: "ring-1")
        let first = link.sentCommands.count
        scriptSetup(firstTime: false)
        try await session.runSetup(deviceID: "ring-1")
        XCTAssertEqual(Array(link.sentCommands.dropFirst(first)),
                       [0x01, 0x42, 0x13, 0x27, 0x22, 0x2B, 0x2B, 0x2B, 0x1C, 0x1C])
    }

    func testProbingNeverSendsADestructiveCommand() async throws {
        scriptSetup(firstTime: true)
        try await session.runSetup(deviceID: "ring-1")
        XCTAssertFalse(link.sentCommands.contains(where: [0x61, 0x87, 0x12].contains))
        for op in X5HistoryKind.allCases.map(\.rawValue) {
            XCTAssertFalse(link.payloads(op).contains { $0.first == 0x99 })
        }
    }

    func testGesturesReachTheHandlerOnceEach() {
        var seen: [X5Gesture] = []
        session.onGesture = { seen.append($0) }
        link.push(X5Bytes.frame("0A 05"))
        link.push(X5Bytes.frame("0A 05"))
        now = now.addingTimeInterval(1)
        link.push(X5Bytes.frame("0A 05"))
        link.push(X5Bytes.frame("0A 03"))
        XCTAssertEqual(seen, [.click, .click, .swipeLeft])
        XCTAssertEqual(session.lastGesture?.gesture, .swipeLeft)
    }

    func testATouchTimeoutReArmsOnceWhenAlwaysAwake() async throws {
        session.awakePolicy = .always
        link.push(X5Bytes.frame("1C 08"))
        try await Task.sleep(nanoseconds: 100_000_000)
        now = now.addingTimeInterval(5)
        link.push(X5Bytes.frame("1C 08"))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(link.payloads(0x1C).filter { $0.first == 0x01 }.count, 1)
    }

    func testATouchTimeoutIsLeftAloneOnATimer() async throws {
        session.awakePolicy = .minutes(5)
        link.push(X5Bytes.frame("1C 08"))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(link.payloads(0x1C).isEmpty)
    }

    func testLiveDataStopOwedAcrossADroppedLinkIsPaidOnTheNextSetup() async throws {
        link.script(0x09, [X5Bytes.frame("09 01")])
        await session.setLive(true)
        XCTAssertTrue(session.liveOn)
        session.linkDropped()
        XCTAssertFalse(session.liveOn)
        link.script(0x09, [X5Bytes.frame("09 00")])
        scriptSetup(firstTime: false)
        try await session.runSetup(deviceID: "ring-1")
        let afterDrop = link.sent.drop { $0[0] != 0x09 || $0[1] != 0x01 }.dropFirst()
        XCTAssertEqual(afterDrop.first?[0], 0x09)
        XCTAssertEqual(afterDrop.first?[1], 0x00)
        XCTAssertFalse(defaults.bool(forKey: "jc.x5.liveStopOwed"))
    }

    /// Review finding #7: a live packet already in flight is not the ring acknowledging the stop.
    func testAStreamPacketIsNotTakenAsTheStopAck() async {
        link.script(0x09, [X5Bytes.frame("09 01")])
        await session.setLive(true)
        link.script(0x09, [X5Bytes.data("09 66 00 00 00 19 01 00 00 05 00 00 00 25 00 00 00 00 00 00 00 48 5A 01 00 00 00 00 00 00 00 00")])
        await session.setLive(false)
        XCTAssertTrue(defaults.bool(forKey: "jc.x5.liveStopOwed"))
        link.script(0x09, [X5Bytes.frame("09 00")])
        await session.setLive(false)
        XCTAssertFalse(defaults.bool(forKey: "jc.x5.liveStopOwed"))
    }

    func testAHeartRateCheckReadsTheLiveStreamAndStopsBoth() async throws {
        link.script(0x28, [X5Bytes.frame("28 02")])
        let live = (70...74).map { hr in
            X5Bytes.data("09 66 00 00 00 19 01 00 00 05 00 00 00 25 00 00 00 00 00 00 00 "
                          + String(format: "%02X", hr) + " 5A 01 00 00 00 00 00 00 00 00")
        }
        link.script(0x09, live)
        link.script(0x28, [X5Bytes.frame("28 02")])
        link.script(0x09, [X5Bytes.frame("09 00")])
        let result = try await session.measure(.heartRate, seconds: 1)
        XCTAssertEqual(result, 72)
        let measureWrites = link.payloads(0x28)
        XCTAssertEqual(measureWrites.first.map { Array($0.prefix(2)) }, [0x02, 0x01])
        XCTAssertEqual(measureWrites.last.map { Array($0.prefix(2)) }, [0x02, 0x00])
        XCTAssertEqual(link.payloads(0x09).last?.first, 0x00)
        XCTAssertFalse(session.liveOn)
        XCTAssertEqual(session.measurement?.result, 72)
    }

    /// On the ring: with the page's live data already on, a spot check sent no `09` after starting,
    /// no packets came, and every reading ended "No reading". It always asks after starting now.
    func testASpotCheckAsksForPerSecondDataEvenWithLiveAlreadyOn() async throws {
        link.script(0x09, [X5Bytes.frame("09 01")])
        await session.setLive(true)
        session.holdsLive = true
        link.script(0x28, [X5Bytes.frame("28 02")])
        let live = (70...74).map { hr in
            X5Bytes.data("09 66 00 00 00 19 01 00 00 05 00 00 00 25 00 00 00 00 00 00 00 "
                          + String(format: "%02X", hr) + " 5A 01 00 00 00 00 00 00 00 00")
        }
        link.script(0x09, live)
        link.script(0x28, [X5Bytes.frame("28 02")])
        let result = try await session.measure(.heartRate, seconds: 1)
        XCTAssertEqual(result, 72)
        let writes = link.sent.map { Array($0.prefix(3)) }
        let start = try XCTUnwrap(writes.firstIndex(of: [0x28, 0x02, 0x01]))
        XCTAssertEqual(writes[(start + 1)...].first, [0x09, 0x01, 0x01])
        XCTAssertTrue(session.liveOn, "the page still wants live data")
    }

    /// The X5 has no wear command: wear is read off the skin temperature (35.5 °C is a finger,
    /// 24.4 °C the table) and any heart rate in the live stream.
    func testWearIsReadFromTheSkinTemperature() async {
        link.script(0x14, [X5Bytes.frame("14 63 01 03 55")])
        let worn = await session.checkWear()
        XCTAssertEqual(worn, .worn)
        link.script(0x14, [X5Bytes.frame("14 F4 00 03 55")])
        let off = await session.checkWear()
        XCTAssertEqual(off, .offFinger)
        link.push(X5Bytes.data("09 66 00 00 00 19 01 00 00 05 00 00 00 25 00 00 00 00 00 00 00 48 5A 01 61 00 00 00 00 00 00 00"))
        XCTAssertEqual(session.wear, .worn)
    }

    /// Off the finger a spot check says so straight away instead of running 30 s for nothing.
    func testASpotCheckOffTheFingerSaysSoWithoutMeasuring() async throws {
        link.script(0x14, [X5Bytes.frame("14 F4 00 03 55")])
        let result = try await session.measure(.heartRate, seconds: 1)
        XCTAssertNil(result)
        XCTAssertEqual(session.measurement?.failed, X5Session.notWorn)
        XCTAssertFalse(link.sentCommands.contains(0x28))
    }

    func testWorkoutTicksReachTheHandler() {
        var ticks: [X5WorkoutTick] = []
        session.onWorkoutTick = { ticks.append($0) }
        link.push(X5Bytes.data("18 48 64 00 00 00 00 00 20 41 3C 00 00 00 00 00 80 3F 00 00 00"))
        link.push(X5Bytes.frame("18 FF 02"))
        XCTAssertEqual(ticks.map(\.heartRate), [72, 0])
        XCTAssertEqual(ticks.last?.autoEnded, true)
    }

    func testIdentityIsAnX5ThatAnswersFirmwareAndTime() async {
        link.script(0x27, [X5Bytes.frame("27 01 00 00 05 24 08 27")])
        link.script(0x41, [X5Bytes.frame("41 24 08 08 08 10 47 06 F4")])
        let isX5 = await session.verifyIdentity()
        XCTAssertTrue(isX5)
        let silent = await session.verifyIdentity()
        XCTAssertFalse(silent)
    }
}

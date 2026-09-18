import XCTest
@testable import JarvisCopilot

@MainActor
final class RingSessionTests: XCTestCase {

    private var link: FakeRingLink!
    private var session: RingSession!
    private var defaults: UserDefaults!
    private let suite = "RingSessionTests.session"

    override func setUp() async throws {
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
        link = FakeRingLink()
        session = RingSession(transport: makeRingTransport(link), defaults: defaults)
        session.measurementLimit = 0.4
        session.measurementSettle = 0.3
    }

    override func tearDown() async throws {
        UserDefaults().removePersistentDomain(forName: suite)
    }

    private func blockA(hrv: Bool = false, stress: Bool = false, spo2: Bool = false) -> [UInt8] {
        var a = [UInt8](repeating: 0, count: 14)
        if spo2 { a[3] |= 0b10 }
        if stress { a[13] |= 0b1_0000 }
        if hrv { a[13] |= 0b10_0000 }
        return a
    }

    private func settle() async throws {
        try await Task.sleep(nanoseconds: 60_000_000)
    }

    func testSetupReadsCapabilitiesBatteryAndSettings() async throws {
        link.script(0x01, [RingProtocol.frame(0x01, blockA(hrv: true))])
        link.script(0x3C, [RingProtocol.frame(0x3C, [UInt8](repeating: 0, count: 14))])
        link.script(0x03, [RingProtocol.frame(0x03, [77, 1])])
        link.script(0x16, [RingProtocol.frame(0x16, [1, 1, 10, 0, 0, 0, 1, 60])])
        link.script(0x38, [RingProtocol.frame(0x38, [1, 1, 10, 0x60])])

        await session.runSetup()

        XCTAssertEqual(Array(link.sentCommands.prefix(3)), [0x01, 0x3C, 0x03])
        XCTAssertTrue(session.capabilities.hrv)
        XCTAssertEqual(session.battery, RingBattery(percent: 77, charging: true))
        XCTAssertEqual(session.settings.heartRate?.intervalMinutes, 10)
        XCTAssertEqual(session.settings.hrv, RingHRVMonitor(enabled: true, intervalSupported: true, intervalMinutes: 60))
        XCTAssertFalse(link.sentCommands.contains(0x36), "stress is not supported, so it is not read")
        XCTAssertNotNil(session.setupCompletedAt)
    }

    func testAnHRVWriteIsFollowedByAReRead() async throws {
        session.setCapabilities(RingCapabilities(blockA: blockA(hrv: true), blockB: nil))
        link.script(0x38, [RingProtocol.frame(0x38, [2])])
        link.script(0x38, [RingProtocol.frame(0x38, [1, 1, 10, 30])])

        try await session.setHRVMonitoring(enabled: true, intervalMinutes: 60)

        XCTAssertEqual(link.payloads(0x38).first.map { Array($0.prefix(7)) }, [2, 1, 0x0A, 0x60, 0, 0, 0])
        XCTAssertEqual(session.settings.hrv, RingHRVMonitor(enabled: true, intervalSupported: true, intervalMinutes: 30))
    }

    func testAHeartRateWriteKeepsTheAlertThresholds() async throws {
        link.script(0x16, [RingProtocol.frame(0x16, [1, 1, 10, 5, 50, 180, 1, 60])])
        await session.refreshSettings()
        link.script(0x16, [RingProtocol.frame(0x16, [2])])
        link.script(0x16, [RingProtocol.frame(0x16, [1, 2, 30, 5, 50, 180, 1, 60])])

        try await session.setHeartRateMonitoring(enabled: false, intervalMinutes: 30)

        XCTAssertEqual(link.payloads(0x16).last.map { Array($0.prefix(7)) }, [1, 0, 0, 0, 0, 0, 0],
                       "the last write is the re-read")
        XCTAssertEqual(link.payloads(0x16).dropLast().last.map { Array($0.prefix(7)) }, [2, 2, 30, 5, 50, 180, 1])
        XCTAssertEqual(session.settings.heartRate?.enabled, false)
    }

    func testAWriteTheRingDoesNotSupportThrows() async {
        session.setCapabilities(RingCapabilities(blockA: blockA(), blockB: nil))
        do {
            try await session.setStressMonitoring(enabled: true)
            XCTFail("expected unsupported")
        } catch {
            XCTAssertEqual(error as? RingError, .unsupported("stress monitoring"))
        }
        XCTAssertTrue(link.sent.isEmpty)
    }

    func testAMeasurementCompletesAndStopsTheSensor() async throws {
        link.script(0x69, [RingProtocol.frame(0x69, [1, 0, 0]), RingProtocol.frame(0x69, [1, 0, 72])])
        var finished: RingMeasurementState?
        session.onMeasurementFinished = { finished = $0 }

        try await session.startMeasurement(.heartRate)
        let result = await session.awaitMeasurement(timeout: 1)
        try await settle()

        XCTAssertEqual(result?.phase, .done)
        XCTAssertEqual(result?.value, 72)
        XCTAssertEqual(finished?.value, 72)
        XCTAssertEqual(link.payloads(0x6A).first.map { Array($0.prefix(3)) }, [1, 72, 0])
    }

    /// Frames as the ring sends them: type, error, value, 0, 0, then the
    /// optical signal little-endian in bytes 5–6.
    private func measuring(value: UInt8 = 0, signal: UInt16 = 0) -> [UInt8] {
        [1, 0, value, 0, 0, UInt8(signal & 0xFF), UInt8(signal >> 8)]
    }

    func testTheOpticalSignalMarksTheRingAsOnTheFinger() async throws {
        try await session.startMeasurement(.heartRate)

        link.deliver(RingProtocol.frame(0x69, measuring()))
        XCTAssertNil(session.measurement?.skinContactAt, "zeros are a ring that sees nothing")

        link.deliver(RingProtocol.frame(0x69, measuring(signal: 0x02EA)))
        XCTAssertNotNil(session.measurement?.skinContactAt)
        XCTAssertNil(session.measurement?.value, "a signal is not yet a number")
        XCTAssertEqual(session.measurement?.phase, .measuring)
    }

    func testAHeartRateShowsEachValueAndFinishesOnTheLast() async throws {
        try await session.startMeasurement(.heartRate)

        link.deliver(RingProtocol.frame(0x69, measuring(value: 81, signal: 0x02A3)))
        XCTAssertEqual(session.measurement?.value, 81)
        XCTAssertEqual(session.measurement?.phase, .measuring, "the reading stays live after its first value")

        link.deliver(RingProtocol.frame(0x69, measuring(value: 78, signal: 0x02A3)))
        XCTAssertEqual(session.measurement?.value, 78)

        let result = await session.awaitMeasurement(timeout: 1)
        try await settle()
        XCTAssertEqual(result?.phase, .done)
        XCTAssertEqual(result?.value, 78)
        XCTAssertEqual(link.payloads(0x6A).first.map { Array($0.prefix(3)) }, [1, 78, 0])
    }

    func testAChargingRingSaysSo() async throws {
        link.script(0x69, [RingProtocol.frame(0x69, [1, 1, 0])])
        try await session.startMeasurement(.heartRate)
        let result = await session.awaitMeasurement(timeout: 1)
        XCTAssertEqual(result?.detail, "the ring is on its charger")
    }

    func testANotWornReplyEndsTheMeasurement() async throws {
        link.script(0x69, [RingProtocol.frame(0x69, [1, 1, 0])])
        try await session.startMeasurement(.heartRate)
        let result = await session.awaitMeasurement(timeout: 1)
        XCTAssertEqual(result?.phase, .notWorn)
    }

    func testAMeasurementWithNoReadingTimesOut() async throws {
        try await session.startMeasurement(.heartRate)
        let result = await session.awaitMeasurement(timeout: 2)
        XCTAssertEqual(result?.phase, .timedOut)
    }

    func testOnlyOneMeasurementRunsAtATime() async throws {
        try await session.startMeasurement(.heartRate)
        do {
            try await session.startMeasurement(.heartRate)
            XCTFail("expected busy")
        } catch {
            XCTAssertNotNil(error as? RingError)
        }
        session.cancelMeasurement()
        XCTAssertEqual(session.measurement?.phase, .cancelled)
    }

    func testBatteryAndLiveActivityPushesUpdateState() {
        link.deliver(RingProtocol.frame(0x73, [12, 64, 1]))
        XCTAssertEqual(session.battery, RingBattery(percent: 64, charging: true))

        var live: RingActivity?
        session.onLiveActivity = { live = $0 }
        link.deliver(RingProtocol.frame(0x73, [18, 0x00, 0x03, 0xE8, 0x00, 0x27, 0x10, 0x00, 0x01, 0xF4]))
        XCTAssertEqual(session.liveActivity?.steps, 1000)
        XCTAssertEqual(live?.distanceMeters, 500)
    }

    func testPhoneStillTimeQueriesCountAndResetWhenTheAppIsUsed() async throws {
        link.deliver(RingProtocol.frame(0x73, [62]))
        try await settle()
        link.deliver(RingProtocol.frame(0x73, [62]))
        try await settle()
        session.noteAppBecameActive()
        link.deliver(RingProtocol.frame(0x73, [62]))
        try await settle()

        XCTAssertEqual(link.payloads(0x7E).map { Array($0.prefix(4)) }, [[2, 1, 0, 0], [2, 1, 1, 0], [2, 1, 0, 0]])
    }

    func testDataPushesReachTheSyncHookAndInstantReadingsAreForwarded() {
        var metrics: [RingMetric] = []
        var readings: [(RingMetric, Double)] = []
        session.onDataUpdated = { metrics.append($0) }
        session.onLiveReading = { readings.append(($0, $1.value)) }

        link.deliver(RingProtocol.frame(0x73, [1]))
        link.deliver(RingProtocol.frame(0x73, [44]))
        link.deliver(RingProtocol.frame(0x73, [55, 66]))

        XCTAssertEqual(metrics, [.heartRate, .stress])
        XCTAssertEqual(readings.first?.0, .heartRate)
        XCTAssertEqual(readings.first?.1, 66)
        XCTAssertEqual(session.liveHeartRate?.value, 66)
    }

    private let goalsReply: [UInt8] = [1, 0x10, 0x27, 0, 0x20, 0xA1, 0x07, 0x88, 0x13, 0, 60, 0, 0xE0, 0x01]
    private let someGoals = RingGoals(steps: 9000, calories: 300_000, distanceMeters: 5000, sportMinutes: 60, sleepMinutes: 480)

    func testALateWriteAckIsNotTakenForTheReRead() async throws {
        link.script(0x21, [])
        link.script(0x21, [RingProtocol.frame(0x21, [2]), RingProtocol.frame(0x21, goalsReply)])

        try await session.setGoals(someGoals)

        XCTAssertEqual(session.settings.goals?.steps, 10000, "the ring's reply, not the requested value")
    }

    func testATouchReadSkipsALateGestureReply() async throws {
        var b = [UInt8](repeating: 0, count: 14)
        b[1] = 0b1000_0001
        session.setCapabilities(RingCapabilities(blockA: blockA(), blockB: b))
        link.script(0x3B, [])
        link.script(0x3B, [RingProtocol.frame(0x3B, [1, 1, 5, 0, 3]), RingProtocol.frame(0x3B, [1, 0, 1, 10])])

        await session.refreshSettings()

        XCTAssertNil(session.settings.gesture)
        XCTAssertEqual(session.settings.touch?.isTouch, true)
        XCTAssertEqual(session.settings.touch?.mode, 1)
    }

    func testASettingChangedAfterSetupIsCached() async throws {
        let defaults = UserDefaults(suiteName: "RingSessionTests.cacheWrites")!
        defaults.removePersistentDomain(forName: "RingSessionTests.cacheWrites")
        session.loadCache(deviceID: "ring-2", defaults: defaults)
        link.script(0x21, [RingProtocol.frame(0x21, [2])])
        link.script(0x21, [RingProtocol.frame(0x21, goalsReply)])

        try await session.setGoals(someGoals)

        let restored = RingSession(transport: makeRingTransport(FakeRingLink()))
        restored.loadCache(deviceID: "ring-2", defaults: defaults)
        XCTAssertEqual(restored.settings.goals?.steps, 10000)
    }

    func testTheCacheRestoresCapabilitiesAndSettings() {
        let defaults = UserDefaults(suiteName: "RingSessionTests.cache")!
        defaults.removePersistentDomain(forName: "RingSessionTests.cache")
        session.setCapabilities(RingCapabilities(blockA: blockA(stress: true), blockB: nil))
        session.saveCache(deviceID: "ring-1", defaults: defaults)

        let restored = RingSession(transport: makeRingTransport(FakeRingLink()))
        restored.loadCache(deviceID: "ring-1", defaults: defaults)
        XCTAssertTrue(restored.capabilities.stress)
    }

    // MARK: Real-time mode

    /// The action byte of every real-time heart-rate command written: 1 start, 4 stop.
    private func realtimeActions() -> [UInt8] {
        link.payloads(0x69).filter { $0.first == 6 }.map { $0[1] }
    }

    /// Nothing in the app starts real-time mode any more, but a ring left streaming by an
    /// older build is still running: setup owes it a stop, and pays it on the next link.
    func testARealtimeSessionLeftRunningIsStoppedOnTheNextLink() async {
        session.noteRealtimeOwed()
        link.isLinkReady = true

        await session.runSetup()

        XCTAssertEqual(realtimeActions(), [4])
    }

    func testSetupSendsNoStopWhenNothingIsOwed() async {
        await session.runSetup()

        XCTAssertEqual(realtimeActions(), [])
    }

    func testAnOwedStopSurvivesTheAppBeingKilled() async {
        session.noteRealtimeOwed()

        let relaunched = RingSession(transport: makeRingTransport(link), defaults: defaults)
        await relaunched.runSetup()

        XCTAssertEqual(realtimeActions(), [4])
    }

    func testARealtimeReadingIsNotTakenForAOneShotMeasurement() async throws {
        try await session.startMeasurement(.heartRate)

        link.deliver(RingProtocol.frame(0x69, [6, 0, 78]))

        XCTAssertEqual(session.measurement?.phase, .measuring)
        XCTAssertNil(session.measurement?.value)
    }

    func testARealtimeReadingStillUpdatesTheLiveHeartRate() {
        link.deliver(RingProtocol.frame(0x69, [6, 0, 78]))

        XCTAssertEqual(session.liveHeartRate?.value, 78)
    }

    func testARealtimeReadingDoesNotFinishAOneShotMeasurement() async throws {
        try await session.startMeasurement(.heartRate)

        link.deliver(RingProtocol.frame(0x69, [6, 0, 78]))

        XCTAssertEqual(session.measurement?.phase, .measuring)
        XCTAssertNil(session.measurement?.value)
    }
}

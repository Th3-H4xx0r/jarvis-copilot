import XCTest
@testable import JarvisCopilot

@MainActor
final class RingSyncTests: XCTestCase {

    private var link: FakeRingLink!
    private var session: RingSession!
    private var store: RingHistoryStore!
    private var sync: RingSync!
    private var directory: URL!
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }()

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("RingSyncTests-\(UUID().uuidString)")
        link = FakeRingLink()
        session = RingSession(transport: makeRingTransport(link))
        let store = RingHistoryStore(directory: directory)
        self.store = store
        sync = RingSync(session: session, store: { store })
        sync.calendar = calendar
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 11, hour: 10))!
        sync.now = { now }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testATodaySyncStoresTotalsSlotsSleepAndIntervalHeartRate() async throws {
        var a = [UInt8](repeating: 0, count: 14)
        a[8] = 1
        var b = [UInt8](repeating: 0, count: 14)
        b[7] = 0b1000
        session.setCapabilities(RingCapabilities(blockA: a, blockB: b))
        link.script(0x03, [RingProtocol.frame(0x03, [90, 0])])
        link.script(0x48, [RingProtocol.frame(0x48, [0x00, 0x10, 0x68, 0, 0, 0, 0x01, 0x86, 0xA0, 0x00, 0x0B, 0xB8, 0x00, 0x1E])])
        link.script(0x43, [RingProtocol.frame(0x43, [0xF0, 0, 0]),
                           RingProtocol.frame(0x43, [0x26, 0x09, 0x11, 40, 0, 1, 0x19, 0x00, 0xB0, 0x04, 0x84, 0x03])])
        let sleepBlock: [UInt8] = [0, 8, 0x46, 0x05, 0xA4, 0x01, 3, 200, 2, 250]
        link.script(0x27, on: .bigData, [RingProtocol.bigDataFrame(0x27, [1] + sleepBlock)])
        link.script(0x75, on: .bigData, [RingProtocol.bigDataFrame(0x75, [0, 5, 1, 0, 60, 62, 64])])

        let report = await sync.sync(days: 0)

        XCTAssertEqual(report.failed, [:])
        let day = store.day("2026-09-11")
        XCTAssertEqual(day.activity?.steps, 4200)
        XCTAssertEqual(day.stepSlots.first?.steps, 1200)
        XCTAssertEqual(day.sleep.first?.asleepMinutes, 450)
        XCTAssertEqual(day.heartRate?.values, [60, 62, 64])
        XCTAssertEqual(link.payloads(0x27, on: .bigData).first, [0x00, 0x01])
        XCTAssertEqual(session.battery?.percent, 90)
        XCTAssertNotNil(sync.lastTodaySync)
        XCTAssertNil(sync.lastFullSync)
    }

    func testGatedMetricsAreSkippedAndAFailureDoesNotStopTheRest() async throws {
        var a = [UInt8](repeating: 0, count: 14)
        a[13] = 0b10_0000
        session.setCapabilities(RingCapabilities(blockA: a, blockB: [UInt8](repeating: 0, count: 14)))
        link.script(0x03, [RingProtocol.frame(0x03, [50, 0])])
        link.script(0x48, [RingProtocol.frame(0x48, [UInt8](repeating: 0, count: 14))])
        link.script(0x43, [RingProtocol.frame(0x43, [0xFF])])
        link.script(0x44, [RingProtocol.frame(0x44, [0xFF])])
        link.script(0x15, [RingProtocol.frame(0x15, [0xFF])])
        // HRV (0x39) gets no reply and times out.

        let report = await sync.sync(days: 0)

        XCTAssertEqual(Set(report.updated), ["activity", "sleep", "heart_rate"])
        XCTAssertNotNil(report.failed["hrv"])
        XCTAssertFalse(link.sentCommands.contains(0x37), "stress is not supported")
        XCTAssertFalse(link.sent.contains { $0.channel == .bigData }, "legacy sleep and heart rate stay on the command channel")
    }

    func testAPastDayStaysUnsyncedWhileAMetricFailed() async throws {
        var a = [UInt8](repeating: 0, count: 14)
        a[13] = 0b10_0000
        session.setCapabilities(RingCapabilities(blockA: a, blockB: [UInt8](repeating: 0, count: 14)))
        link.script(0x03, [RingProtocol.frame(0x03, [50, 0])])
        link.script(0x48, [RingProtocol.frame(0x48, [UInt8](repeating: 0, count: 14))])
        for _ in 0...1 {
            link.script(0x43, [RingProtocol.frame(0x43, [0xFF])])
            link.script(0x44, [RingProtocol.frame(0x44, [0xFF])])
            link.script(0x15, [RingProtocol.frame(0x15, [0xFF])])
        }
        // HRV (0x39) gets no reply and times out.

        let report = await sync.sync(days: 1)

        XCTAssertNotNil(report.failed["hrv"])
        XCTAssertFalse(report.updated.isEmpty)
        XCTAssertNil(store.day("2026-09-10").syncedAt, "yesterday is read again next sync")
    }

    func testSyncWithoutALinkSaysSoAndSendsNothing() async {
        link.isLinkReady = false
        let report = await sync.sync(days: 6)
        XCTAssertNotNil(report.failed["link"])
        XCTAssertTrue(link.sent.isEmpty)
    }

    func testAFinishedMeasurementIsRecordedForTheDay() async throws {
        link.script(0x69, [RingProtocol.frame(0x69, [1, 0, 70])])
        try await session.startMeasurement(.heartRate)
        _ = await session.awaitMeasurement(timeout: 1)

        let key = RingDates.dayKey(Date(), calendar: calendar)
        XCTAssertEqual(store.day(key).measurements.first?.value, 70)
        XCTAssertEqual(store.day(key).instantHeartRate.first?.value, 70)
    }
}

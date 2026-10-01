import XCTest
@testable import JarvisCopilot

/// Reading the X5's history stores page by page, from where the last sync left off.
@MainActor
final class X5SyncTests: XCTestCase {

    private var directory: URL!
    private var store: RingHistoryStore!
    private var defaults: UserDefaults!
    private var link: X5FakeLink!
    private var transport: RingTransport!
    private var sync: X5Sync!
    private var now = X5Bytes.date(2024, 8, 27, 12, 0)

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("X5SyncTests-\(UUID().uuidString)")
        store = RingHistoryStore(directory: directory)
        defaults = UserDefaults(suiteName: "X5SyncTests-\(UUID().uuidString)")
        transport = RingTransport(timing: .init(reply: 0.3, packetGap: 0.3, bigDataGap: 0.3, idle: 0.3))
        link = X5FakeLink()
        link.transport = transport
        transport.link = link
        let cursors = X5Cursors(deviceID: "ring-1", defaults: defaults)
        sync = X5Sync(transport: transport, store: { [unowned self] in self.store }, cursors: { cursors },
                      calendar: X5Bytes.utc, now: { [unowned self] in self.now })
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func readings(_ count: Int, hour: Int, idStart: Int = 0) -> [String] {
        (0..<count).map { X5Bytes.singleHR(id: idStart + $0, 2024, 8, 27, hour, $0, 30, bpm: 60 + $0 % 20) }
    }

    func testFirstSyncReadsFromTheNewestAndStoresEveryEntry() async {
        link.script(0x55, X5Bytes.notifications(readings(2, hour: 9), op: 0x55))
        _ = await sync.sync(kinds: [.singleHR])
        XCTAssertEqual(link.payloads(0x55), [[UInt8](repeating: 0, count: 14)])
        XCTAssertEqual(store.day("2024-08-27").manualHeartRate.count, 2)
        XCTAssertEqual(X5Cursors(deviceID: "ring-1", defaults: defaults).newest(.singleHR), X5Bytes.date(2024, 8, 27, 9, 1, 30))
    }

    func testTheNextSyncAsksOnlyForNewerEntriesInBCD() async {
        link.script(0x55, X5Bytes.notifications(readings(2, hour: 9), op: 0x55))
        _ = await sync.sync(kinds: [.singleHR])
        link.script(0x55, X5Bytes.notifications([], op: 0x55))
        _ = await sync.sync(kinds: [.singleHR])
        XCTAssertEqual(Array(link.payloads(0x55)[1].prefix(9)), [0x00, 0x00, 0x00, 0x24, 0x08, 0x27, 0x09, 0x01, 0x30])
    }

    func testAFullPageAsksForTheNextPage() async {
        link.script(0x55, X5Bytes.notifications(readings(50, hour: 8), op: 0x55))
        link.script(0x55, X5Bytes.notifications(readings(3, hour: 9, idStart: 50), op: 0x55))
        _ = await sync.sync(kinds: [.singleHR])
        XCTAssertEqual(link.sentCommands, [0x55, 0x55])
        XCTAssertEqual(link.payloads(0x55)[1].first, 0x02)
        XCTAssertEqual(store.day("2024-08-27").manualHeartRate.count, 53)
    }

    func testALinkDroppedAfterAPageResumesWithoutLosingOrDoublingEntries() async {
        link.script(0x55, X5Bytes.notifications(readings(50, hour: 8), op: 0x55))
        // No answer to "next page": the link went quiet.
        _ = await sync.sync(kinds: [.singleHR])
        XCTAssertEqual(store.day("2024-08-27").manualHeartRate.count, 50)
        XCTAssertEqual(X5Cursors(deviceID: "ring-1", defaults: defaults).newest(.singleHR), X5Bytes.date(2024, 8, 27, 8, 49, 30))

        link.script(0x55, X5Bytes.notifications(readings(3, hour: 9, idStart: 50), op: 0x55))
        _ = await sync.sync(kinds: [.singleHR])
        XCTAssertEqual(Array(link.payloads(0x55).last!.prefix(9)), [0x00, 0x00, 0x00, 0x24, 0x08, 0x27, 0x08, 0x49, 0x30])
        XCTAssertEqual(store.day("2024-08-27").manualHeartRate.count, 53)
    }

    func testAnEmptyAnswerChangesNothing() async {
        link.script(0x55, X5Bytes.notifications(readings(1, hour: 9), op: 0x55))
        _ = await sync.sync(kinds: [.singleHR])
        let revision = store.revision
        link.script(0x55, [X5Bytes.data("55 FF")])
        _ = await sync.sync(kinds: [.singleHR])
        XCTAssertEqual(store.revision, revision)
        XCTAssertEqual(X5Cursors(deviceID: "ring-1", defaults: defaults).newest(.singleHR), X5Bytes.date(2024, 8, 27, 9, 0, 30))
    }

    func testTheCursorSkipsAStepBlockThatIsStillFilling() async {
        now = X5Bytes.date(2024, 8, 27, 10, 5)
        let complete = "52 01 00 24 08 27 09 30 00 0A 00 0A 00 00 00 05 05 00 00 00 00 00 00 00 00"
        let filling = "52 02 00 24 08 27 10 00 00 05 00 05 00 00 00 05 00 00 00 00 00 00 00 00 00"
        link.script(0x52, X5Bytes.notifications([filling, complete], op: 0x52))
        _ = await sync.sync(kinds: [.stepBlocks])
        XCTAssertEqual(X5Cursors(deviceID: "ring-1", defaults: defaults).newest(.stepBlocks), X5Bytes.date(2024, 8, 27, 9, 30))
        XCTAssertEqual(store.day("2024-08-27").stepSlots.reduce(0) { $0 + $1.steps }, 15)
    }

    func testDayTotalsAreAlwaysReadInFull() async {
        link.script(0x51, [X5Bytes.data("51 00 24 08 27 2E 00 00 00 11 00 00 00 03 00 00 00 93 00 00 00 00 00 00 00 00 00 51 FF")])
        link.script(0x51, [X5Bytes.data("51 00 24 08 27 2F 00 00 00 11 00 00 00 03 00 00 00 93 00 00 00 00 00 00 00 00 00 51 FF")])
        _ = await sync.sync(kinds: [.dayTotals])
        _ = await sync.sync(kinds: [.dayTotals])
        XCTAssertEqual(link.payloads(0x51), [[UInt8](repeating: 0, count: 14), [UInt8](repeating: 0, count: 14)])
        XCTAssertEqual(store.day("2024-08-27").activity?.steps, 47)
    }

    func testWorkoutRecordsAreHandedOnNotStoredAsDays() async {
        var handed: [X5WorkoutRecord] = []
        sync.onWorkouts = { handed += $0 }
        link.script(0x5C, [X5Bytes.data("5C 00 00 24 09 03 10 36 47 00 8A 43 00 75 00 00 00 54 2A 0E 40 80 E3 6B 3D 5C FF")])
        _ = await sync.sync(kinds: [.workouts])
        XCTAssertEqual(handed.map(\.heartRate), [138])
    }
}

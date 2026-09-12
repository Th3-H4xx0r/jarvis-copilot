import XCTest
@testable import JarvisCopilot

@MainActor
final class FakeRingBackend: RingBackend {
    var deviceID: String? = "ring-test"
    var connectable = false
    private(set) var connectAttempts = 0
    private var connected = false
    let link = FakeRingLink()
    let session: RingSession
    let sync: RingSync
    let store: RingHistoryStore?

    var isConnected: Bool { connected }
    var connectionText: String { connected ? "Connected" : "Idle" }
    var displayName: String? = "R12_TEST"

    init(directory: URL) {
        session = RingSession(transport: makeRingTransport(link))
        let store = RingHistoryStore(directory: directory)
        self.store = store
        sync = RingSync(session: session, store: { store })
    }

    func ensureConnected(timeout: TimeInterval) async -> Bool {
        connectAttempts += 1
        connected = connectable
        return connectable
    }

    func waitForSetup(timeout: TimeInterval) async {}
    func releaseIfIdle() {}
}

@MainActor
final class ColmiR12Tests: XCTestCase {

    private var directory: URL!
    private var backend: FakeRingBackend!
    private var ring: ColmiR12!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ColmiR12Tests-\(UUID().uuidString)")
        backend = FakeRingBackend(directory: directory)
        ring = ColmiR12(backend: backend)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func knownCaps(stress: Bool = false) -> RingCapabilities {
        var a = [UInt8](repeating: 0, count: 14)
        if stress { a[13] = 0b1_0000 }
        return RingCapabilities(blockA: a, blockB: [UInt8](repeating: 0, count: 14))
    }

    private func assertBadArgument(_ skill: String, _ args: [String: Any],
                                   file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await ring.invoke(skill, args: args)
            XCTFail("expected a bad argument", file: file, line: line)
        } catch DeviceError.badArgument {
            // expected
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    func testTheCatalogueNamesEveryRingSkill() {
        XCTAssertEqual(ring.capabilities.map(\.name), [
            "ring_get_status", "ring_get_day", "ring_get_history", "ring_sync", "ring_measure", "ring_find",
            "ring_set_monitoring", "ring_set_touch_mode", "ring_set_goals", "ring_set_profile",
            "ring_set_preferences", "ring_power", "ring_get_log", "ring_raw_command",
            "ring_read_accelerometer", "ring_firmware_update",
        ])
        XCTAssertEqual(ColmiR12.model, "Colmi R12")
    }

    func testStatusWorksOfflineFromCachedState() async throws {
        backend.session.setCapabilities(knownCaps(stress: true))
        let status = try await ring.invoke("ring_get_status", args: [:])
        XCTAssertEqual(status["connected"] as? Bool, false)
        XCTAssertEqual(status["capabilities_known"] as? Bool, true)
        XCTAssertTrue((status["supported_metrics"] as? [String])?.contains("stress") ?? false)
        XCTAssertEqual(backend.connectAttempts, 0)
    }

    func testArgumentsAreValidatedBeforeConnecting() async {
        backend.session.setCapabilities(knownCaps())
        await assertBadArgument("ring_measure", ["metric": "blood_type"])
        await assertBadArgument("ring_measure", ["metric": "blood_pressure"])
        await assertBadArgument("ring_set_monitoring", ["metric": "heart_rate", "enabled": true, "interval_minutes": 500])
        await assertBadArgument("ring_set_monitoring", ["metric": "temperature", "enabled": true, "interval_minutes": 45])
        await assertBadArgument("ring_set_touch_mode", ["control": "touch", "mode": "teleport"])
        await assertBadArgument("ring_set_goals", [:])
        await assertBadArgument("ring_set_profile", ["sex": "other"])
        await assertBadArgument("ring_set_preferences", ["dnd": ["start": "25:00"]])
        await assertBadArgument("ring_power", ["action": "factory_reset"])
        await assertBadArgument("ring_raw_command", ["hex": "0102"])
        await assertBadArgument("ring_sync", ["days": 9])
        XCTAssertEqual(backend.connectAttempts, 0)
    }

    func testLiveSkillsFailCleanlyWhenTheRingIsAway() async {
        do {
            _ = try await ring.invoke("ring_find", args: [:])
            XCTFail("expected notConnected")
        } catch DeviceError.notConnected {
            XCTAssertEqual(backend.connectAttempts, 1)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testFindWritesTheFindCommandWhenConnected() async throws {
        backend.connectable = true
        let result = try await ring.invoke("ring_find", args: [:])
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(backend.link.payloads(0x50).first?.prefix(2), [0x55, 0xAA])
    }

    func testDayRejectsBadDatesAndHistoryClampsDays() async throws {
        await assertBadArgument("ring_get_day", ["date": "yesterday"])
        await assertBadArgument("ring_get_day", ["metrics": ["pulse"]])
        let history = try await ring.invoke("ring_get_history", args: ["days": 99])
        XCTAssertEqual((history["days"] as? [[String: Any]])?.count, 30)
    }

    func testTasbihAndCoupleAreNeverSent() async {
        await assertBadArgument("ring_set_touch_mode", ["control": "touch", "mode": "tasbih"])
        await assertBadArgument("ring_set_touch_mode", ["control": "gesture", "mode": "couple"])
        XCTAssertEqual(backend.connectAttempts, 0)
    }

    func testGoalCaloriesReadBackInKilocalories() async throws {
        backend.connectable = true
        backend.link.script(0x21, [RingProtocol.frame(0x21, [2])])
        backend.link.script(0x21, [RingProtocol.frame(0x21, [1, 0x10, 0x27, 0, 0x20, 0xA1, 0x07, 0x88, 0x13, 0, 60, 0, 0xE0, 0x01])])

        let result = try await ring.invoke("ring_set_goals", args: ["calories": 500])

        let goals = (result["settings"] as? [String: Any])?["goals"] as? [String: Any]
        XCTAssertEqual(goals?["kilocalories"] as? Int, 500)
        XCTAssertNil(goals?["calories"])
    }

    func testBloodPressureAndSugarHaveSummaryKeys() async throws {
        backend.store?.update(RingDates.dayKey(Date())) { day in
            day.mergeBloodPressure([RingBloodPressureReading(time: Date(), systolic: 118, diastolic: 76)])
            day.bloodSugar = RingMinMax(min: [0, 52] + [Int](repeating: 0, count: 22),
                                        max: [0, 61] + [Int](repeating: 0, count: 22))
        }
        let result = try await ring.invoke("ring_get_day", args: ["metrics": ["blood_pressure", "blood_sugar"]])
        let summary = result["summary"] as? [String: Any]
        XCTAssertEqual(summary?["blood_pressure_systolic"] as? Int, 118)
        XCTAssertEqual(summary?["blood_pressure_diastolic"] as? Int, 76)
        XCTAssertEqual(summary?["blood_sugar_min"] as? Int, 52)
        XCTAssertEqual(summary?["blood_sugar_max"] as? Int, 61)
        XCTAssertNil(summary?["steps"])
    }

    func testDayReturnsTheStoredSummaryFilteredByMetric() async throws {
        let today = RingDates.dayKey(Date())
        backend.store?.update(today) { day in
            day.activity = RingActivity(steps: 5000, runningSteps: 0, calories: 200_000, distanceMeters: 3500, sportMinutes: 20)
            day.heartRate = RingSeries(intervalMinutes: 5, values: [60, 70])
        }
        let result = try await ring.invoke("ring_get_day", args: ["metrics": ["activity"], "detail": true])
        let summary = result["summary"] as? [String: Any]
        XCTAssertEqual(summary?["steps"] as? Int, 5000)
        XCTAssertNil(summary?["heart_rate_avg"])
        let detail = result["detail"] as? [String: Any]
        XCTAssertNotNil(detail?["step_slots"])
        XCTAssertNil(detail?["heart_rate_series"])
    }
}

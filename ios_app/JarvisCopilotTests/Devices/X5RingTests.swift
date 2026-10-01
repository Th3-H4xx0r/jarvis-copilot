import XCTest
@testable import JarvisCopilot

/// A stand-in for the X5 manager: a real session over a scripted link, a temp store.
@MainActor
final class FakeX5Backend: X5Backend {
    var deviceID: String? = "x5-test-ring"
    var isConnected = false
    var connectionText: String { isConnected ? "Connected" : "Idle" }
    var displayName: String? = "X5_7A21"
    let session: X5Session
    let sync: X5Sync
    let store: RingHistoryStore?
    let inputs: RingInputStore?
    let link = X5FakeLink()
    private(set) var appliedInputMode = 0

    init(directory: URL, defaults: UserDefaults) {
        session = X5Session(defaults: defaults, timing: .init(reply: 0.3, packetGap: 0.3, bigDataGap: 0.3, idle: 0.3))
        link.transport = session.transport
        session.attach(link)
        let store = RingHistoryStore(directory: directory)
        self.store = store
        sync = X5Sync(transport: session.transport, store: { store }, cursors: { X5Cursors(deviceID: "x5-test-ring", defaults: defaults) })
        inputs = RingInputStore(deviceID: "x5-test-ring", defaults: defaults)
    }

    func ensureConnected(timeout: TimeInterval) async -> Bool { isConnected }
    func waitForSetup(timeout: TimeInterval) async {}
    func releaseIfIdle() {}
    func applyInputMode() async { appliedInputMode += 1 }
    var awakePolicy: X5AwakePolicy = .always
    func setAwakePolicy(_ policy: X5AwakePolicy) { awakePolicy = policy }
}

@MainActor
final class X5RingTests: XCTestCase {

    private var directory: URL!
    private var defaults: UserDefaults!
    private var backend: FakeX5Backend!
    private var ring: X5Ring!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("X5RingTests-\(UUID().uuidString)")
        defaults = UserDefaults(suiteName: "X5RingTests-\(UUID().uuidString)")
        backend = FakeX5Backend(directory: directory, defaults: defaults)
        ring = X5Ring(backend: backend)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testEverySkillIsAnX5Skill() {
        let names = Set(ring.capabilities.map(\.name))
        XCTAssertTrue(names.allSatisfy { $0.hasPrefix("x5_") })
        for expected in ["x5_get_status", "x5_get_day", "x5_get_health_day", "x5_get_history", "x5_sync", "x5_measure",
                         "x5_workout", "x5_set_monitoring", "x5_set_gesture_mode", "x5_set_gesture_action", "x5_find",
                         "x5_set_profile", "x5_restart", "x5_get_log"] {
            XCTAssertTrue(names.contains(expected), expected)
        }
    }

    func testStatusWorksWithTheRingAway() async throws {
        let status = try await ring.invoke("x5_get_status", args: [:])
        XCTAssertEqual(status["model"] as? String, "X5 smart ring")
        XCTAssertEqual(status["connected"] as? Bool, false)
        XCTAssertEqual(status["name"] as? String, "X5_7A21")
        XCTAssertNotNil(status["gesture_mode"])
        XCTAssertNotNil(status["touch_awake"])
    }

    func testHealthDayIsTheR12ShapeFiledAsX5() async throws {
        let key = RingDates.dayKey(Date())
        backend.store?.update(key) { day in
            day.activity = RingActivity(steps: 4200, runningSteps: 0, calories: 150_000, distanceMeters: 3100, sportMinutes: 25)
            day.syncedAt = Date()
        }
        let payload = try await ring.invoke("x5_get_health_day", args: ["date": key])
        XCTAssertEqual(payload["source"] as? String, "x5ring")
        let r12 = HealthDayPayload.make(backend.store!.day(key), key: key)
        XCTAssertEqual(Set(payload.keys), Set(r12.keys))
    }

    func testHistoryListsDays() async throws {
        let key = RingDates.dayKey(Date())
        backend.store?.update(key) { $0.manualHeartRate = [RingTimedValue(minute: 600, value: 64)] }
        let history = try await ring.invoke("x5_get_history", args: ["days": 3])
        XCTAssertEqual((history["days"] as? [[String: Any]])?.first?["date"] as? String, key)
    }

    func testGestureActionsAreSetOnTheSharedInputsStore() async throws {
        _ = try await ring.invoke("x5_set_gesture_action", args: ["gesture": "swipe_left", "prompt": "next song please"])
        XCTAssertEqual(backend.inputs?.action(for: .swipeLeft), .prompt("next song please"))
        _ = try await ring.invoke("x5_set_gesture_action", args: ["gesture": "double_tap", "skill": "play_pause"])
        XCTAssertEqual(backend.inputs?.action(for: .doubleTap), .skill(id: "play_pause", arguments: [:]))
        _ = try await ring.invoke("x5_set_gesture_action", args: ["gesture": "swipe_left", "none": true])
        XCTAssertEqual(backend.inputs?.action(for: .swipeLeft), RingAction.none)
        do {
            _ = try await ring.invoke("x5_set_gesture_action", args: ["gesture": "wiggle", "prompt": "x"])
            XCTFail("an unknown gesture must be refused")
        } catch {}
    }

    func testGestureModeAndAwakeTimeAreStoredAndApplied() async throws {
        _ = try await ring.invoke("x5_set_gesture_mode", args: ["mode": "music", "touch_awake": 5])
        XCTAssertEqual(backend.inputs?.wantedMode, .music)
        XCTAssertEqual(backend.awakePolicy, .minutes(5))
        _ = try await ring.invoke("x5_set_gesture_mode", args: ["mode": "jarvis", "touch_awake": "always"])
        XCTAssertEqual(backend.inputs?.wantedMode, .jarvis)
        XCTAssertEqual(backend.awakePolicy, .always)
        XCTAssertEqual(backend.appliedInputMode, 2)
    }

    func testDefaultInputsSeedOnlyAnUnconfiguredStore() {
        let store = RingInputStore(deviceID: "seed-test", defaults: defaults)
        X5Ring.seedDefaultInputs(store)
        XCTAssertEqual(store.action(for: .tap), .skill(id: "play_pause", arguments: [:]))
        XCTAssertEqual(store.action(for: .swipeRight), .skill(id: "next_track", arguments: [:]))
        store.set(.prompt("mine"), for: .tap)
        X5Ring.seedDefaultInputs(store)
        XCTAssertEqual(store.action(for: .tap), .prompt("mine"))
    }

    func testMeasureNeedsTheRing() async {
        do {
            _ = try await ring.invoke("x5_measure", args: ["type": "heart_rate"])
            XCTFail("a measurement with the ring away must fail")
        } catch {}
    }
}

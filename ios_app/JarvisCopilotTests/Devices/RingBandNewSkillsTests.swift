import XCTest
@testable import JarvisCopilot

/// Ring and band controls that used to live only on their settings screens, as tools.
@MainActor
final class RingBandNewSkillsTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("RingBandNewSkills-\(UUID().uuidString)")
        suite = "ring-band-new-skills-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
    }

    private func expectBadArgument(_ work: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await work(); XCTFail("expected a bad argument", file: file, line: line) }
        catch DeviceError.badArgument {} catch { XCTFail("unexpected \(error)", file: file, line: line) }
    }

    private func expectNotConnected(_ work: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await work(); XCTFail("expected not connected", file: file, line: line) }
        catch DeviceError.notConnected {} catch { XCTFail("unexpected \(error)", file: file, line: line) }
    }

    private func schema(_ device: any WearableDevice, _ name: String) throws -> [String: [String: Any]] {
        let capability = try XCTUnwrap(device.capabilities.first { $0.name == name }, name)
        XCTAssertTrue(capability.description.hasSuffix("."), name)
        XCTAssertFalse(capability.description.dropLast().contains(". "), "\(name): one sentence")
        return capability.inputSchema["properties"] as? [String: [String: Any]] ?? [:]
    }

    // MARK: R12

    /// `ColmiR12` and `X5Ring` hold their backends unowned; the test keeps them.
    private var ringBackend: FakeRingBackend!
    private var x5Backend: FakeX5Backend!

    private func r12() -> ColmiR12 {
        ringBackend = FakeRingBackend(directory: directory)
        return ColmiR12(backend: ringBackend)
    }

    func testTheR12OffersItsScreensGestureModes() throws {
        let ring = r12()
        XCTAssertEqual(try schema(ring, "ring_set_input_mode")["mode"]?["enum"] as? [String], ["jarvis", "music", "off"])
        _ = try schema(ring, "ring_sync_clock")
        _ = try schema(ring, "ring_reload_settings")
    }

    /// Same as the screen: the choice is kept for the ring, which takes it when it next connects.
    func testAGestureModeIsSavedEvenWithTheRingAway() async throws {
        let ring = r12()
        let inputs = RingInputStore(deviceID: "ring-test", defaults: defaults)
        ringBackend.inputs = inputs
        let out = try await ring.invoke("ring_set_input_mode", args: ["mode": "music"])
        XCTAssertEqual(inputs.mode, .music)
        XCTAssertEqual(out["mode"] as? String, "music")
        XCTAssertEqual(out["applied"] as? Bool, false)
    }

    func testAGestureModeTheR12LacksIsRefused() async {
        let ring = r12()
        let backend = ringBackend!
        backend.inputs = RingInputStore(deviceID: "ring-test", defaults: defaults)
        await expectBadArgument { _ = try await ring.invoke("ring_set_input_mode", args: ["mode": "camera"]) }
        await expectBadArgument { _ = try await ring.invoke("ring_set_input_mode", args: [:]) }
        XCTAssertNil(backend.inputs?.mode)
    }

    func testSyncClockWritesTheTimeOnALiveLink() async throws {
        let ring = r12()
        let backend = ringBackend!
        await expectNotConnected { _ = try await ring.invoke("ring_sync_clock", args: [:]) }
        backend.connectable = true
        backend.link.script(RingOp.setTime, [RingProtocol.frame(RingOp.setTime, [1])])
        let out = try await ring.invoke("ring_sync_clock", args: [:])
        XCTAssertEqual(out["ok"] as? Bool, true)
        XCTAssertEqual(backend.link.payloads(RingOp.setTime).count, 1, "nothing is written while the ring is away")
    }

    func testReloadSettingsNeedsTheRing() async {
        let ring = r12()
        await expectNotConnected { _ = try await ring.invoke("ring_reload_settings", args: [:]) }
    }

    // MARK: X5

    func testX5PowerOffRefusesWithoutConfirm() async throws {
        x5Backend = FakeX5Backend(directory: directory, defaults: defaults)
        let backend = x5Backend!
        let ring = X5Ring(backend: backend)
        XCTAssertEqual(try schema(ring, "x5_power_off")["confirm"]?["type"] as? String, "boolean")
        await expectBadArgument { _ = try await ring.invoke("x5_power_off", args: [:]) }
        await expectBadArgument { _ = try await ring.invoke("x5_power_off", args: ["confirm": false]) }
        await expectNotConnected { _ = try await ring.invoke("x5_power_off", args: ["confirm": true]) }
        XCTAssertTrue(backend.link.sentCommands.isEmpty)
    }

    // MARK: Band

    /// `BandDevice` holds its backend unowned; the test keeps it.
    private var bandBackend: UnitFakeBandBackend?

    private func band(scheduler: BandMeasureScheduler? = nil) -> BandDevice {
        let backend = UnitFakeBandBackend(scheduler: scheduler ?? BandMeasureScheduler(defaults: defaults))
        bandBackend = backend
        return BandDevice(backend: backend)
    }

    func testBandUnitsOfferTheScreensFourPickers() throws {
        let device = band()
        let props = try schema(device, "band_set_units")
        XCTAssertEqual(props["temperature"]?["enum"] as? [String], TemperatureUnit.allCases.map(\.rawValue))
        XCTAssertEqual(props["glucose"]?["enum"] as? [String], GlucoseUnit.allCases.map(\.rawValue))
        XCTAssertEqual(props["blood_fat"]?["enum"] as? [String], BloodFatUnit.allCases.map(\.rawValue))
        XCTAssertEqual(props["uric_acid"]?["enum"] as? [String], UricAcidUnit.allCases.map(\.rawValue))
    }

    /// The app's own choice (what every screen draws) is saved even with the band away.
    func testBandUnitsChangeTheAppsUnitsWithTheBandAway() async throws {
        let keys = ["temperatureUnit", GlucoseUnit.key, BloodFatUnit.key, UricAcidUnit.key]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { UserDefaults.standard.setValue(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        let device = band()
        let out = try await device.invoke("band_set_units", args: ["temperature": "fahrenheit", "glucose": "mgdL"])
        XCTAssertEqual(TemperatureUnit.current, .fahrenheit)
        XCTAssertEqual(GlucoseUnit.current, .mgdL)
        XCTAssertEqual(out["band_updated"] as? Bool, false)
        await expectBadArgument { _ = try await device.invoke("band_set_units", args: ["glucose": "mg"]) }
        await expectBadArgument { _ = try await device.invoke("band_set_units", args: [:]) }
    }

    func testNightTrackingKeepsTheWindow() async throws {
        let scheduler = BandMeasureScheduler(defaults: defaults)
        let device = band(scheduler: scheduler)
        let before = scheduler.plan
        _ = try await device.invoke("band_night_tracking", args: ["on": false])
        XCTAssertFalse(scheduler.plan.nightTracking)
        XCTAssertEqual(scheduler.plan.nightStart, before.nightStart)
        XCTAssertEqual(scheduler.plan.nightEnd, before.nightEnd)
        _ = try await device.invoke("band_night_tracking", args: ["on": true])
        XCTAssertTrue(scheduler.plan.nightTracking)
        await expectBadArgument { _ = try await device.invoke("band_night_tracking", args: [:]) }
    }

    func testTheMeasurementPlanOffersTheScreensChoices() throws {
        let device = band()
        let props = try schema(device, "band_set_measurement_plan")
        XCTAssertEqual(props["managed_by"]?["enum"] as? [String], ["band", "phone"])
        for name in BandMeasurePlan.types.map(\.name) + [BandMeasurePlan.hrv] {
            XCTAssertEqual(props[name]?["enum"] as? [Int], BandMeasurePlan.choices, name)
        }
        XCTAssertNotNil(props["night_start"])
        XCTAssertNotNil(props["night_end"])
    }

    func testTheMeasurementPlanSetsIntervalsAndTheNightWindow() async throws {
        let scheduler = BandMeasureScheduler(defaults: defaults)
        let device = band(scheduler: scheduler)
        _ = try await device.invoke("band_set_measurement_plan",
                                    args: ["heart_rate": 15, "hrv": 0, "night_start": "22:30", "night_end": "07:15"])
        XCTAssertEqual(scheduler.plan.interval("heart_rate"), 15)
        XCTAssertEqual(scheduler.plan.interval(BandMeasurePlan.hrv), 0)
        XCTAssertEqual(scheduler.plan.nightStart, 22 * 60 + 30)
        XCTAssertEqual(scheduler.plan.nightEnd, 7 * 60 + 15)
    }

    func testABadPlanChangesNothing() async {
        let scheduler = BandMeasureScheduler(defaults: defaults)
        let device = band(scheduler: scheduler)
        let before = scheduler.plan
        await expectBadArgument { _ = try await device.invoke("band_set_measurement_plan", args: ["heart_rate": 15, "spo2": 7]) }
        await expectBadArgument { _ = try await device.invoke("band_set_measurement_plan", args: ["night_start": "25:00"]) }
        await expectBadArgument { _ = try await device.invoke("band_set_measurement_plan", args: [:]) }
        XCTAssertEqual(scheduler.plan, before)
    }

    /// Handing measuring to the phone needs the band; nothing else in the plan changes without it.
    func testHandingMeasuringOverNeedsTheBand() async {
        let scheduler = BandMeasureScheduler(defaults: defaults)
        let device = band(scheduler: scheduler)
        let before = scheduler.plan
        await expectNotConnected {
            _ = try await device.invoke("band_set_measurement_plan", args: ["managed_by": "phone", "heart_rate": 15])
        }
        XCTAssertEqual(scheduler.plan, before)
    }
}

/// A band that never connects, with a measuring plan.
@MainActor
private final class UnitFakeBandBackend: BandBackend {
    let deviceID: String? = "band-test"
    let isConnected = false
    let connectionText = "Idle"
    let displayName: String? = "E910"
    let session = BandSession()
    let sync: BandSync
    let store: RingHistoryStore? = nil
    let workouts: RingWorkoutController? = nil
    let scheduler: BandMeasureScheduler?

    init(scheduler: BandMeasureScheduler) {
        self.scheduler = scheduler
        sync = BandSync(session: session, store: { nil }, defaults: UserDefaults(suiteName: "RingBandNewSkillsTests")!)
    }

    func ensureConnected(timeout: TimeInterval) async -> Bool { false }
    func waitForSetup(timeout: TimeInterval) async {}
    func releaseIfIdle() {}
}

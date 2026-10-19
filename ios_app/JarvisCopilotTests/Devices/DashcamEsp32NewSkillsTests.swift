import XCTest
@testable import JarvisCopilot

/// Dashcam and ESP32 controls that used to live only on their screens, as tools; and the scale
/// and ESP32 boards staying with Jarvis after a manual Disconnect.
@MainActor
final class DashcamEsp32NewSkillsTests: XCTestCase {
    private var device: DashcamDevice!
    private var sync: DashcamSync!
    private var server: FakeSyncServer!
    private var cam: FakeDashcam!
    private var onCamera = true
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        suite = "dashcam-esp32-new-skills-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        cam = FakeDashcam()
        server = FakeSyncServer()
        onCamera = true
        sync = DashcamSync()
        sync.defaults = defaults
        sync.server = server
        sync.cameraFactory = { [unowned self] _ in self.cam }
        sync.setupProvider = { DashcamSetup(ssid: "A4", family: .viidure, cameraID: "CAM") }
        sync.onCameraProvider = { [unowned self] in self.onCamera }
        device = DashcamDevice()
        device.sync = sync
        device.wifi = { [unowned self] in self.onCamera }
        device.setup = { DashcamSetup(ssid: "A4", family: .viidure, cameraID: "CAM", brand: "Affver", lenses: 2) }
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func expectError(_ work: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line,
                             _ check: (Error) -> Bool) async {
        do { try await work(); XCTFail("expected an error", file: file, line: line) }
        catch { XCTAssertTrue(check(error), "unexpected \(error)", file: file, line: line) }
    }

    // MARK: Dashcam

    func testTheDashcamOffersItsSettingsSwitchesAndClock() throws {
        let options = try XCTUnwrap(device.capabilities.first { $0.name == "dashcam_set_options" })
        let props = try XCTUnwrap(options.inputSchema["properties"] as? [String: [String: Any]])
        XCTAssertEqual(Set(props.keys), ["auto_download", "upload", "keep_on_phone", "lock_screen_progress"])
        XCTAssertTrue(props.values.allSatisfy { $0["type"] as? String == "boolean" })
        let clock = try XCTUnwrap(device.capabilities.first { $0.name == "dashcam_sync_clock" })
        for capability in [options, clock] {
            XCTAssertTrue(capability.description.hasSuffix("."), capability.name)
            XCTAssertFalse(capability.description.dropLast().contains(". "), "\(capability.name): one sentence")
        }
    }

    /// The upload and keep-on-phone switches edit the rules the server keeps, as Settings does.
    func testUploadAndKeepOnPhoneSaveTheRules() async throws {
        server.rules.upload = true
        server.rules.keepOnPhone = false
        let out = try await device.invoke("dashcam_set_options", args: ["upload": false, "keep_on_phone": true])
        XCTAssertEqual(server.rules.upload, false)
        XCTAssertEqual(server.rules.keepOnPhone, true)
        XCTAssertEqual(out["upload"] as? Bool, false)
        XCTAssertEqual(out["keep_on_phone"] as? Bool, true)
    }

    /// "Download everything" needs normal footage on, like the Settings switch does it.
    func testAutoDownloadTurnsNormalFootageOn() async throws {
        onCamera = false   // no sync pass
        server.rules.normal = .off
        sync.autoSync = false
        _ = try await device.invoke("dashcam_set_options", args: ["auto_download": true])
        XCTAssertTrue(sync.autoSync)
        XCTAssertTrue(defaults.bool(forKey: DashcamSync.autoSyncKey))
        XCTAssertEqual(server.rules.normal, .all)
        _ = try await device.invoke("dashcam_set_options", args: ["auto_download": false])
        XCTAssertFalse(sync.autoSync)
    }

    func testLockScreenProgressIsTheBeaconSwitch() async throws {
        let saved = UserDefaults.standard.object(forKey: DashcamSyncBeacon.enabledKey)
        defer { Self.restore(saved, forKey: DashcamSyncBeacon.enabledKey) }
        _ = try await device.invoke("dashcam_set_options", args: ["lock_screen_progress": false])
        XCTAssertFalse(DashcamSyncBeacon.enabled)
        XCTAssertEqual(server.rules, DashcamRules(), "nothing else changed")
    }

    func testBadOptionsChangeNothing() async {
        sync.autoSync = true
        await expectError({ _ = try await self.device.invoke("dashcam_set_options", args: ["auto_download": false, "upload": "no"]) }) {
            if case DeviceError.badArgument = $0 { return true }; return false
        }
        await expectError({ _ = try await self.device.invoke("dashcam_set_options", args: [:]) }) {
            if case DeviceError.badArgument = $0 { return true }; return false
        }
        XCTAssertTrue(sync.autoSync)
    }

    /// Settings' "Sync the camera's clock now" runs a pass, which sets the clock first.
    func testSyncClockSetsTheCamerasClock() async throws {
        onCamera = false
        await expectError({ _ = try await self.device.invoke("dashcam_sync_clock", args: [:]) }) { ($0 as? DashcamError) == .notConnected }
        onCamera = true
        _ = try await device.invoke("dashcam_sync_clock", args: [:])
        XCTAssertTrue(cam.calls.contains("time"))
    }

    private static func restore(_ value: Any?, forKey key: String) {
        if let value { UserDefaults.standard.setValue(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
    }

    // MARK: ESP32

    func testTheBoardOffersTheNotificationRelaySwitch() throws {
        let board = Esp32Board(manager: WearablesHub.shared.esp32)
        let relay = try XCTUnwrap(board.capabilities.first { $0.name == "esp32_notification_relay" })
        let props = try XCTUnwrap(relay.inputSchema["properties"] as? [String: [String: Any]])
        XCTAssertEqual(props["on"]?["type"] as? String, "boolean")
        XCTAssertEqual(relay.inputSchema["required"] as? [String], ["on"])
    }

    /// No board to reach: the skill says so instead of hanging.
    func testABoardThatCantBeReachedSaysSo() async {
        let esp32 = WearablesHub.shared.esp32
        guard esp32.state != .ready else { return }
        let board = Esp32Board(manager: esp32)
        let started = Date()
        await expectError({ _ = try await board.invoke("esp32_notification_relay", args: ["on": true]) }) {
            if case DeviceError.notConnected = $0 { return true }; return false
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 15)
    }

    // MARK: Disconnect keeps the device

    /// Registration follows Share with Jarvis, not the link: a Disconnect leaves the skills.
    private func assertStaysRegistered(kind: String, publish: () -> Void, disconnect: () -> Void) {
        let id = "\(kind)-fixture-\(UUID().uuidString)"
        let savedID = WearableIdentity.remembered(kind)
        WearableIdentity.remember(id, for: kind)
        defer {
            DeviceRegistry.shared.remove(deviceID: id)
            BridgeClient.forget(deviceID: id)
            if let savedID { WearableIdentity.remember(savedID, for: kind) } else { WearableIdentity.forget(kind) }
        }
        publish()
        XCTAssertNotNil(DeviceRegistry.shared.device(id: id), "\(kind) registered")
        disconnect()
        XCTAssertNotNil(DeviceRegistry.shared.device(id: id), "\(kind) still registered after Disconnect")
    }

    func testAManualDisconnectKeepsTheBoardRegistered() {
        let esp32 = WearablesHub.shared.esp32
        guard esp32.info == nil else { return }   // a real board is linked: its own id wins
        assertStaysRegistered(kind: WearableKeepAlive.esp32, publish: { esp32.publishRemembered() },
                              disconnect: { esp32.disconnect() })
    }

    func testAManualDisconnectKeepsTheScaleRegistered() {
        let scale = WearablesHub.shared.scale
        guard scale.connected == nil else { return }
        assertStaysRegistered(kind: WearableKeepAlive.scale, publish: { scale.publishRemembered() },
                              disconnect: { scale.disconnect() })
    }
}

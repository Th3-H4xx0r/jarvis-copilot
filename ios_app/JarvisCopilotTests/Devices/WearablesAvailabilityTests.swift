import XCTest
@testable import JarvisCopilot

/// A paired wearable has to stay addressable while its Bluetooth link is down.
///
/// Registration used to follow the connection: between app launch and the first
/// successful connect, `DeviceRegistry.allSkills()` carried no `bottle_*` at all,
/// so the agent had no failing tool to report — it had no tool. These cover the
/// three pieces that fix it: a device id that survives a drop, routing that sends
/// a skill to whoever actually implements it, and the status a card shows when the
/// device is simply not around.
@MainActor
final class WearablesAvailabilityTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "wearables-availability-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    // MARK: Sticky identity

    func testARememberedIdSurvivesTheLinkDropping() {
        WearableIdentity.remember("A4:C1:38:99:2D:08", for: WearableKeepAlive.bottle, defaults: defaults)
        XCTAssertEqual(WearableIdentity.remembered(WearableKeepAlive.bottle, defaults: defaults),
                       "A4:C1:38:99:2D:08")
    }

    func testPlaceholderIdsAreNeverRemembered() {
        // `VsitooS1Pro.deviceID` falls back to "unpaired" when nothing is connected.
        // Storing that would register the bottle under a fake identity, and then a
        // second time under its real MAC once the link came up.
        for placeholder in ["unpaired", "esf551", "esp32", "unknown", ""] {
            WearableIdentity.remember(placeholder, for: WearableKeepAlive.bottle, defaults: defaults)
            XCTAssertNil(WearableIdentity.remembered(WearableKeepAlive.bottle, defaults: defaults),
                         "'\(placeholder)' is not a real device id")
        }
    }

    func testEachKindKeepsItsOwnIdentity() {
        WearableIdentity.remember("mac-bottle", for: WearableKeepAlive.bottle, defaults: defaults)
        WearableIdentity.remember("uuid-scale", for: WearableKeepAlive.scale, defaults: defaults)
        XCTAssertEqual(WearableIdentity.remembered(WearableKeepAlive.bottle, defaults: defaults), "mac-bottle")
        XCTAssertEqual(WearableIdentity.remembered(WearableKeepAlive.scale, defaults: defaults), "uuid-scale")
        XCTAssertNil(WearableIdentity.remembered(WearableKeepAlive.esp32, defaults: defaults))
    }

    func testAnExistingInstallIsSeededFromItsSharedDevices() {
        // Upgrades have a shared bottle but no recorded id yet. Without seeding they'd
        // show nothing until the bottle reconnected once — the bug, again.
        WearableIdentity.seedFromSharedRecords([
            "A4:C1:38:99:2D:08": VsitooS1Pro.model,
            "1E2D-scale": Esf551Scale.model,
        ], defaults: defaults)
        XCTAssertEqual(WearableIdentity.remembered(WearableKeepAlive.bottle, defaults: defaults),
                       "A4:C1:38:99:2D:08")
        XCTAssertEqual(WearableIdentity.remembered(WearableKeepAlive.scale, defaults: defaults),
                       "1E2D-scale")
    }

    func testSeedingDoesNotOverwriteAnIdWeAlreadyLearned() {
        WearableIdentity.remember("live-mac", for: WearableKeepAlive.bottle, defaults: defaults)
        WearableIdentity.seedFromSharedRecords(["stale-id": VsitooS1Pro.model], defaults: defaults)
        XCTAssertEqual(WearableIdentity.remembered(WearableKeepAlive.bottle, defaults: defaults), "live-mac")
    }

    func testLastSeenIsRecordedSoAnAbsentCardStillHasSomethingToShow() {
        WearableIdentity.noteSeen(WearableKeepAlive.bottle, rssi: -57, defaults: defaults)
        XCTAssertEqual(WearableIdentity.lastRSSI(WearableKeepAlive.bottle, defaults: defaults), -57)
        XCTAssertNotNil(WearableIdentity.lastSeen(WearableKeepAlive.bottle, defaults: defaults))
    }

    func testAnOfflineBottleTakesItsRememberedIdNotThePlaceholder() {
        // `VsitooS1Pro.deviceID` reads the standard defaults directly, so this test
        // borrows the real identity and puts it back.
        let saved = WearableIdentity.remembered(WearableKeepAlive.bottle)
        defer {
            if let saved { WearableIdentity.remember(saved, for: WearableKeepAlive.bottle) }
            else { WearableIdentity.forget(WearableKeepAlive.bottle) }
        }

        WearableIdentity.remember("A4:C1:38:99:2D:08", for: WearableKeepAlive.bottle)
        // `VsitooS1Pro` holds its manager `unowned` — the manager owns the device, not
        // the other way round — so the manager has to outlive the assertions.
        let manager = BottleManager()
        withExtendedLifetime(manager) {
            let bottle = VsitooS1Pro(manager: manager)
            XCTAssertFalse(bottle.isConnected)
            XCTAssertEqual(bottle.deviceID, "A4:C1:38:99:2D:08",
                           "a disconnected bottle must keep the id it was paired under, "
                           + "not fall through to the \"unpaired\" placeholder")
            XCTAssertTrue(bottle.capabilities.contains { $0.name == "bottle_get_status" },
                          "the catalogue must survive the link being down — that is the bug")
        }
    }

    // MARK: Routing

    func testASkillGoesToTheDeviceThatImplementsItNotTheOneNamedByDeviceID() async throws {
        // `wearables_connect` names the bottle it wants to connect. Routing on
        // `device_id` alone sent it INTO the bottle, which has no such command.
        // Names nothing real: `DeviceRegistry` is a singleton the host app has already
        // populated, and reusing "wearables" / "wearables_connect" would collide with
        // the live hub instead of testing the routing rule.
        let hub = FakeDevice(id: "test-hub", commands: ["testhub_connect"])
        let bottle = FakeDevice(id: "test-bottle", commands: ["testbottle_status"])
        let registry = DeviceRegistry.shared
        registry.register(hub); registry.register(bottle)
        defer { registry.remove(deviceID: hub.deviceID); registry.remove(deviceID: bottle.deviceID) }

        let result = try await registry.invoke(skill: "testhub_connect",
                                               args: ["device_id": "test-bottle"])
        XCTAssertEqual(result["ran_on"] as? String, "test-hub")
    }

    func testDeviceIDStillPicksBetweenTwoDevicesOfferingTheSameSkill() async throws {
        let a = FakeDevice(id: "bottle-a", commands: ["testbottle_status"])
        let b = FakeDevice(id: "bottle-b", commands: ["testbottle_status"])
        let registry = DeviceRegistry.shared
        registry.register(a); registry.register(b)
        defer { registry.remove(deviceID: a.deviceID); registry.remove(deviceID: b.deviceID) }

        let result = try await registry.invoke(skill: "testbottle_status",
                                               args: ["device_id": "bottle-b"])
        XCTAssertEqual(result["ran_on"] as? String, "bottle-b")
    }

    func testADisconnectedDeviceStillAdvertisesItsSkills() {
        // The whole point: `isConnected == false` must not remove the catalogue.
        let bottle = FakeDevice(id: "A4:C1:38:99:2D:08",
                                commands: ["bottle_get_status", "bottle_sterilise"],
                                connected: false)
        let registry = DeviceRegistry.shared
        registry.register(bottle)
        defer { registry.remove(deviceID: bottle.deviceID) }

        let names = Set(registry.allSkills().compactMap { $0["name"] as? String })
        XCTAssertTrue(names.contains("bottle_get_status"))
        XCTAssertFalse(bottle.isConnected, "it advertises, but it must not claim to be connected")
    }

    // MARK: Card status

    func testAnAbsentDeviceReadsAsNotFoundRatherThanDisappearing() {
        let entry = WearableEntry(kind: WearableKeepAlive.bottle,
                                  deviceID: "A4:C1:38:99:2D:08",
                                  model: VsitooS1Pro.model,
                                  name: "VSITOO-S1-Pro",
                                  connected: false,
                                  rssi: nil,
                                  lastRSSI: -57,
                                  lastSeen: Date(timeIntervalSince1970: 1_757_000_000))
        XCTAssertEqual(entry.statusText, "Not found")
        XCTAssertFalse(entry.seenInLastScan)
        XCTAssertEqual(entry.json["last_rssi"] as? Int, -57)
        XCTAssertNotNil(entry.json["last_seen"])
    }

    func testASeenButUnconnectedDeviceShowsItsSignal() {
        let entry = WearableEntry(kind: WearableKeepAlive.bottle, deviceID: "id", model: "m",
                                  name: "n", connected: false, rssi: -61,
                                  lastRSSI: -61, lastSeen: nil)
        XCTAssertEqual(entry.statusText, "-61 dBm")
        XCTAssertTrue(entry.seenInLastScan)
    }

    func testAConnectedDeviceSaysSo() {
        let entry = WearableEntry(kind: WearableKeepAlive.bottle, deviceID: "id", model: "m",
                                  name: "n", connected: true, rssi: -40,
                                  lastRSSI: -40, lastSeen: nil)
        XCTAssertEqual(entry.statusText, "Connected")
    }
}

/// Stands in for a real wearable so routing and catalogue behaviour can be tested
/// without CoreBluetooth — `BottleManager` builds a `CBCentralManager` in its
/// initialiser, which a unit test has no business doing.
@MainActor
private final class FakeDevice: WearableDevice {
    static let model = "Fake"
    let deviceID: String
    let isConnected: Bool
    private let commands: [String]

    init(id: String, commands: [String], connected: Bool = true) {
        self.deviceID = id
        self.commands = commands
        self.isConnected = connected
    }

    var capabilities: [DeviceCapability] {
        commands.map { DeviceCapability(name: $0, description: "", inputSchema: DeviceCapability.schema()) }
    }

    func snapshot() -> [String: Any] { ["id": deviceID] }

    func invoke(_ name: String, args: [String: Any]) async throws -> [String: Any] {
        guard commands.contains(name) else { throw DeviceError.unknownCommand(name) }
        return ["ran_on": deviceID]
    }
}

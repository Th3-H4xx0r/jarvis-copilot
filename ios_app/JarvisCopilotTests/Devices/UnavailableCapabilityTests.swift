import XCTest
@testable import JarvisCopilot

/// The action picker lists tools a device has but can't run yet, greyed with a reason.
/// Jarvis's own tool list (`capabilities`) must not change because of it.
@MainActor
final class UnavailableCapabilityTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "unavailable-capability-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func glasses(experimental: Bool) -> InmoGo3Device {
        defaults.set(experimental, forKey: "inmo.experimentalControls")
        return InmoGo3Device(identity: "inmo-go3-fixture", defaults: defaults)
    }

    /// A device that doesn't override the requirement offers nothing greyed.
    func testDevicesListNothingUnavailableByDefault() {
        let device = PlainDevice()
        XCTAssertTrue(device.unavailableCapabilities.isEmpty)
    }

    func testExperimentalGlassesToolsAreUnavailableWhileTheSwitchIsOff() {
        let device = glasses(experimental: false)
        let unavailable = Dictionary(uniqueKeysWithValues: device.unavailableCapabilities.map { ($0.capability.name, $0.reason) })
        for name in ["glasses_camera_action", "glasses_device_setting", "glasses_remote_key"] {
            XCTAssertEqual(unavailable[name], "Turn on Experimental Controls in Glasses", name)
            XCTAssertFalse(device.capabilities.contains { $0.name == name }, "\(name) stays hidden from Jarvis")
        }
    }

    /// Setting a value needs the switch; only listing works, which is no use as a button.
    func testGlassesSettingsIsGreyedForThePickerButStaysForJarvis() {
        let device = glasses(experimental: false)
        XCTAssertEqual(device.unavailableCapabilities.first { $0.capability.name == "glasses_settings" }?.reason,
                       "Turn on Experimental Controls in Glasses")
        XCTAssertTrue(device.capabilities.contains { $0.name == "glasses_settings" })
    }

    func testNothingIsUnavailableOnceExperimentalControlsAreOn() {
        let device = glasses(experimental: true)
        XCTAssertTrue(device.unavailableCapabilities.isEmpty)
        for name in ["glasses_camera_action", "glasses_device_setting", "glasses_remote_key", "glasses_settings"] {
            XCTAssertTrue(device.capabilities.contains { $0.name == name }, name)
        }
    }

    /// Greyed entries carry the same schema the tool has when it is live, so a saved action
    /// keeps working once the switch is turned on.
    func testGreyedEntriesMatchTheLiveSchema() {
        let off = glasses(experimental: false).unavailableCapabilities
        let on = glasses(experimental: true).capabilities
        for entry in off {
            let live = on.first { $0.name == entry.capability.name }
            XCTAssertNotNil(live, entry.capability.name)
            XCTAssertTrue(NSDictionary(dictionary: entry.capability.inputSchema).isEqual(to: live?.inputSchema ?? [:]),
                          entry.capability.name)
        }
    }
}

@MainActor
private final class PlainDevice: WearableDevice {
    static let model = "Fixture"
    let deviceID = "fixture"
    var isConnected: Bool { false }
    var capabilities: [DeviceCapability] { [] }
    func snapshot() -> [String: Any] { [:] }
    func invoke(_ name: String, args: [String: Any]) async throws -> [String: Any] { [:] }
}

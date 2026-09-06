import XCTest
@testable import JarvisCopilot

/// The phone has to reach the server through the SAME plumbing the BLE
/// wearables use: `DeviceRegistry.allSkills()` (what `BridgeClient
/// .sendRegistration()` sends) and `DeviceRegistry.invoke(skill:args:)` (what
/// both the socket and the poll path dispatch through).
///
/// `DeviceRegistry` is a singleton owned by the existing app, so these tests use
/// the shared instance and take the phone back out afterwards rather than
/// changing its initialiser.
@MainActor
final class PhoneDeviceTests: XCTestCase {

    private var registry = SkillRegistry(store: MemoryKeyValueStore())
    private var mocks = MockedBoundaries()
    private var devices: DeviceRegistry { .shared }

    override func setUp() {
        super.setUp()
        let (boundaries, mocks) = PhoneSkills.Boundaries.mocked()
        self.mocks = mocks
        registry = SkillRegistry(store: MemoryKeyValueStore())
        registry.register(PhoneSkills.all(boundaries))
        devices.remove(deviceID: "phone")
        devices.register(PhoneDevice(registry: registry,
                                     runner: InvokeRunner(registry: registry,
                                                          lifecycle: AppLifecycle(),
                                                          pending: PendingActions(),
                                                          notifier: mocks.notifier)))
    }

    override func tearDown() {
        devices.remove(deviceID: "phone")
        super.tearDown()
    }

    func testPhoneSkillsAppearInAllSkills() {
        let names = Set(devices.allSkills().compactMap { $0["name"] as? String })
        XCTAssertTrue(names.contains("clipboard_read"))
        XCTAssertTrue(names.contains("phone_control"))
        XCTAssertTrue(names.contains("battery_level"))
    }

    func testAllSkillsCarriesTheBridgeWireShapeAndTheDeviceIdArgument() throws {
        let entry = try XCTUnwrap(devices.allSkills().first { $0["name"] as? String == "notify" })
        XCTAssertEqual(entry["description"] as? String, "Show a local notification on this device.")
        let schema = try XCTUnwrap(entry["input_schema"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        // DeviceRegistry namespaces every skill by argument rather than by name.
        XCTAssertNotNil(properties["device_id"])
        XCTAssertNotNil(properties["title"])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(entry))
    }

    func testADisabledSkillIsNotAdvertised() {
        registry.setEnabled(false, for: "record_audio")
        let names = Set(devices.allSkills().compactMap { $0["name"] as? String })
        XCTAssertFalse(names.contains("record_audio"))
        XCTAssertTrue(names.contains("clipboard_read"))
    }

    func testInvokeRoutesThroughTheRegistryToTheSkill() async throws {
        let result = try await devices.invoke(skill: "clipboard_write", args: ["text": "abc"])
        XCTAssertEqual(result["wrote"] as? Int, 3)
        XCTAssertEqual(mocks.clipboard.stored, "abc")
    }

    func testInvokeIgnoresTheDeviceIdArgument() async throws {
        let result = try await devices.invoke(skill: "clipboard_read", args: ["device_id": "phone"])
        XCTAssertEqual(result["text"] as? String, "hello")
    }

    func testADisabledSkillThrowsRatherThanRunning() async {
        registry.setEnabled(false, for: "clipboard_write")
        mocks.clipboard.stored = nil
        do {
            _ = try await devices.invoke(skill: "clipboard_write", args: ["text": "nope"])
            XCTFail("a disabled skill must not run")
        } catch {
            XCTAssertNil(mocks.clipboard.stored)
        }
    }

    func testAnUnknownSkillThrows() async {
        do {
            _ = try await devices.invoke(skill: "no_such_skill", args: ["device_id": "phone"])
            XCTFail("expected a throw")
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            XCTAssertTrue(text.contains("no_such_skill"), text)
        }
    }

    func testASkillThatFailsThrowsSoTheBridgeSendsAnErrorFrame() async {
        registry.register(AnySkill(name: "boom", description: "always fails") { _ in
            throw SkillError.failed("kaboom")
        })
        do {
            _ = try await devices.invoke(skill: "boom", args: [:])
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual((error as? LocalizedError)?.errorDescription, "kaboom")
        }
    }

    func testDescriptorAndSnapshotDescribeThePhone() throws {
        registry.setEnabled(false, for: "record_audio")
        let phone = try XCTUnwrap(devices.device(id: "phone"))

        let descriptor = phone.descriptor()
        XCTAssertEqual(descriptor["device_id"] as? String, "phone")
        XCTAssertEqual(descriptor["model"] as? String, "iPhone")
        XCTAssertEqual(descriptor["connected"] as? Bool, true)
        XCTAssertFalse((descriptor["commands"] as? [String] ?? []).contains("record_audio"))

        let snapshot = phone.snapshot()
        XCTAssertEqual(snapshot["disabled"] as? [String], ["record_audio"])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(snapshot))
    }

    func testRegisteringTwiceKeepsOnePhone() {
        devices.register(PhoneDevice(registry: registry))
        XCTAssertEqual(devices.devices.filter { $0.deviceID == "phone" }.count, 1)
    }

    func testInstallPutsThePhoneOnTheRegistry() {
        let (boundaries, _) = PhoneSkills.Boundaries.mocked()
        let fresh = SkillRegistry(store: MemoryKeyValueStore())
        devices.remove(deviceID: "phone")
        let phone = PhoneSkills.install(boundaries: boundaries, registry: fresh, devices: devices)
        XCTAssertEqual(devices.device(id: "phone")?.deviceID, phone.deviceID)
        XCTAssertEqual(fresh.all.count, PhoneSkills.all(boundaries).count)
        XCTAssertFalse(devices.allSkills().isEmpty)
    }
}

import XCTest
@testable import JarvisCopilot

@MainActor
final class InmoControlsTests: XCTestCase {
    func testTeleprompterUploadUsesOriginalMD5ThenAppendedLF() throws {
        let packet = try InmoWireCodec.decode(InmoCommand.teleprompterUpload(text: "GO3 TEST 123", title: "fixture"))
        let prompt = try XCTUnwrap(packet.firstField(12)).nested()
        let document = try XCTUnwrap(prompt.firstField(2)).nested()
        XCTAssertEqual(document.firstField(2)?.bytes, Data("GO3 TEST 123\n".utf8))
        XCTAssertEqual(document.firstField(3)?.bytes, Data("53c55740e6b54ddce1a2c656f73e89bd".utf8))
        let progress = try InmoWireCodec.decode(InmoCommand.teleprompterProgress(line: 4, percent: 50))
        let position = try XCTUnwrap(try progress.firstField(12)?.nested().firstField(6)).nested()
        XCTAssertEqual(position.firstField(2)?.fixed, UInt64(Float(50).bitPattern))
        let previous = try InmoWireCodec.decode(InmoCommand.teleprompterPage(next: false))
        XCTAssertEqual(try previous.firstField(12)?.nested().firstField(9)?.varint, 0)
    }
    func testExplicitUnknownTargetDoesNotFallback() async throws {
        let registry = DeviceRegistry.shared
        let device = InmoGo3Device.shared
        registry.register(device)
        defer { registry.remove(deviceID: device.deviceID) }
        do {
            _ = try await registry.invoke(skill: "glasses_status", args: ["device_id": "missing-device-fixture"])
            XCTFail("Must reject an explicit unknown target")
        } catch DeviceError.badArgument { }
    }
    func testExplicitIncompatibleTargetDoesNotFallback() async throws {
        let registry = DeviceRegistry.shared
        let device = InmoGo3Device.shared
        registry.register(device)
        defer { registry.remove(deviceID: device.deviceID) }
        do {
            _ = try await registry.invoke(skill: "wearables_list", args: ["device_id": device.deviceID])
            XCTFail("Must reject incompatible target")
        } catch DeviceError.badArgument { }
    }
    func testDisconnectedStatusPreservesUnknownBatteryAndCatalogue() async throws {
        let result = try await InmoGo3Device.shared.invoke("glasses_status", args: [:])
        XCTAssertNotNil(result["battery"])
        XCTAssertNotNil(result["capabilities"])
        XCTAssertTrue(InmoGo3Device.inventory.contains { $0.id == "restricted" && $0.skill == nil })
    }
}

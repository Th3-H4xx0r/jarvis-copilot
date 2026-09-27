import XCTest
@testable import JarvisCopilot

final class InmoAdvancedControlsTests: XCTestCase {
    func testLanguageDefaultPreservesEmptySubmessage() throws {
        let encoded = try InmoAdvancedControls.setting("language", value: "zh-CN")
        let message = try InmoWireCodec.decode(encoded)
        let settings = try XCTUnwrap(message.firstField(22)).nested()
        XCTAssertEqual(settings.firstField(1)?.varint, 11)
        XCTAssertEqual(settings.firstField(7)?.bytes, Data())
    }
    func testSystemTimeUsesMillisecondsAndSignedWholeHourTimezone() throws {
        let encoded = try InmoAdvancedControls.setting("sync_time", value: nil, date: Date(timeIntervalSince1970: 1_700_000_000), zone: XCTUnwrap(TimeZone(secondsFromGMT: -18000)))
        let message = try InmoWireCodec.decode(encoded)
        let settings = try XCTUnwrap(message.firstField(22)).nested()
        let time = try XCTUnwrap(settings.firstField(8)).nested()
        XCTAssertEqual(time.firstField(4)?.varint, 1_700_000_000_000)
        XCTAssertEqual(time.firstField(5)?.varint, UInt64(bitPattern: -5))
    }
    func testRejectUnsupportedNamesAndKeys() {
        XCTAssertThrowsError(try InmoAdvancedControls.setting("reset", value: "true"))
        XCTAssertThrowsError(try InmoAdvancedControls.setting("name", value: "bad\u{0}name"))
        XCTAssertThrowsError(try InmoAdvancedControls.setting("language", value: "unknown"))
        XCTAssertThrowsError(try InmoAdvancedControls.remoteKey("shutdown"))
    }
}

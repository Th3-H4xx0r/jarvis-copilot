import XCTest
@testable import Jarvis

/// Game Streaming on the Mac: whether the menu entry shows follows the
/// `game-streaming` row in `/api/power`.
final class GameStreamingMacTests: XCTestCase {

    func testPowerRowDrivesWhetherItIsOn() {
        XCTAssertEqual(GameStreaming.isOn(inPower:
            ["integrations": [["id": "game-streaming", "enabled": false]]]), false)
        XCTAssertEqual(GameStreaming.isOn(inPower:
            ["integrations": [["id": "game-streaming", "enabled": true]]]), true)
        // A row with no `enabled` key counts as on.
        XCTAssertEqual(GameStreaming.isOn(inPower:
            ["integrations": [["id": "game-streaming"]]]), true)
    }

    func testMissingRowIsUnknown() {
        // No game-streaming row (another server, or an older build): unknown, so the
        // caller keeps whatever it had (unknown counts as on).
        XCTAssertNil(GameStreaming.isOn(inPower:
            ["integrations": [["id": "holo-drop", "enabled": true]]]))
        XCTAssertNil(GameStreaming.isOn(inPower: [:]))
    }
}

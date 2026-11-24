import XCTest
@testable import JarvisCopilot

/// One server record per device (2026-11-24): the iPhone sends a stable machine_id when pairing and registering,
/// so a re-pair (or a reinstall) keeps its record instead of leaving a duplicate.
final class DeviceMachineIDTests: XCTestCase {
    func testStableAndShapedForTheServer() {
        let a = DeviceMachineID.current()
        let b = DeviceMachineID.current()
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.hasPrefix("ios-"))
        XCTAssertEqual(a.count, 36)
        XCTAssertTrue(a.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" })
    }
}

final class BridgeClientIdentityTests: XCTestCase {
    func testPairingClaimCarriesTheMachineID() {
        let body = BridgeClient.claimBody(code: " ABC-DEF ", name: "JarvisCopilot (iPhone)")
        XCTAssertEqual(body["code"] as? String, "ABC-DEF")
        XCTAssertEqual(body["machine_id"] as? String, DeviceMachineID.current())
    }

    func testRegisterFrameCarriesTheMachineID() {
        let msg = BridgeClient.registerMessage(skills: [], channels: [])
        XCTAssertEqual(msg["type"] as? String, "register")
        XCTAssertEqual(msg["machine_id"] as? String, DeviceMachineID.current())
    }
}

/// Live 2026-11-24: after a firmware update the board forgot its owner and the page only said "board rejected
/// the owner key". It now says what to do, and the app moves to Bluetooth to claim it again.
final class Esp32BoardResetTests: XCTestCase {
    func testABoardThatForgotItsOwnerSaysWhatToDo() {
        let text = Esp32Error.boardReset.errorDescription ?? ""
        XCTAssertTrue(text.contains("BOOT"))
        XCTAssertFalse(text.contains("rejected the owner key"))
    }
}

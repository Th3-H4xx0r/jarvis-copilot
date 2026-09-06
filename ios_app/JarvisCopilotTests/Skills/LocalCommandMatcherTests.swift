import XCTest
@testable import JarvisCopilot

/// The looser matcher the router still consults after `LocalExecutor` declines.
/// Cases taken from the behaviours `test/local_router_test.dart` relies on.
final class LocalCommandMatcherTests: XCTestCase {

    func testFlashlightOnAndOff() {
        XCTAssertEqual(LocalCommandMatcher.match("turn on the flashlight")?.name, "flashlight_on")
        XCTAssertEqual(LocalCommandMatcher.match("flashlight off")?.name, "flashlight_off")
    }

    func testVibrate() {
        XCTAssertEqual(LocalCommandMatcher.match("vibrate")?.name, "vibrate")
        XCTAssertEqual(LocalCommandMatcher.match("vibrate the phone")?.name, "vibrate")
    }

    func testVolumeBecomesAPhoneControlVerb() throws {
        let cmd = try XCTUnwrap(LocalCommandMatcher.match("set volume to 30"))
        XCTAssertEqual(cmd.name, "phone_control")
        XCTAssertEqual(cmd.args["action"] as? String, "volume")
        XCTAssertEqual(cmd.args["value"] as? String, "30")
        XCTAssertFalse(cmd.confirmation.isEmpty)
    }

    func testBrightnessBecomesAPhoneControlVerb() throws {
        let cmd = try XCTUnwrap(LocalCommandMatcher.match("set the brightness to 80"))
        XCTAssertEqual(cmd.args["action"] as? String, "brightness")
        XCTAssertEqual(cmd.args["value"] as? String, "80")
    }

    func testTextBecomesASendMessageVerb() throws {
        let cmd = try XCTUnwrap(LocalCommandMatcher.match("text Chahel hi"))
        XCTAssertEqual(cmd.name, "phone_control")
        XCTAssertEqual(cmd.args["action"] as? String, "send_message")
        XCTAssertEqual(cmd.args["to"] as? String, "Chahel")
        XCTAssertEqual(cmd.args["message"] as? String, "hi")
    }

    func testOpenAnApp() throws {
        let cmd = try XCTUnwrap(LocalCommandMatcher.match("open Spotify"))
        XCTAssertEqual(cmd.name, "open_app")
        XCTAssertEqual(cmd.args["name"] as? String, "Spotify")
    }

    func testCrossDeviceIsNotALocalCommand() {
        XCTAssertNil(LocalCommandMatcher.match("open Spotify on my Mac"))
        XCTAssertNil(LocalCommandMatcher.match("turn on the flashlight on my watch"))
    }

    func testNonAppOpenTargetsAreRejected() {
        XCTAssertNil(LocalCommandMatcher.match("open the door"))
        XCTAssertNil(LocalCommandMatcher.match("open settings"))
    }

    func testEmptyInput() {
        XCTAssertNil(LocalCommandMatcher.match("   "))
    }
}

import XCTest
@testable import JarvisCopilot

/// Port of `mobile_client/test/skills/phone_command_test.dart`.
final class PhoneCommandTests: XCTestCase {

    // MARK: buildPhoneCommand

    func testKeepsActionAndParamsDroppingNullsEmptiesAndInternalKeys() throws {
        let cmd = try PhoneCommand.build([
            "action": "open_url",
            "url": "spotify://",
            "value": NSNull(),
            "extra": "",
            "timeout_seconds": 30,   // internal, must be dropped
        ])
        XCTAssertEqual(cmd as NSDictionary, ["action": "open_url", "url": "spotify://"] as NSDictionary)
    }

    func testPreservesNonStringValuesLikeNumbersAndBools() throws {
        let cmd = try PhoneCommand.build(["action": "brightness", "value": 0.5])
        XCTAssertEqual(cmd as NSDictionary, ["action": "brightness", "value": 0.5] as NSDictionary)
    }

    func testThrowsWhenActionMissing() {
        XCTAssertThrowsError(try PhoneCommand.build(["value": 0.5]))
    }

    // MARK: rawValueForVerb

    func testBrightnessAndVolumeBecomeIntegerPercent() {
        XCTAssertEqual(PhoneCommand.rawValue(for: "brightness", command: ["value": 0.3]), "30")
        XCTAssertEqual(PhoneCommand.rawValue(for: "volume", command: ["value": "0.55"]), "55")
    }

    func testBrightnessAcceptsAPercentage() {
        XCTAssertEqual(PhoneCommand.rawValue(for: "brightness", command: ["value": 30]), "30")
        XCTAssertEqual(PhoneCommand.rawValue(for: "brightness", command: ["value": "80%"]), "80")
    }

    func testBrightnessClampsOutOfRangeValues() {
        XCTAssertEqual(PhoneCommand.rawValue(for: "brightness", command: ["value": 150]), "100")
        XCTAssertEqual(PhoneCommand.rawValue(for: "brightness", command: ["value": -2]), "0")
    }

    func testSendMessageJoinsRecipientAndBodyWithAPipe() {
        XCTAssertEqual(
            PhoneCommand.rawValue(for: "send_message", command: ["to": "Chahel", "message": "hi"]),
            "Chahel|hi")
    }

    func testTruthyFalsyWordsNormalizeToOneAndZero() {
        XCTAssertEqual(PhoneCommand.rawValue(for: "wifi", command: ["value": "on"]), "1")
        XCTAssertEqual(PhoneCommand.rawValue(for: "wifi", command: ["value": true]), "1")
        XCTAssertEqual(PhoneCommand.rawValue(for: "bluetooth", command: ["value": "off"]), "0")
        XCTAssertEqual(PhoneCommand.rawValue(for: "focus", command: ["value": 0]), "0")
    }

    func testOpenUrlPassesTheUrlThrough() {
        XCTAssertEqual(PhoneCommand.rawValue(for: "open_url", command: ["url": "https://x.com"]),
                       "https://x.com")
    }

    // MARK: phoneShortcutFor

    func testMapsEachSupportedVerbToItsShortcutAndRawInput() {
        XCTAssertEqual(PhoneCommand.shortcut(for: ["action": "brightness", "value": 0.3]),
                       PhoneShortcut(name: "JC Brightness", input: "30"))
        XCTAssertEqual(PhoneCommand.shortcut(for: ["action": "volume", "value": 0.5]),
                       PhoneShortcut(name: "JC Volume", input: "50"))
        XCTAssertEqual(PhoneCommand.shortcut(for: ["action": "wifi", "value": 0]),
                       PhoneShortcut(name: "JC WiFi", input: "0"))
        XCTAssertEqual(PhoneCommand.shortcut(for: ["action": "bluetooth", "value": "on"]),
                       PhoneShortcut(name: "JC Bluetooth", input: "1"))
        XCTAssertEqual(PhoneCommand.shortcut(for: ["action": "focus", "value": 1]),
                       PhoneShortcut(name: "JC Focus", input: "1"))
        XCTAssertEqual(PhoneCommand.shortcut(for: ["action": "open_url", "url": "x://"]),
                       PhoneShortcut(name: "JC Open URL", input: "x://"))
    }

    func testReturnsNilForAVerbWithNoShortcut() {
        XCTAssertNil(PhoneCommand.shortcut(for: ["action": "flashlight"]))
        XCTAssertNil(PhoneCommand.shortcut(for: ["action": "made_up"]))
    }

    // MARK: encodeQueryWithPercent20

    func testEncodesSpacesAsPercent20NeverPlus() {
        let qs = PhoneCommand.encodeQueryWithPercent20(["name": "JC Brightness"])
        XCTAssertEqual(qs, "name=JC%20Brightness")
        XCTAssertFalse(qs.contains("+"))
    }

    func testPercentEncodesValuesAndJoinsWithAmpersand() {
        // Ordering matters for a URL, so the encoder takes ordered pairs.
        let qs = PhoneCommand.encodeQueryWithPercent20(
            [("name", "JC Open URL"), ("text", "spotify://playlist")])
        XCTAssertTrue(qs.hasPrefix("name=JC%20Open%20URL&text="))
        XCTAssertTrue(qs.contains("%3A"))   // : encoded
        XCTAssertFalse(qs.contains("+"))
    }

    func testRoundTripsThroughURLPreservingPercent20() throws {
        let qs = PhoneCommand.encodeQueryWithPercent20(["name": "A B"])
        let url = try XCTUnwrap(URL(string: "shortcuts://x-callback-url/run-shortcut?\(qs)"))
        XCTAssertTrue(url.absoluteString.contains("A%20B"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first(where: { $0.name == "name" })?.value, "A B")
    }

    // MARK: nativeRedirectSkill

    func testOpenAppAlarmFlashlightRedirectToNativeSkills() {
        XCTAssertEqual(PhoneCommand.nativeRedirectSkill(["action": "open_app", "app": "Spotify"]),
                       "open_app")
        XCTAssertEqual(PhoneCommand.nativeRedirectSkill(["action": "alarm", "time": "7:00 AM"]),
                       "set_alarm")
        XCTAssertTrue(PhoneCommand.nativeRedirectSkill(["action": "flashlight"])?
            .contains("flashlight") ?? false)
    }

    func testGetBatteryLocationClipboardRedirectToNativeSkills() {
        XCTAssertEqual(PhoneCommand.nativeRedirectSkill(["action": "get", "what": "battery"]),
                       "battery_level")
        XCTAssertEqual(PhoneCommand.nativeRedirectSkill(["action": "get", "what": "location"]),
                       "get_location")
        XCTAssertEqual(PhoneCommand.nativeRedirectSkill(["action": "get", "what": "clipboard"]),
                       "clipboard_read")
    }

    func testShortcutVerbsReturnNilNoRedirect() {
        XCTAssertNil(PhoneCommand.nativeRedirectSkill(["action": "brightness", "value": 0.5]))
        XCTAssertNil(PhoneCommand.nativeRedirectSkill(["action": "wifi", "value": 0]))
        XCTAssertNil(PhoneCommand.nativeRedirectSkill(["action": "open_url", "url": "x://"]))
    }

    // MARK: parsePhoneOutput

    func testParsesAJSONObjectOutput() {
        XCTAssertEqual(PhoneCommand.parseOutput(#"{"ok":true,"result":"done"}"#) as NSDictionary,
                       ["ok": true, "result": "done"] as NSDictionary)
    }

    func testWrapsNonJSONTextAsARawResult() {
        XCTAssertEqual(PhoneCommand.parseOutput("73%") as NSDictionary,
                       ["ok": true, "result": "73%"] as NSDictionary)
    }

    func testEmptyOutputIsOkWithEmptyResult() {
        XCTAssertEqual(PhoneCommand.parseOutput("") as NSDictionary,
                       ["ok": true, "result": ""] as NSDictionary)
        XCTAssertEqual(PhoneCommand.parseOutput(nil) as NSDictionary,
                       ["ok": true, "result": ""] as NSDictionary)
    }

    func testAJSONNonObjectIsTreatedAsRawText() {
        XCTAssertEqual(PhoneCommand.parseOutput("[1,2]") as NSDictionary,
                       ["ok": true, "result": "[1,2]"] as NSDictionary)
    }
}

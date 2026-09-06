import XCTest
@testable import JarvisCopilot

/// Port of `mobile_client/test/services/local_executor_test.dart`.
///
/// The two skill sets mirror what a real build registers, so classification is
/// checked against a real device's capability set rather than an imaginary one.
final class LocalExecutorTests: XCTestCase {

    /// What a typical Android build registers (kept for parity with the Flutter
    /// suite: `set_volume`/`adjust_volume` exist there and exercise the branch
    /// iOS reaches through `phone_control`).
    private static let androidSkills: Set<String> = [
        "open_app", "open_url", "notify", "clipboard_read", "clipboard_write",
        "vibrate", "take_photo", "play_audio", "set_alarm", "flashlight_on",
        "flashlight_off", "set_volume", "adjust_volume", "send_sms", "make_call",
    ]

    /// iOS has no set_volume/adjust_volume — volume goes through phone_control.
    private static let iosSkills: Set<String> = [
        "open_app", "open_url", "notify", "clipboard_read", "clipboard_write",
        "vibrate", "take_photo", "play_audio", "set_alarm", "flashlight_on",
        "flashlight_off", "phone_control", "send_sms", "make_call",
    ]

    private func cls(_ text: String, skills: Set<String> = androidSkills) -> LocalDecision {
        LocalExecutor.classify(text, skills: skills)
    }

    private func plan(_ text: String, skills: Set<String>) -> LocalRun? {
        if case .run(let plan) = cls(text, skills: skills) { return plan }
        return nil
    }

    private func run(_ text: String, skills: Set<String> = androidSkills,
                     file: StaticString = #filePath, line: UInt = #line) throws -> LocalRun {
        try XCTUnwrap(plan(text, skills: skills),
                      "expected a local action for \"\(text)\", got \(cls(text, skills: skills))",
                      file: file, line: line)
    }

    private func escalates(_ text: String, skills: Set<String> = androidSkills,
                           file: StaticString = #filePath, line: UInt = #line) {
        let d = cls(text, skills: skills)
        if case .run(let plan) = d {
            XCTFail("expected \"\(text)\" to escalate, got \(plan.skill) \(plan.args)",
                    file: file, line: line)
        }
    }

    // MARK: device-local actions it runs without the server

    func testOpenAnAppByName() throws {
        let r = try run("open Chrome")
        XCTAssertEqual(r.skill, "open_app")
        XCTAssertEqual(r.args["app"] as? String, "Chrome")
        XCTAssertFalse(r.ack.isEmpty)
    }

    func testOpenAnAppWithFillerWordsAndAnAppSuffix() throws {
        let r = try run("hey, could you launch the Spotify app please")
        XCTAssertEqual(r.skill, "open_app")
        XCTAssertEqual(r.args["app"] as? String, "Spotify")
    }

    func testOpenABareDomainAsAURLNotAnApp() throws {
        let r = try run("open youtube.com")
        XCTAssertEqual(r.skill, "open_url")
        XCTAssertEqual(r.args["url"] as? String, "https://youtube.com")
    }

    func testOpenAnExplicitHttpsURL() throws {
        let r = try run("go to https://news.ycombinator.com")
        XCTAssertEqual(r.skill, "open_url")
        XCTAssertEqual(r.args["url"] as? String, "https://news.ycombinator.com")
    }

    func testFlashlightOn() throws {
        XCTAssertEqual(try run("turn on the flashlight").skill, "flashlight_on")
        XCTAssertEqual(try run("torch on").skill, "flashlight_on")
    }

    func testFlashlightOff() throws {
        XCTAssertEqual(try run("turn off the flashlight").skill, "flashlight_off")
    }

    func testSetAnAbsoluteVolumeLevelOnAndroid() throws {
        let r = try run("set the volume to 40")
        XCTAssertEqual(r.skill, "set_volume")
        XCTAssertEqual(r.args["level"] as? Int, 40)
    }

    func testSetAnAbsoluteVolumeLevelOnIOSGoesThroughPhoneControl() throws {
        let r = try run("set the volume to 40%", skills: Self.iosSkills)
        XCTAssertEqual(r.skill, "phone_control")
        XCTAssertEqual(r.args["action"] as? String, "volume")
        XCTAssertEqual(r.args["value"] as? String, "40")
    }

    func testRelativeVolumeChange() throws {
        let r = try run("turn the volume up")
        XCTAssertEqual(r.skill, "adjust_volume")
        XCTAssertEqual(r.args["direction"] as? String, "up")
    }

    func testVolumeLevelIsClampedTo0To100() throws {
        XCTAssertEqual(try run("set the volume to 480").args["level"] as? Int, 100)
    }

    func testVibrate() throws {
        XCTAssertEqual(try run("vibrate the phone").skill, "vibrate")
    }

    func testTimerInMinutesBecomesARelativeAlarm() throws {
        let r = try run("set a timer for 10 minutes")
        XCTAssertEqual(r.skill, "set_alarm")
        XCTAssertEqual(r.args["in_minutes"] as? Int, 10)
    }

    func testAnAlarmAtAClockTimeBecomesAnAbsoluteAlarm() throws {
        let r = try run("set an alarm for 7:30 am")
        XCTAssertEqual(r.skill, "set_alarm")
        XCTAssertEqual(r.args["hour"] as? Int, 7)
        XCTAssertEqual(r.args["minute"] as? Int, 30)
    }

    func testPmClockTimesAreConvertedTo24h() throws {
        let r = try run("wake me up at 6 pm")
        XCTAssertEqual(r.args["hour"] as? Int, 18)
        XCTAssertEqual(r.args["minute"] as? Int, 0)
    }

    func testWriteTheClipboard() throws {
        let r = try run("copy hello world to my clipboard")
        XCTAssertEqual(r.skill, "clipboard_write")
        XCTAssertEqual(r.args["text"] as? String, "hello world")
    }

    func testReadTheClipboard() throws {
        XCTAssertEqual(try run("what's on my clipboard").skill, "clipboard_read")
    }

    func testTakeAPhoto() throws {
        XCTAssertEqual(try run("take a photo").skill, "take_photo")
    }

    func testLocalNotification() throws {
        let r = try run("notify me that the pasta is ready")
        XCTAssertEqual(r.skill, "notify")
        XCTAssertEqual(r.args["title"] as? String, "the pasta is ready")
    }

    // MARK: everything else escalates to the server

    func testAnotherDevice() {
        escalates("open Chrome on my Mac")
        escalates("turn on the flashlight on my watch")
    }

    func testMessagesAndContacts() {
        escalates("text Mom I'm late")
        escalates("send Sarah a message saying hi")
        escalates("call Dad")
        escalates("what's Priya's number")
    }

    func testMoneyAndCommerce() {
        escalates("order me an Uber")
        escalates("pay Sam 20 dollars")
        escalates("buy the AirPods in my cart")
    }

    func testLiveDataIsNotADeviceAction() {
        escalates("what's the weather")
        escalates("give me the morning brief")
        escalates("what's on my calendar today")
    }

    func testAmbiguousTarget() {
        escalates("open it")
        escalates("open that thing")
        escalates("set the volume")
    }

    func testDestructiveVerbsNeverRunLocally() {
        escalates("delete my photos")
        escalates("erase the clipboard history")
    }

    func testASkillThisDeviceDoesNotHaveEscalates() {
        escalates("turn on the flashlight", skills: ["open_app", "vibrate"])
        escalates("set the volume to 40", skills: ["open_app"])
    }

    func testEmptyOrNoiseInputEscalates() {
        escalates("   ")
        escalates("uh")
    }

    func testPlayRequestsNeedTheServer() {
        escalates("play some jazz")
        escalates("play Bohemian Rhapsody on Spotify")
    }

    // MARK: negated commands never run locally

    func testNegatedFlashlight() { escalates("don't turn on the flashlight") }
    func testNegatedVibrate() { escalates("do not vibrate the phone") }
    func testNegatedAlarm() { escalates("never set an alarm for 7am") }
    func testNegatedPhoto() { escalates("stop taking photos") }
    func testNegatedClipboard() { escalates("no need to copy this to my clipboard") }
    func testNegatedVolume() { escalates("don't set the volume to 40") }

    // MARK: permission questions never run locally

    func testQuestionFlashlight() { escalates("should I turn on the flashlight?") }
    func testQuestionAlarm() { escalates("should I set an alarm for 7am?") }
    func testQuestionVibrate() { escalates("can I vibrate the phone?") }
    func testQuestionVolume() { escalates("do I need to set the volume to 40?") }
    func testQuestionPhoto() { escalates("is it ok to take a photo?") }
    func testQuestionClipboard() { escalates("am I supposed to copy this to my clipboard?") }

    // MARK: polite positive imperatives still run

    func testAQuestionPhrasedRequestThatIsActuallyACommandStillRuns() throws {
        XCTAssertEqual(try run("could you turn on the flashlight?").skill, "flashlight_on")
    }

    func testAPleasePrefixedAlarmStillRuns() throws {
        XCTAssertEqual(try run("please set an alarm for 7:30 am").skill, "set_alarm")
    }

    // MARK: third-party targets escalate

    func testAnAlarmForSomeoneElse() { escalates("set an alarm for Dad at 6am") }
    func testAFlashlightRequestForSomeoneElse() { escalates("turn on the flashlight for Mom") }

    func testATimerDurationIsNotAThirdPartyTarget() throws {
        XCTAssertEqual(try run("set a timer for 10 minutes").skill, "set_alarm")
    }

    func testForMeIsNotAThirdPartyTarget() throws {
        XCTAssertEqual(try run("open Chrome for me").skill, "open_app")
    }

    func testADayNameIsNotAThirdPartyTarget() throws {
        XCTAssertEqual(try run("set an alarm for 6am").skill, "set_alarm")
    }

    // MARK: safety invariants

    func testEverySkillItCanEmitIsOnTheLocalAllowList() throws {
        let utterances = [
            "open Chrome", "open youtube.com", "turn on the flashlight",
            "turn off the flashlight", "set the volume to 40", "turn the volume up",
            "vibrate the phone", "set a timer for 10 minutes",
            "copy hello to my clipboard", "what's on my clipboard", "take a photo",
            "notify me that dinner is ready",
        ]
        for u in utterances {
            if case .run(let plan) = LocalExecutor.classify(u, skills: Self.androidSkills) {
                XCTAssertTrue(isLocallyAllowed(plan.skill),
                              "\"\(u)\" produced non-allow-listed skill \(plan.skill)")
            }
        }
        // …and on iOS, where volume is a phone_control verb.
        let ios = try run("set the volume to 40", skills: Self.iosSkills)
        XCTAssertTrue(isLocallyAllowed(ios.skill))
    }

    func testTheAllowListExcludesOutwardAndDestructiveSkills() {
        for name in ["send_sms", "make_call", "share_text", "run_shortcut"] {
            XCTAssertFalse(isLocallyAllowed(name), name)
        }
    }

    func testASkipCarriesAReasonForTheEscalationLog() {
        guard case .skip(let reason) = cls("open Chrome on my Mac") else {
            return XCTFail("expected a skip")
        }
        XCTAssertFalse(reason.isEmpty)
    }

    // MARK: isOutwardOrDestructive segment matching

    func testOutwardDestructiveMatchesNameSegmentsNotSubstrings() {
        XCTAssertTrue(isOutwardOrDestructive("send_sms"))
        XCTAssertTrue(isOutwardOrDestructive("make_call"))
        XCTAssertTrue(isOutwardOrDestructive("share_text"))
        // "text_to_speech" / "type_text" contain "text" but no risky segment.
        XCTAssertFalse(isOutwardOrDestructive("text_to_speech"))
        XCTAssertFalse(isOutwardOrDestructive("type_text"))
    }
}

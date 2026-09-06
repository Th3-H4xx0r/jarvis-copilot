import XCTest
@testable import JarvisCopilot

/// Port of `mobile_client/test/services/foreground_defer_test.dart`.
@MainActor
final class ForegroundDeferTests: XCTestCase {

    // MARK: shouldDeferToForeground

    func testDefersAForegroundRequiredSkillOnlyWhenBackgrounded() {
        XCTAssertTrue(shouldDeferToForeground(requiresForeground: true, isForeground: false))
        XCTAssertFalse(shouldDeferToForeground(requiresForeground: true, isForeground: true))
    }

    func testNeverDefersANonForegroundSkill() {
        XCTAssertFalse(shouldDeferToForeground(requiresForeground: false, isForeground: false))
    }

    // MARK: actionBannerTitle

    func testOpenAppNamesTheApp() {
        XCTAssertEqual(actionBannerTitle("open_app", ["app": "Robinhood"]), "Open Robinhood")
    }

    func testOpenUrlUsesTheHost() {
        XCTAssertEqual(actionBannerTitle("open_url", ["url": "https://www.google.com/x"]),
                       "Open www.google.com")
    }

    func testPhoneControlBrightnessAsPercent() {
        XCTAssertEqual(actionBannerTitle("phone_control", ["action": "brightness", "value": 0.3]),
                       "Set brightness 30%")
    }

    func testPhoneControlWifiOff() {
        XCTAssertEqual(actionBannerTitle("phone_control", ["action": "wifi", "value": 0]),
                       "Turn off Wi-Fi")
    }

    func testUnknownSkillFallsBack() {
        XCTAssertEqual(actionBannerTitle("mystery", [:]), "JARVIS action ready")
    }

    func testClampsAPathologicalTitle() {
        XCTAssertTrue(actionBannerTitle("open_app", ["app": String(repeating: "Z", count: 400)]).count <= 100)
    }

    func testRunShortcutAndSmsTitles() {
        XCTAssertEqual(actionBannerTitle("run_shortcut", ["name": "JC Focus"]), "Run JC Focus")
        XCTAssertEqual(actionBannerTitle("run_shortcut", [:]), "Run shortcut")
        XCTAssertEqual(actionBannerTitle("create_shortcut", [:]), "Add a Shortcut")
    }

    /// The banner is the only thing between a backgrounded invoke and a text
    /// being composed, so it has to name the recipient and quote the body.
    func testAnOutwardTextNamesTheRecipientAndQuotesTheBody() {
        XCTAssertEqual(actionBannerTitle("send_sms", ["number": "Mom", "message": "on my way"]),
                       "Text Mom: on my way")
        XCTAssertEqual(actionBannerTitle("send_sms", ["number": "Mom"]), "Text Mom")
        XCTAssertEqual(actionBannerTitle("send_sms", [:]), "Text someone")
    }

    func testPhoneControlSendMessageGetsTheSameTitle() {
        XCTAssertEqual(
            actionBannerTitle("phone_control",
                              ["action": "send_message", "to": "Chahel", "message": "hi"]),
            "Text Chahel: hi")
        // `recipient`/`body` are the aliases the server sometimes sends.
        XCTAssertEqual(
            actionBannerTitle("phone_control",
                              ["action": "send_message", "recipient": "Dad", "body": "call me"]),
            "Text Dad: call me")
    }

    func testPhoneControlOpenURLUsesTheHostToo() {
        XCTAssertEqual(
            actionBannerTitle("phone_control", ["action": "open_url", "url": "https://bank.com/x"]),
            "Open bank.com")
        XCTAssertEqual(actionBannerTitle("phone_control", ["action": "made_up"]), "Phone control")
    }

    func testALongBodyIsTruncatedNotDropped() {
        let title = actionBannerTitle(
            "send_sms", ["number": "Mom", "message": String(repeating: "x", count: 300)])
        XCTAssertTrue(title.hasPrefix("Text Mom: "))
        XCTAssertTrue(title.hasSuffix("…"), title)
        XCTAssertTrue(title.count <= 100)
    }

    func testTheRemainingForegroundSkillsGetTheirOwnTitles() {
        XCTAssertEqual(actionBannerTitle("make_call", ["number": "+15105550100"]),
                       "Call +15105550100")
        XCTAssertEqual(actionBannerTitle("make_call", [:]), "Place a call")
        XCTAssertEqual(actionBannerTitle("share_text", ["text": "a link"]), "Share: a link")
        XCTAssertEqual(actionBannerTitle("share_text", ["text": "x", "subject": "Invoice"]),
                       "Share: Invoice")
        XCTAssertEqual(actionBannerTitle("share_image", ["caption": "the receipt"]),
                       "Share image: the receipt")
        XCTAssertEqual(actionBannerTitle("share_image", [:]), "Share an image")
        XCTAssertEqual(actionBannerTitle("take_photo", [:]), "Take a photo")
        XCTAssertEqual(actionBannerTitle("pick_photo", [:]), "Pick a photo")
    }

    // MARK: PendingActions

    func testAddThenDrainFreshReturnsAndClears() {
        let p = PendingActions()
        p.add("open_app", ["app": "X"])
        p.add("open_url", ["url": "y://"])
        XCTAssertEqual(p.count, 2)
        let out = p.drainFresh()
        XCTAssertEqual(out.map(\.skill), ["open_app", "open_url"])
        XCTAssertTrue(p.isEmpty)
    }

    func testDropsActionsOlderThanTheTTL() {
        let p = PendingActions()
        let old = Date(timeIntervalSince1970: 1_577_836_800)   // 2020-01-01
        p.add("open_app", ["app": "stale"], at: old)
        p.add("open_app", ["app": "fresh"])
        let out = p.drainFresh()
        XCTAssertEqual(out.compactMap { $0.args["app"] as? String }, ["fresh"])
    }

    func testOnChangedFiresAfterEveryAdd() {
        let p = PendingActions()
        var fired = 0
        p.onChanged = { fired += 1 }
        p.add("open_app", ["app": "X"])
        p.add("open_app", ["app": "Y"])
        XCTAssertEqual(fired, 2)
    }
}

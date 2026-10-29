import XCTest
@testable import JarvisCopilot

/// The "Update available" card: what counts as an offer, and when the card may show.
final class AppUpdateCenterTests: XCTestCase {

    private let answer: [String: Any] = [
        "available": true, "build": 263021514, "version": "1.0",
        "notes": "\n• Paste images\n• Faster PDFs\n",
        "install_url": "itms-services://?action=download-manifest&url=https%3A%2F%2Fx.dev%2Fota%2Fm%2Ft.plist",
    ]

    func testANewerBuildIsAnOffer() throws {
        let offer = try XCTUnwrap(AppUpdateOffer.decode(answer, installed: 1))
        XCTAssertEqual(offer.build, 263021514)
        XCTAssertEqual(offer.notes, "• Paste images\n• Faster PDFs")
        XCTAssertEqual(offer.installURL.scheme, "itms-services")
    }

    func testTheSameOrAnOlderBuildIsNoOffer() {
        XCTAssertNil(AppUpdateOffer.decode(answer, installed: 263021514))
        XCTAssertNil(AppUpdateOffer.decode(answer, installed: 263021600))
        var off = answer; off["available"] = false
        XCTAssertNil(AppUpdateOffer.decode(off, installed: 1))
        var noLink = answer; noLink["install_url"] = ""
        XCTAssertNil(AppUpdateOffer.decode(noLink, installed: 1))
    }

    func testTheUpdateBannerIsRecognisedInsideTheServerEnvelope() {
        // What `alert_phones(data=...)` sends: the data rides under "jarviscopilot".
        let push: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "Jarvis update ready", "body": "Paste images"]],
            "jarviscopilot": ["kind": "app_update", "platform": "ios", "build": 263021514],
        ]
        XCTAssertTrue(AppUpdateRules.isUpdatePush(push))
        XCTAssertFalse(AppUpdateRules.isUpdatePush(["kind": "app_update"]))
        XCTAssertFalse(AppUpdateRules.isUpdatePush(["jarviscopilot": ["kind": "permission"]]))
    }

    func testTheCardWaitsForTheForegroundAndForVoiceAndRespectsLater() throws {
        let offer = try XCTUnwrap(AppUpdateOffer.decode(answer, installed: 1))
        XCTAssertTrue(AppUpdateRules.shouldShow(offer, foreground: true, voiceActive: false, laterBuild: nil))
        XCTAssertFalse(AppUpdateRules.shouldShow(offer, foreground: false, voiceActive: false, laterBuild: nil))
        XCTAssertFalse(AppUpdateRules.shouldShow(offer, foreground: true, voiceActive: true, laterBuild: nil))
        XCTAssertFalse(AppUpdateRules.shouldShow(offer, foreground: true, voiceActive: false, laterBuild: offer.build))
        // Later on an older offer doesn't hide a newer one.
        XCTAssertTrue(AppUpdateRules.shouldShow(offer, foreground: true, voiceActive: false, laterBuild: 5))
        XCTAssertFalse(AppUpdateRules.shouldShow(nil, foreground: true, voiceActive: false, laterBuild: nil))
    }
}

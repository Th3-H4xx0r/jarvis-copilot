import XCTest
@testable import JarvisCopilot

final class WearableNotificationTests: XCTestCase {
    private let payload: [String: Any] = ["type": "device_notify", "channel": "glasses",
                                         "notify_title": "Mom", "notify_body": "Dinner at 7?", "notify_app": "iMessage"]

    func testDecodesActualAPNsEnvelope() throws {
        let card = try XCTUnwrap(WearableNotification.decode(["jarviscopilot": payload]))
        XCTAssertEqual(card.channel, "glasses")
        XCTAssertEqual(card.title, "Mom")
        XCTAssertEqual(card.body, "Dinner at 7?")
        XCTAssertEqual(card.app, "iMessage")
    }

    func testFlatPayloadAndLegacyStillRoute() throws {
        XCTAssertEqual(WearableNotification.decode(payload)?.app, "iMessage")
        let card = try XCTUnwrap(WearableNotification.decode(["type": "glasses_notify", "glasses_body": "Hello"]))
        XCTAssertEqual(card.channel, "glasses")
        XCTAssertEqual(card.body, "Hello")
        XCTAssertNil(card.app)
    }

    func testOtherChannelsStayOnTheirOwnChannel() {
        XCTAssertEqual(WearableNotification.decode(["jarviscopilot": ["type": "device_notify", "channel": "ring", "notify_body": "Done"]])?.channel, "ring")
        XCTAssertNil(WearableNotification.decode(["aps": ["alert": "Unrelated"]]))
        XCTAssertNil(WearableNotification.decode(["type": "device_notify", "channel": "glasses"]))
    }

    /// Code Master's banners (Allow / Deny, Finished) carry the glasses card
    /// themselves: one push, and the app it wakes puts the card on the lens.
    func testABannerCanCarryAGlassesCard() throws {
        let push: [String: Any] = ["type": "coding_permission", "request_id": "r1", "notify_channel": "glasses",
                                   "notify_title": "Claude has a question", "notify_body": "app: Which database?"]
        let card = try XCTUnwrap(WearableNotification.decode(["aps": ["alert": ["title": "x"]], "jarviscopilot": push]))
        XCTAssertEqual(card.channel, "glasses")
        XCTAssertEqual(card.title, "Claude has a question")
        XCTAssertEqual(card.body, "app: Which database?")
        XCTAssertNil(card.app)
        XCTAssertNil(WearableNotification.decode(["jarviscopilot": ["type": "coding_permission", "request_id": "r1"]]),
                     "a banner without a card isn't one")
        XCTAssertEqual(WearableNotification.decode(["jarviscopilot": ["type": "coding", "notify_channel": "glasses",
                                                                      "notify_title": "Claude Code finished"]])?.title,
                       "Claude Code finished")
    }

    func testANCSMatchesTruncatedTextButNotUnrelatedBanner() {
        XCTAssertTrue(WearableNotification.matchesRelay(title: "Mom", body: "Dinner at 7?", relayTitle: "Mo", relayBody: "Dinner"))
        XCTAssertFalse(WearableNotification.matchesRelay(title: "Dad", body: "Dinner at 7?", relayTitle: "Mom", relayBody: "Dinner"))
        XCTAssertFalse(WearableNotification.matchesRelay(title: "Mom", body: "Different", relayTitle: "Mom", relayBody: "Dinner"))
        XCTAssertFalse(WearableNotification.matchesRelay(title: "Mom", body: "Dinner", relayTitle: "", relayBody: ""))
    }
}

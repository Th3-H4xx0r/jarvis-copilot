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

    func testANCSMatchesTruncatedTextButNotUnrelatedBanner() {
        XCTAssertTrue(WearableNotification.matchesRelay(title: "Mom", body: "Dinner at 7?", relayTitle: "Mo", relayBody: "Dinner"))
        XCTAssertFalse(WearableNotification.matchesRelay(title: "Dad", body: "Dinner at 7?", relayTitle: "Mom", relayBody: "Dinner"))
        XCTAssertFalse(WearableNotification.matchesRelay(title: "Mom", body: "Different", relayTitle: "Mom", relayBody: "Dinner"))
        XCTAssertFalse(WearableNotification.matchesRelay(title: "Mom", body: "Dinner", relayTitle: "", relayBody: ""))
    }
}

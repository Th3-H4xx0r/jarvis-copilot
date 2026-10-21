import SwiftUI
import XCTest
@testable import JarvisCopilot

/// The memory deck on the Chat home: its text helpers, and PNGs of how it looks
/// (written to $RING_SNAPSHOT_DIR, default /tmp/ringshots) for review.
@MainActor
final class IMessageFactCardRenderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_600_000)

    private func fact(_ text: String, from chat: String, minutesAgo: Double, hoursLeft: Double) -> IMessageFact {
        IMessageFact(id: UUID().uuidString, chatName: chat, fact: text,
                     at: now.timeIntervalSince1970 - minutesAgo * 60,
                     expiresAt: now.timeIntervalSince1970 + hoursLeft * 3600)
    }

    func testNamesInitialsAndCountdown() {
        XCTAssertEqual(IMessageFactCard.initials("Sam Lee"), "SL")
        XCTAssertEqual(IMessageFactCard.initials("Sreeja"), "S")
        XCTAssertTrue(IMessageFactCard.isGroup("the group “F1”"))
        XCTAssertEqual(IMessageFactCard.displayName("the group “F1”"), "F1")
        let card = IMessageFactCard(fact: fact("x", from: "Sam Lee", minutesAgo: 5, hoursLeft: 17.6),
                                    onDecide: { _ in }, now: now)
        XCTAssertEqual(card.savesIn, "Saves in 18 h")
        XCTAssertTrue(card.sourceText.hasPrefix("Sam Lee · "))
        let soon = IMessageFactCard(fact: fact("x", from: "Sam", minutesAgo: 1, hoursLeft: 0.5),
                                    onDecide: { _ in }, now: now)
        XCTAssertEqual(soon.savesIn, "Saves in 30 min")
    }

    func testRenderDeck() throws {
        let size = CGSize(width: 393, height: 320)
        let single = IMessageFactDeck(
            front: fact("Sam Lee's new address is 1420 Oak Street, Apt 3B, Oakland CA 94612",
                        from: "Sam Lee", minutesAgo: 12, hoursLeft: 23.8),
            behind: 0, now: now, onDecide: { _ in })
        try RenderHarness.write(single.padding(16).frame(maxHeight: .infinity, alignment: .top),
                                size: size, name: "imessage-fact-single")

        let stacked = IMessageFactDeck(
            front: fact("Sreeja's birthday is on March 14th; she wants a film camera",
                        from: "Sreeja", minutesAgo: 45, hoursLeft: 18),
            behind: 2, now: now, onDecide: { _ in })
        try RenderHarness.write(stacked.padding(16).frame(maxHeight: .infinity, alignment: .top),
                                size: size, name: "imessage-fact-stacked")

        let group = IMessageFactDeck(
            front: fact("The F1 group is watching the Austin GP together on Sunday at 2 PM at Omar's place",
                        from: "the group “F1”", minutesAgo: 200, hoursLeft: 4),
            behind: 1, now: now, onDecide: { _ in })
        try RenderHarness.write(group.padding(16).frame(maxHeight: .infinity, alignment: .top),
                                size: size, name: "imessage-fact-group")
    }
}

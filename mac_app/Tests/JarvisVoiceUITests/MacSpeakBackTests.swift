import XCTest
@testable import JarvisVoiceUI

/// A hand-off's answer read out on the Mac after the push-to-talk turn that
/// asked has ended.
///
/// Pranav (2026-10-16): "whenever it reroutes to another agent to complete it,
/// it should basically start speaking again once it gets a response from the agent."
final class MacSpeakBackTests: XCTestCase {

    func testAnAnswerIsSaidSentenceBySentenceWithoutMarkdown() {
        let chunks = MacSpeakBack.spokenChunks("**The lease wins.** It's $40 a month cheaper than the dealer's best offer.")
        XCTAssertEqual(chunks.joined(separator: " "),
                       "The lease wins. It's $40 a month cheaper than the dealer's best offer.")
        XCTAssertFalse(chunks.joined().contains("*"))
    }

    func testATableIsReadAsItsRowsNotItsRules() {
        let chunks = MacSpeakBack.spokenChunks("""
        | Offer | Monthly |
        |---|:---:|
        | Dealer | $412 |
        | Lease | $372 |
        """)
        let said = chunks.joined(separator: " ")
        XCTAssertTrue(said.contains("Dealer, $412."), said)
        XCTAssertFalse(said.contains("|"), said)
        XCTAssertFalse(said.contains("---"), said)
    }

    func testALongAnswerStopsAtASentenceAndPointsAtTheRest() {
        let sentence = "This sentence is here to make the answer long enough to cut."
        let chunks = MacSpeakBack.spokenChunks(Array(repeating: sentence, count: 40).joined(separator: " "))
        XCTAssertEqual(chunks.last, MacSpeakBack.restNote)
        let said = chunks.dropLast().joined(separator: " ")
        XCTAssertLessThanOrEqual(said.count, MacSpeakBack.spokenLimit + chunks.count)
        XCTAssertTrue(said.hasSuffix("cut."))
    }

    func testAShortAnswerIsSaidWhole() {
        XCTAssertEqual(MacSpeakBack.spokenChunks("Done."), ["Done."])
        XCTAssertEqual(MacSpeakBack.spokenChunks("   "), [])
    }
}

import SwiftUI
import XCTest
@testable import JarvisCopilot

/// The pure decisions behind the Voice screen (`VoicePagePresentation.swift`) —
/// boundaries and exhaustiveness, so re-ordering the tabs or adding a state can't
/// silently freeze the orb or leave a caption blank.
@MainActor
final class VoicePagePresentationTests: XCTestCase {

    // MARK: - voiceActiveSegment

    private func segments(_ chunks: [String]) -> [VoiceSegment] {
        var reply = VoiceReply()
        for chunk in chunks { reply.append(chunk) }
        return reply.segments
    }

    func testNothingSpokenYetPointsAtTheFirstSegment() {
        let segs = segments(["One two three.", "Four five."])
        XCTAssertEqual(voiceActiveSegment(segs, spokenWords: 0), 0)
    }

    func testNoSegmentsAtAllHasNoActiveSegment() {
        XCTAssertEqual(voiceActiveSegment([], spokenWords: 0), -1)
        XCTAssertEqual(voiceActiveSegment([], spokenWords: 9), -1)
    }

    /// The exact boundary: a segment becomes active the moment its FIRST word is
    /// reached, not once the previous one has fully finished.
    func testASegmentBecomesActiveOnItsFirstWord() {
        let segs = segments(["One two three.", "Four five.", "Six."])
        XCTAssertEqual(segs.map(\.wordOffset), [0, 3, 5])

        XCTAssertEqual(voiceActiveSegment(segs, spokenWords: 1), 0)
        XCTAssertEqual(voiceActiveSegment(segs, spokenWords: 3), 0, "word 3 is segment 1's first")
        XCTAssertEqual(voiceActiveSegment(segs, spokenWords: 4), 1)
        XCTAssertEqual(voiceActiveSegment(segs, spokenWords: 5), 1)
        XCTAssertEqual(voiceActiveSegment(segs, spokenWords: 6), 2)
        XCTAssertEqual(voiceActiveSegment(segs, spokenWords: 99), 2, "never past the last segment")
    }

    func testASingleSegmentIsAlwaysTheActiveOne() {
        let segs = segments(["Only one."])
        XCTAssertEqual(voiceActiveSegment(segs, spokenWords: 0), 0)
        XCTAssertEqual(voiceActiveSegment(segs, spokenWords: 2), 0)
    }

    // MARK: - Colours

    /// `connecting` deliberately shares `thinking`'s colour — the island has no
    /// distinct art for it and flipping between the two reads as a glitch.
    func testConnectingBorrowsTheThinkingColourAndNothingElseCollides() {
        XCTAssertEqual(voiceStateColor(.connecting), voiceStateColor(.thinking))
        let distinct = Set(VoiceState.allCases.map { "\(voiceStateColor($0))" })
        XCTAssertEqual(distinct.count, VoiceState.allCases.count - 1)
    }
}

import XCTest
@testable import JarvisCopilot

/// The streaming reply + karaoke highlight model.
final class VoiceReplyTests: XCTestCase {

    func testAppendJoinsSegmentsAsThePlainReply() {
        var reply = VoiceReply()
        XCTAssertEqual(reply.append("The weather is **clear**."), 0)
        XCTAssertEqual(reply.append("Winds are light."), 1)
        XCTAssertEqual(reply.text, "The weather is clear.\n\nWinds are light.")
        XCTAssertEqual(reply.totalWords, 7)
        XCTAssertEqual(reply.segments[1].wordOffset, 4)
        XCTAssertFalse(reply.isEmpty)
    }

    func testAChunkThatStripsToNothingAddsNoSegment() {
        var reply = VoiceReply()
        XCTAssertNil(reply.append("```\ncode\n```"))
        XCTAssertNil(reply.append("   "))
        XCTAssertTrue(reply.segments.isEmpty)
        XCTAssertTrue(reply.isEmpty)
    }

    func testResetClearsEverything() {
        var reply = VoiceReply()
        reply.append("one two")
        reply.clipStarted(tag: 0, durationMs: 100)
        reply.reset()
        XCTAssertTrue(reply.segments.isEmpty)
        XCTAssertEqual(reply.text, "")
        XCTAssertEqual(reply.spokenWords, 0)
        XCTAssertEqual(reply.totalWords, 0)
        XCTAssertEqual(reply.currentSegment, -1)
    }

    // MARK: - Pairing clips to segments

    func testClaimSegmentTagTakesTheMostRecentUnpairedSegment() {
        var reply = VoiceReply()
        reply.append("first")
        reply.append("second")
        XCTAssertEqual(reply.claimSegmentTag(), 1)
        XCTAssertEqual(reply.claimSegmentTag(), 0)
        XCTAssertNil(reply.claimSegmentTag(), "nothing left to pair")
    }

    func testClaimSegmentTagSkipsSegmentsThatAlreadyHaveAudio() {
        var reply = VoiceReply()
        reply.append("first")
        reply.append("second")
        reply.assignAudio(to: 1)
        XCTAssertEqual(reply.claimSegmentTag(), 0)
    }

    func testAssignAudioIgnoresAnOutOfRangeIndex() {
        var reply = VoiceReply()
        reply.append("only")
        reply.assignAudio(to: 9) // must not trap
        XCTAssertEqual(reply.claimSegmentTag(), 0)
    }

    // MARK: - Highlight

    func testTheHighlightAdvancesWithThePlaybackPosition() {
        var reply = VoiceReply()
        reply.append("one two three four")
        reply.clipStarted(tag: 0, durationMs: 1000)
        XCTAssertEqual(reply.spokenWords, 0, "nothing is spoken until audio plays")
        reply.clipPosition(tag: 0, positionMs: 500)
        let mid = reply.spokenWords
        XCTAssertGreaterThan(mid, 1)
        XCTAssertLessThan(mid, 4)
        reply.clipPosition(tag: 0, positionMs: 1000)
        XCTAssertEqual(reply.spokenWords, 4)
    }

    func testStartingALaterSegmentMarksEveryEarlierOneFullySpoken() {
        var reply = VoiceReply()
        reply.append("one two")     // 2 words
        reply.append("three four")  // 2 words
        reply.append("five")        // 1 word
        reply.clipStarted(tag: 2, durationMs: 500)
        XCTAssertEqual(reply.spokenWords, 4, "the first two segments are behind us")
    }

    func testARepeatClipStartIsAScheduleCorrectionNotARestart() {
        var reply = VoiceReply()
        reply.append("one two three four five")
        // MP3: an estimate first, then the real decoded duration.
        reply.clipStarted(tag: 0, durationMs: 0)
        reply.clipPosition(tag: 0, positionMs: 900)
        let progress = reply.spokenWords
        XCTAssertGreaterThan(progress, 1)

        reply.clipStarted(tag: 0, durationMs: 2000) // correction for the SAME segment
        XCTAssertEqual(reply.spokenWords, progress, "progress is kept, not reset to 0")
    }

    func testAnUnknownDurationFallsBackToAWordCountEstimate() {
        var reply = VoiceReply()
        reply.append("one two three")
        reply.clipStarted(tag: 0, durationMs: 0)
        XCTAssertEqual(reply.segments[0].durMs, 900, "~200 wpm: 300 ms per word")
    }

    func testAStalePositionFromTheOutgoingClipIsIgnored() {
        var reply = VoiceReply()
        reply.append("one two")
        reply.append("three four five")
        reply.clipStarted(tag: 0, durationMs: 400)
        reply.clipStarted(tag: 1, durationMs: 600)
        // A trailing event from the previous clip would read near ITS end and,
        // because `advance` is monotonic, would jump this segment to its last word.
        reply.clipPosition(tag: 1, positionMs: 5000)
        XCTAssertEqual(reply.spokenWords, 2, "segment 0's two words, and none of this one yet")
    }

    func testPositionsForANonCurrentSegmentAreIgnored() {
        var reply = VoiceReply()
        reply.append("one two")
        reply.append("three four")
        reply.clipStarted(tag: 1, durationMs: 500)
        let before = reply.spokenWords
        reply.clipPosition(tag: 0, positionMs: 400)
        reply.clipPosition(tag: nil, positionMs: 400)
        reply.clipPosition(tag: 9, positionMs: 400)
        XCTAssertEqual(reply.spokenWords, before)
    }

    func testClipStartWithANilOrOutOfRangeTagIsIgnored() {
        var reply = VoiceReply()
        reply.append("one two")
        reply.clipStarted(tag: nil, durationMs: 500)
        reply.clipStarted(tag: 7, durationMs: 500)
        XCTAssertEqual(reply.currentSegment, -1)
        XCTAssertEqual(reply.spokenWords, 0)
    }

    func testFinalizeLightsUpTheWordsThePositionStreamNeverReached() {
        var reply = VoiceReply()
        reply.append("one two three")
        reply.append("four five")
        reply.clipStarted(tag: 0, durationMs: 1000)
        XCTAssertLessThan(reply.spokenWords, 5)
        reply.finalizeSpoken()
        XCTAssertEqual(reply.spokenWords, 5)
        XCTAssertEqual(reply.spokenWords, reply.totalWords)
    }

    func testAStreamedSegmentsGrowingTotalKeepsTheHighlightMoving() {
        var reply = VoiceReply()
        reply.append("one two three four five six")
        // The streaming path re-announces the segment with a bigger running
        // total as more of the sentence arrives.
        reply.clipStarted(tag: 0, durationMs: 300)
        reply.clipPosition(tag: 0, positionMs: 100)
        let afterFirstChunk = reply.spokenWords
        XCTAssertGreaterThan(afterFirstChunk, 0)
        XCTAssertLessThan(afterFirstChunk, 6)

        reply.clipStarted(tag: 0, durationMs: 1200)
        reply.clipPosition(tag: 0, positionMs: 1200)
        XCTAssertEqual(reply.spokenWords, 6)
        XCTAssertGreaterThanOrEqual(reply.spokenWords, afterFirstChunk,
                                    "the highlight never steps backward")
    }
}

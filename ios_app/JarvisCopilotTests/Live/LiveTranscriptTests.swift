import XCTest
@testable import JarvisCopilot

/// Transcript assembly and the speaker relabelling rules of design §5.2.
final class LiveTranscriptTests: XCTestCase {

    private func segment(_ seq: Int, speaker: String? = nil, name: String? = nil,
                         state: LiveLabelState = .provisional,
                         text: String? = nil) -> LiveSegment {
        LiveSegment(seq: seq, startMs: seq * 1000, endMs: seq * 1000 + 800,
                    speakerID: speaker, speakerName: name, speakerConf: nil,
                    labelState: state, text: text ?? "row \(seq)", lang: "en-US")
    }

    // MARK: - Ordering

    func testRowsAreOrderedBySeq() {
        var transcript = LiveTranscript()
        transcript.upsert(segment(1))
        transcript.upsert(segment(2))
        transcript.upsert(insight(3))
        XCTAssertEqual(transcript.rows.map(\.seq), [1, 2, 3])
    }

    /// A row the server re-sends once its speaker is resolved must REPLACE the
    /// provisional one. Appending would make the conversation say everything twice.
    func testResendingARowReplacesItRatherThanDuplicatingIt() {
        var transcript = LiveTranscript()
        transcript.upsert(segment(5, speaker: nil, state: .provisional))
        transcript.upsert(segment(5, speaker: "sp-2", name: "Ada", state: .confirmed))

        XCTAssertEqual(transcript.segments.count, 1)
        XCTAssertEqual(transcript.segments[0].speakerID, "sp-2")
        XCTAssertEqual(transcript.segments[0].labelState, .confirmed)
    }

    /// A late frame is placed, not appended — appended it would read as having been
    /// said last.
    func testALateFrameIsPlacedInOrderNotAppended() {
        var transcript = LiveTranscript()
        transcript.upsert(segment(1))
        transcript.upsert(segment(9))
        transcript.upsert(segment(4))
        XCTAssertEqual(transcript.segments.map(\.seq), [1, 4, 9])
    }

    func testALateInsightIsAlsoPlacedInOrder() {
        var transcript = LiveTranscript()
        transcript.upsert(insight(2))
        transcript.upsert(insight(8))
        transcript.upsert(insight(5))
        XCTAssertEqual(transcript.insights.map(\.seq), [2, 5, 8])
    }

    func testCursorIsTheHighestSeqAcrossBothStreams() {
        var transcript = LiveTranscript()
        XCTAssertEqual(transcript.cursor, 0)
        transcript.upsert(segment(4))
        XCTAssertEqual(transcript.cursor, 4)
        transcript.upsert(insight(11))
        XCTAssertEqual(transcript.cursor, 11, "an insight advances the resume cursor too")
    }

    // MARK: - Rename

    func testRenameRelabelsEveryRowFromThatVoice() {
        var transcript = LiveTranscript()
        transcript.upsert(segment(1, speaker: "sp-1"))
        transcript.upsert(segment(2, speaker: "sp-2"))
        transcript.upsert(segment(3, speaker: "sp-1"))

        transcript.apply(LiveSpeakerEvent(op: .rename, speakerID: "sp-1", name: "Ada"))

        XCTAssertEqual(transcript.segments.map(\.speakerName), ["Ada", nil, "Ada"])
    }

    func testRenameWithNoSpeakerIDChangesNothing() {
        var transcript = LiveTranscript()
        transcript.upsert(segment(1, speaker: "sp-1", name: "Ada"))
        transcript.apply(LiveSpeakerEvent(op: .rename, speakerID: "", name: "Nobody"))
        XCTAssertEqual(transcript.segments[0].speakerName, "Ada")
    }

    // MARK: - Confirm

    func testConfirmSettlesTheLabelOnEveryRowFromThatVoice() {
        var transcript = LiveTranscript()
        transcript.upsert(segment(1, speaker: "sp-1", state: .provisional))
        transcript.upsert(segment(2, speaker: "sp-9", state: .provisional))

        transcript.apply(LiveSpeakerEvent(op: .confirm, speakerID: "sp-1"))

        XCTAssertEqual(transcript.segments[0].labelState, .confirmed)
        XCTAssertEqual(transcript.segments[1].labelState, .provisional,
                       "confirming one voice must not settle another")
    }

    func testConfirmCanCarryANameToo() {
        var transcript = LiveTranscript()
        transcript.upsert(segment(1, speaker: "sp-1"))
        transcript.apply(LiveSpeakerEvent(op: .confirm, speakerID: "sp-1", name: "Grace"))
        XCTAssertEqual(transcript.segments[0].speakerName, "Grace")
        XCTAssertEqual(transcript.segments[0].labelState, .confirmed)
    }

    // MARK: - Merge (the retroactive one)

    /// The behaviour design §5.2 is explicit about: a merge rewrites rows the user
    /// has ALREADY scrolled past, not just the ones that arrive afterwards.
    func testMergeRetroactivelyRelabelsRowsAlreadyRendered() {
        var transcript = LiveTranscript()
        transcript.upsert(segment(1, speaker: "sp-4"))
        transcript.upsert(segment(2, speaker: "sp-1", name: "Ada"))
        transcript.upsert(segment(3, speaker: "sp-4"))
        transcript.upsert(segment(4, speaker: "sp-7"))

        transcript.apply(LiveSpeakerEvent(op: .merge, speakerID: "sp-1", mergedFrom: ["sp-4"]))

        XCTAssertEqual(transcript.segments.map(\.speakerID), ["sp-1", "sp-1", "sp-1", "sp-7"])
        XCTAssertEqual(transcript.segments.map(\.speakerName), ["Ada", "Ada", "Ada", nil],
                       "the folded rows must inherit the surviving voice's name")
    }

    /// A merge carrying no name of its own must not blank the rows it absorbs.
    func testAMergeWithoutANameInheritsTheSurvivorsExistingName() {
        var transcript = LiveTranscript()
        transcript.upsert(segment(1, speaker: "sp-1", name: "Grace"))
        transcript.upsert(segment(2, speaker: "sp-5"))

        transcript.apply(LiveSpeakerEvent(op: .merge, speakerID: "sp-1",
                                          name: nil, mergedFrom: ["sp-5"]))

        XCTAssertEqual(transcript.segments[1].speakerName, "Grace")
    }

    func testMergeCanFoldSeveralIdsAtOnce() {
        var transcript = LiveTranscript()
        transcript.upsert(segment(1, speaker: "sp-2"))
        transcript.upsert(segment(2, speaker: "sp-3"))
        transcript.upsert(segment(3, speaker: "sp-1"))

        transcript.apply(LiveSpeakerEvent(op: .merge, speakerID: "sp-1",
                                          name: "Alan", mergedFrom: ["sp-2", "sp-3"]))

        XCTAssertEqual(Set(transcript.segments.compactMap(\.speakerID)), ["sp-1"])
        XCTAssertEqual(transcript.segments.map(\.speakerName), ["Alan", "Alan", "Alan"])
    }

    func testAMergeWithNothingToFoldChangesNothing() {
        var transcript = LiveTranscript()
        transcript.upsert(segment(1, speaker: "sp-1", name: "Ada"))
        let before = transcript
        transcript.apply(LiveSpeakerEvent(op: .merge, speakerID: "sp-1", mergedFrom: []))
        XCTAssertEqual(transcript, before)
    }

    /// Rows with no resolved speaker must not be swept into a merge.
    func testMergeLeavesUnlabelledRowsAlone() {
        var transcript = LiveTranscript()
        transcript.upsert(segment(1, speaker: nil))
        transcript.apply(LiveSpeakerEvent(op: .merge, speakerID: "sp-1", mergedFrom: ["sp-4"]))
        XCTAssertNil(transcript.segments[0].speakerID)
    }

    // MARK: - Helpers

    private func insight(_ seq: Int) -> LiveInsight {
        LiveInsight(seq: seq, kind: "monitor", text: "note \(seq)", refSeq: nil)
    }
}

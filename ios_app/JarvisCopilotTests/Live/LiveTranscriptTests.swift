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

    /// The server re-sends a row once the language rescue or identification has
    /// looked at it, and that frame usually carries no translation. Taking it
    /// wholesale erased the one the phone had just made, so the phone translated
    /// the line again and stored it again — every translation reached the server
    /// twice.
    func testARowSentAgainKeepsTheTranslationItAlreadyHad() {
        var transcript = LiveTranscript()
        transcript.upsert(segment(5, text: "hola"))
        transcript.setTranslation(seq: 5, text: "hello")

        transcript.upsert(segment(5, speaker: "sp-2", state: .confirmed, text: "hola"))

        XCTAssertEqual(transcript.segment(seq: 5)?.translation, "hello")
        XCTAssertEqual(transcript.segment(seq: 5)?.speakerID, "sp-2")
    }

    /// But a row whose WORDS changed — the rescue re-heard it — has a translation
    /// of the old words, and keeping it would put the wrong meaning under the
    /// corrected line.
    func testACorrectedRowDropsTheTranslationOfItsOldWords() {
        var transcript = LiveTranscript()
        transcript.upsert(segment(5, text: "Ola, Como, Stas"))
        transcript.setTranslation(seq: 5, text: "Ola, Como, Stas")

        transcript.upsert(segment(5, text: "Hola, ¿cómo estás?"))

        XCTAssertNil(transcript.segment(seq: 5)?.translation)
    }

    /// Every translated line showed its meaning twice: under the line, and
    /// again as a "Translation" card — the phone's own translation, echoed back
    /// by the server as an insight.
    func testATranslationNoteGoesUnderItsLineNotBesideIt() {
        var transcript = LiveTranscript()
        transcript.upsert(segment(5, text: "Hola, ¿cómo estás?"))
        var note = LiveInsight()
        note.seq = 5
        note.kind = "translation"
        note.text = "Hello, how are you?"

        transcript.upsert(note)

        XCTAssertTrue(transcript.insights.isEmpty, "no card")
        XCTAssertEqual(transcript.segment(seq: 5)?.translation, "Hello, how are you?")
    }

    /// A translation the frame itself carries always wins.
    func testATranslationInTheFrameReplacesTheOneHeld() {
        var transcript = LiveTranscript()
        transcript.upsert(segment(5, text: "hola"))
        transcript.setTranslation(seq: 5, text: "hi")
        var sent = segment(5, text: "hola")
        sent.translation = "hello"

        transcript.upsert(sent)

        XCTAssertEqual(transcript.segment(seq: 5)?.translation, "hello")
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

    // MARK: - Several notes from one window

    /// A monitor window emits SEVERAL notes and the server stamps them all with
    /// the same `seq` (the last segment of the window). Keyed on `seq` each one
    /// replaced the last, so a window with three things to say showed one — and
    /// silently, which is why it was not obvious the notes were arriving.
    func testEveryNoteFromOneWindowSurvives() {
        var transcript = LiveTranscript()
        transcript.upsert(segment(4))
        transcript.upsert(LiveInsight(seq: 4, kind: "monitor", text: "first note"))
        transcript.upsert(LiveInsight(seq: 4, kind: "monitor", text: "second note"))
        transcript.upsert(LiveInsight(seq: 4, kind: "monitor", text: "third note"))

        XCTAssertEqual(transcript.insights.map(\.text),
                       ["first note", "second note", "third note"])
        // Distinct row ids, or SwiftUI renders one row for the lot.
        XCTAssertEqual(Set(transcript.rows.map(\.id)).count, transcript.rows.count)
        // And the utterance still comes before the notes about it.
        XCTAssertEqual(transcript.rows.first?.id, "s4")
    }

    /// A resume replay re-delivers the same note. That must not become a second
    /// card, and must not move the one already on screen.
    func testAReDeliveredNoteIsAbsorbedRatherThanDuplicated() {
        var transcript = LiveTranscript()
        transcript.upsert(LiveInsight(seq: 4, kind: "monitor", text: "a note"))
        let idBefore = transcript.rows.first?.id
        transcript.upsert(LiveInsight(seq: 4, kind: "monitor", text: "a note"))

        XCTAssertEqual(transcript.insights.count, 1)
        XCTAssertEqual(transcript.rows.first?.id, idBefore)
    }

    // MARK: - The wrap-up

    /// The end-of-session wrap-up arrives with no `seq` at all, so it is held
    /// apart from the rows instead of being filed at seq 0 — at the top of the
    /// conversation it summarises.
    func testTheWrapUpIsHeldApartFromTheRows() {
        var transcript = LiveTranscript()
        transcript.upsert(segment(1))
        transcript.apply(LiveWrapUp(summary: "They agreed to ship on Friday.",
                                    decisions: ["Ship Friday"], actionItems: [], text: ""))

        XCTAssertEqual(transcript.rows.count, 1, "it is not a row")
        XCTAssertEqual(transcript.wrapUp?.decisions, ["Ship Friday"])
        XCTAssertEqual(transcript.cursor, 1, "and it cannot move the resume cursor")
    }

    func testAnEmptyWrapUpIsIgnored() {
        var transcript = LiveTranscript()
        transcript.apply(LiveWrapUp())
        XCTAssertNil(transcript.wrapUp)
    }

    // MARK: - Helpers

    private func insight(_ seq: Int) -> LiveInsight {
        LiveInsight(seq: seq, kind: "monitor", text: "note \(seq)", refSeq: nil)
    }
}

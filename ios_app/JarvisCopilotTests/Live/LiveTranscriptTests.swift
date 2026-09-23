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

    // MARK: - Speaker turns

    private func line(_ seq: Int, _ speaker: String?, atS start: Int, _ text: String,
                      lang: String = "en", translation: String? = nil) -> LiveRow {
        .segment(LiveSegment(seq: seq, startMs: start * 1000, endMs: start * 1000 + 1500,
                             speakerID: speaker, text: text, lang: lang,
                             translation: translation))
    }

    private func turns(_ items: [LiveTimelineItem]) -> [LiveTurn] {
        items.compactMap { if case .turn(let turn) = $0 { return turn } else { return nil } }
    }

    /// The screenshot that asked for this: one person, three pauses, three
    /// headers. Pauses from the same voice are one turn.
    func testPausesFromOneVoiceStayOneTurn() {
        let items = LiveTurns.timeline([
            line(1, "A", atS: 0, "practicar hablar español."),
            line(2, "A", atS: 20, "con hispanohablantes."),
            line(3, "A", atS: 45, "algunos tips profesionales para ti."),
        ])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(turns(items).first?.text,
                       "practicar hablar español. con hispanohablantes. algunos tips profesionales para ti.")
    }

    func testAnotherVoiceStartsANewTurn() {
        let items = LiveTurns.timeline([
            line(1, "A", atS: 0, "hi"), line(2, "B", atS: 3, "hello"), line(3, "A", atS: 6, "how are you"),
        ])
        XCTAssertEqual(turns(items).map(\.speakerKey), ["id:A", "id:B", "id:A"])
    }

    /// His screenshot: "Olá, como temos?" and the English after it sat in one
    /// block tagged Portuguese, with a translation mixing both. A change of
    /// language is a new block, even from the same voice.
    func testAChangeOfLanguageStartsANewBlock() {
        let items = LiveTurns.timeline([
            line(1, "me", atS: 0, "Olá, como temos?", lang: "pt", translation: "Hello, how are we?"),
            line(2, "me", atS: 4, "Hello, are you there?", lang: "en-US"),
            line(3, "me", atS: 8, "Just checking.", lang: "en"),
            line(4, "me", atS: 12, "Hola.", lang: "es-419", translation: "Hello."),
        ])
        XCTAssertEqual(turns(items).map(\.language), ["pt", "en", "es"])
        XCTAssertEqual(turns(items)[1].text, "Hello, are you there? Just checking.",
                       "en-US and en are one language")
        XCTAssertNil(turns(items)[1].readerText(primary: "en"))
    }

    /// A line with no label yet is not a language change.
    func testAnUnlabelledLineStaysInItsTurn() {
        let items = LiveTurns.timeline([
            line(1, "me", atS: 0, "Hola.", lang: "es"), line(2, "me", atS: 3, "¿Qué tal?", lang: ""),
        ])
        XCTAssertEqual(turns(items).count, 1)
    }

    func testATwoMinuteSilenceStartsANewTurn() {
        let items = LiveTurns.timeline([line(1, "A", atS: 0, "before"), line(2, "A", atS: 200, "after")])
        XCTAssertEqual(turns(items).count, 2)
    }

    /// A watcher note written mid-turn goes after the turn, not wedged in it.
    func testANoteSitsAfterItsTurnNotInsideIt() {
        var note = LiveInsight(seq: 1, kind: "monitor", text: "they are practising Spanish")
        note.localID = 7
        let items = LiveTurns.timeline([line(1, "A", atS: 0, "uno"), .insight(note),
                                        line(2, "A", atS: 5, "dos")])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(turns(items).first?.lines.map(\.seq), [1, 2])
        XCTAssertEqual(turns(items).first?.notes.map(\.text), ["they are practising Spanish"])
    }

    /// One paragraph in the reader's language, and a line still waiting for
    /// its translation left out rather than shown untranslated.
    func testTheTranslationReadsAsOneParagraph() {
        let items = LiveTurns.timeline([
            line(1, "A", atS: 0, "Hola.", lang: "es", translation: "Hello."),
            line(2, "A", atS: 3, "Buenos días.", lang: "es", translation: "Good morning."),
            line(3, "A", atS: 6, "¿Cómo estás?", lang: "es"),
        ])
        let turn = turns(items)[0]
        XCTAssertEqual(turn.readerText(primary: "en"), "Hello. Good morning.")
        XCTAssertEqual(turn.foreignLanguages(primary: "en"), ["es"])

        let english = turns(LiveTurns.timeline([line(1, "A", atS: 0, "just English")]))[0]
        XCTAssertNil(english.readerText(primary: "en"), "nothing translated, no second paragraph")
    }

    func testTheLiveWordsCarryOnARecentTurnOnly() {
        let turn = turns(LiveTurns.timeline([line(1, "A", atS: 10, "hi")]))[0]
        XCTAssertTrue(LiveTurns.liveContinues(turn, liveStartMs: 14_000))
        XCTAssertFalse(LiveTurns.liveContinues(turn, liveStartMs: 40_000))
    }

    /// The transcript keeps the turns current as rows change, so the screen
    /// never regroups on its own.
    func testTheTranscriptKeepsItsTurnsCurrent() {
        var transcript = LiveTranscript()
        transcript.upsert(LiveSegment(seq: 1, startMs: 0, endMs: 900, speakerID: "A", text: "one"))
        transcript.upsert(LiveSegment(seq: 2, startMs: 2000, endMs: 2900, speakerID: "A", text: "two"))
        XCTAssertEqual(transcript.timeline.count, 1)
        transcript.upsert(LiveSegment(seq: 2, startMs: 2000, endMs: 2900, speakerID: "B", text: "two"))
        XCTAssertEqual(transcript.timeline.count, 2, "identification moved line 2 to another voice")
    }

    // MARK: - Splitting a line by voice

    /// 80 ms frames from 0 ms; `on` lists, per slot, the stretches (ms) it speaks.
    private func activity(ms: Int, _ on: [[ClosedRange<Int>]]) -> LiveSpeakerActivity {
        let frames = (0..<(ms / 80)).map { frame -> [Float] in
            let at = frame * 80 + 40
            return on.map { spans in spans.contains { $0.contains(at) } ? 0.95 : 0.02 }
        }
        return LiveSpeakerActivity(startMs: 0, frameMs: 80, frames: frames)
    }

    private func words(_ spec: [(String, Int, Int)]) -> [SpeechWord] {
        spec.map { SpeechWord(text: $0.0, startMs: $0.1, endMs: $0.2) }
    }

    /// His recording: the video's voice runs through the whole line, his own
    /// comes in for 1.7 s, and Apple wrote only his English. Every word was
    /// said while both were active, so they go to the voice speaking OVER the
    /// backdrop — his — not to the video, which is where the line was filed.
    func testWordsSpokenOverABackdropGoToTheVoiceOnTop() {
        let heard = activity(ms: 9000, [[0...9000], [6350...8050]])
        let pieces = LiveSpeakerSplit.pieces(
            of: words([("Hello,", 6400, 6800), ("are", 6900, 7100), ("you", 7150, 7350),
                       ("there?", 7400, 7900)]),
            activity: heard)
        XCTAssertEqual(pieces.map(\.slot), [1])
        XCTAssertEqual(pieces.first?.text, "Hello, are you there?")
    }

    /// Two people taking turns inside one line become two pieces.
    func testATurnInsideALineSplitsIt() {
        let heard = activity(ms: 6000, [[0...2600], [2700...6000]])
        let pieces = LiveSpeakerSplit.pieces(
            of: words([("so", 200, 500), ("what", 600, 900), ("now", 1000, 1500),
                       ("I", 2900, 3100), ("have", 3200, 3500), ("no", 3600, 3900),
                       ("idea", 4000, 4600)]),
            activity: heard)
        XCTAssertEqual(pieces.map(\.slot), [0, 1])
        XCTAssertEqual(pieces.map(\.text), ["so what now", "I have no idea"])
    }

    /// A shared word follows the voice that was speaking just before it.
    func testASharedWordStaysWithTheSpeakerBeforeIt() {
        let heard = activity(ms: 4000, [[0...4000], [2000...2600]])
        let pieces = LiveSpeakerSplit.pieces(
            of: words([("I", 100, 300), ("was", 400, 700), ("saying", 800, 1400),
                       ("that", 2100, 2500), ("again", 2700, 3300)]),
            activity: heard)
        XCTAssertEqual(pieces.map(\.slot), [0], "one voice, with a brief overlap")
    }

    /// A flicker shorter than a real turn is not a turn.
    func testAFragmentTooShortToBeATurnIsFoldedIn() {
        let heard = activity(ms: 4000, [[0...1900, 2300...4000], [1950...2250]])
        let pieces = LiveSpeakerSplit.pieces(
            of: words([("one", 100, 800), ("two", 900, 1800), ("uh", 2000, 2200),
                       ("three", 2400, 3200)]),
            activity: heard)
        XCTAssertEqual(pieces.count, 1)
        XCTAssertEqual(pieces.first?.slot, 0)
    }

    /// No diarizer, or one that heard nobody: the line is left whole.
    func testNoActivityLeavesTheLineWhole() {
        let spoken = words([("hi", 0, 300), ("there", 400, 800)])
        XCTAssertEqual(LiveSpeakerSplit.pieces(of: spoken, activity: nil).count, 1)
        XCTAssertEqual(LiveSpeakerSplit.pieces(of: spoken, activity: nil).first?.slot, nil)
        XCTAssertTrue(LiveSpeakerSplit.pieces(of: [], activity: nil).isEmpty)
    }

    /// A voiceprint of one voice is made only from where it speaks alone.
    func testSoloStretchesLeaveOutTheOverlap() {
        let heard = activity(ms: 4000, [[0...4000], [1600...3200]])
        XCTAssertEqual(LiveSpeakerSplit.soloRanges(of: 0, in: heard, fromMs: 0, toMs: 4000),
                       [0...1600, 3200...4000])
        XCTAssertEqual(LiveSpeakerSplit.soloRanges(of: 1, in: heard, fromMs: 0, toMs: 4000), [],
                       "the voice on top was never alone")
    }
}

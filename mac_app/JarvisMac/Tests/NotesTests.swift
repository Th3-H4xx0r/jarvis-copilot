import XCTest
@testable import Jarvis

/// The note-taker's pure rules: how words become lines, how the microphone's
/// echo of the other side is dropped, who is who (You on the microphone, Them on
/// the Mac's sound), when a stretch of audio is ready to transcribe, the
/// Markdown export and the JSON the server sends back.
final class NotesTests: XCTestCase {

    private func w(_ text: String, _ start: Double, _ end: Double) -> TimedWord {
        TimedWord(text: text, start: start, end: end)
    }

    // MARK: lines

    func testCloseWordsOfOneSpeakerMakeOneLine() {
        let lines = NoteBuilder.lines(speaker: "me", words: [w("we", 0, 0.2), w("ship", 0.3, 0.6), w("friday", 0.7, 1.1),
                                                             w("then", 4, 4.2)])
        XCTAssertEqual(lines.map(\.text), ["we ship friday", "then"], "a pause starts a new line")
        XCTAssertEqual(lines[0].start, 0)
        XCTAssertEqual(lines[0].end, 1.1)
    }

    func testALineNeverGrowsPastItsLimit() {
        let words = (0..<100).map { w("w", Double($0), Double($0) + 0.5) }
        let lines = NoteBuilder.lines(speaker: "me", words: words)
        XCTAssertTrue(lines.count >= 2)
        XCTAssertTrue(lines.allSatisfy { $0.end - $0.start <= NoteBuilder.maxLineSeconds })
    }

    func testTheMicrophonesEchoOfTheOtherSideIsDropped() {
        let mine = [NoteLine(speaker: "me", start: 10, end: 13, text: "the budget is fine for now"),
                    NoteLine(speaker: "me", start: 20, end: 22, text: "great let's do it")]
        let theirs = [NoteLine(speaker: "them", start: 10.2, end: 13.1, text: "The budget is fine for now.")]
        XCTAssertEqual(NoteBuilder.removingEcho(mine: mine, others: theirs).map(\.text), ["great let's do it"])
    }

    func testBuildLabelsBySource() {
        let built = NoteBuilder.build(mine: [w("hello", 0, 0.5)], others: [w("hi", 1, 1.3), w("there", 1.4, 1.8)])
        XCTAssertEqual(built.speakers.map(\.id), ["me", "them"])
        XCTAssertEqual(built.speakers.map(\.name), ["You", "Them"])
        XCTAssertEqual(built.speakers.first?.isMe, true)
        XCTAssertEqual(built.lines.map(\.speaker), ["me", "them"])
        XCTAssertEqual(built.lines.map(\.text), ["hello", "hi there"])
    }

    func testAMicOnlyRecordingHasJustYou() {
        let built = NoteBuilder.build(mine: [w("note", 0, 0.5)], others: [])
        XCTAssertEqual(built.speakers.map(\.id), ["me"])
    }

    func testLiveLinesAreMergedInTimeOrder() {
        var lines: [NoteLine] = []
        NoteBuilder.insert(NoteLine(speaker: "them", start: 5, end: 6, text: "b"), into: &lines)
        NoteBuilder.insert(NoteLine(speaker: "me", start: 1, end: 2, text: "a"), into: &lines)
        NoteBuilder.insert(NoteLine(speaker: "me", start: 9, end: 10, text: "c"), into: &lines)
        XCTAssertEqual(lines.map(\.text), ["a", "b", "c"])
    }

    // MARK: chunks

    func testAStretchIsCutOnAPauseOnceLongEnough() {
        XCTAssertEqual(NoteChunker.decide(seconds: 2, tailRMS: 0, rms: 0.1, force: false), .wait, "too short")
        XCTAssertEqual(NoteChunker.decide(seconds: 6, tailRMS: 0.05, rms: 0.1, force: false), .wait, "still talking")
        XCTAssertEqual(NoteChunker.decide(seconds: 6, tailRMS: 0.001, rms: 0.1, force: false), .cut)
        XCTAssertEqual(NoteChunker.decide(seconds: 19, tailRMS: 0.05, rms: 0.1, force: false), .cut, "too long to wait")
        XCTAssertEqual(NoteChunker.decide(seconds: 6, tailRMS: 0.001, rms: 0.001, force: false), .drop, "silence")
        XCTAssertEqual(NoteChunker.decide(seconds: 1, tailRMS: 0.05, rms: 0.1, force: true), .cut, "the end of the call")
        XCTAssertEqual(NoteChunker.decide(seconds: 0.2, tailRMS: 0.05, rms: 0.1, force: true), .wait)
    }

    func testWordsGetTheChunksOffset() {
        let words = NoteBuilder.offset([w("hi", 0.5, 0.8)], by: 30)
        XCTAssertEqual(words.first?.start, 30.5)
        XCTAssertEqual(words.first?.end, 30.8)
    }

    // MARK: export

    private func sample() -> Note {
        var n = Note(title: "Beta launch", start: Date(timeIntervalSince1970: 1_760_450_400))
        n.end = n.start.addingTimeInterval(32 * 60)
        n.speakers = [NoteSpeaker(id: "me", name: "You", isMe: true), NoteSpeaker(id: "them", name: "Them")]
        n.lines = [NoteLine(speaker: "me", start: 0, end: 3, text: "Let's ship Friday."),
                   NoteLine(speaker: "them", start: 75, end: 80, text: "Notes by Thursday.")]
        n.summary = "Ships Friday."
        n.keyPoints = ["Beta Friday"]
        n.todos = [NoteTodo(text: "Write notes", owner: "Them", due: "Thursday", done: true)]
        return n
    }

    func testMarkdownHasEverySection() {
        let md = NoteBuilder.markdown(sample(), timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertTrue(md.hasPrefix("# Beta launch\n"))
        XCTAssertTrue(md.contains("32 min"))
        XCTAssertTrue(md.contains("## Summary\n\nShips Friday."))
        XCTAssertTrue(md.contains("## Key points\n\n- Beta Friday"))
        XCTAssertTrue(md.contains("- [x] Write notes (Them, Thursday)"))
        XCTAssertTrue(md.contains("**You** (0:00): Let's ship Friday."))
        XCTAssertTrue(md.contains("**Them** (1:15): Notes by Thursday."))
    }

    func testClock() {
        XCTAssertEqual(NoteBuilder.clock(75), "1:15")
        XCTAssertEqual(NoteBuilder.clock(3725), "1:02:05")
    }

    // MARK: JSON

    func testTheUploadIsTheServersShape() {
        let n = sample()
        let json = n.serverJSON
        XCTAssertEqual(json["id"] as? String, n.id.uuidString)
        XCTAssertEqual(json["start"] as? Double, 1_760_450_400)
        XCTAssertEqual((json["lines"] as? [[String: Any]])?.first?["speaker"] as? String, "me")
        XCTAssertEqual((json["speakers"] as? [[String: Any]])?.first?["is_me"] as? Bool, true)
        XCTAssertEqual((json["todos"] as? [[String: Any]])?.first?["done"] as? Bool, true)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(json))
    }

    func testTheServersSummaryIsTakenIn() {
        var n = sample()
        n.title = "Call 14 Oct"
        n.summary = nil
        n.absorb(server: ["title": "Beta launch plan", "summary": "The beta ships Friday.",
                          "key_points": ["Friday", 3, ""], "summary_status": "done",
                          "todos": [["text": "Release notes", "owner": "Them", "due": NSNull(), "done": false],
                                    ["text": ""]]])
        XCTAssertEqual(n.title, "Beta launch plan")
        XCTAssertEqual(n.summary, "The beta ships Friday.")
        XCTAssertEqual(n.keyPoints, ["Friday"])
        XCTAssertEqual(n.todos.map(\.text), ["Release notes"])
        XCTAssertNil(n.todos.first?.due)
        XCTAssertEqual(n.summaryStatus, .done)
    }

    func testAnEditedTitleIsKept() {
        var n = sample()
        n.titleEdited = true
        n.absorb(server: ["title": "Something else", "summary": "S", "summary_status": "done"])
        XCTAssertEqual(n.title, "Beta launch")
    }

    func testAFailedSummarySaysWhy() {
        var n = sample()
        n.absorb(server: ["summary_status": "failed", "summary_error": "no provider"])
        XCTAssertEqual(n.summaryStatus, .failed)
        XCTAssertEqual(n.summaryError, "no provider")
        XCTAssertEqual(n.summary, "Ships Friday.", "a failure never erases what was there")
    }

    func testNotesRoundTripOnDisk() throws {
        let n = sample()
        let data = try NoteStore.encoder.encode(n)
        let back = try NoteStore.decoder.decode(Note.self, from: data)
        XCTAssertEqual(back, n)
    }

    func testANoteInterruptedByAQuitIsNotLeftRecording() {
        var n = sample()
        n.status = .recording
        let partial = NoteStore.recovered(n)
        XCTAssertEqual(partial.status, .ready, "the live lines written before the quit are kept")
        XCTAssertNotNil(partial.error)
        XCTAssertFalse(partial.uploaded)
        n.lines = []
        XCTAssertEqual(NoteStore.recovered(n).status, .failed, "nothing was written: nothing to keep")
        n.status = .ready
        XCTAssertEqual(NoteStore.recovered(n), n, "a finished note is left alone")
    }
}

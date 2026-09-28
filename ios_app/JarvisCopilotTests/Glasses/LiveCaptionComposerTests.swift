import XCTest
@testable import JarvisCopilot

@MainActor
final class LiveCaptionComposerTests: XCTestCase {
    private func seg(_ seq: Int, _ name: String, _ text: String, _ tr: String = "") -> LiveCaptionSegment {
        LiveCaptionSegment(seq: seq, name: name, text: text, translation: tr)
    }

    func testANewLineGoesUpNamedAndFinal() {
        var c = LiveCaptionComposer()
        _ = c.begin(.init(partial: "", segments: []))
        XCTAssertEqual(c.update(.init(partial: "", segments: [seg(1, "Maya", "Are we on for six?")])),
                       [LensCaption(text: "Maya — Are we on for six?", translation: "", final: true)])
    }

    func testPartialWordsGoUpUnnamedThenTheFinalReplacesThem() {
        var c = LiveCaptionComposer()
        _ = c.begin(.init(partial: "", segments: []))
        XCTAssertEqual(c.update(.init(partial: "are we on", segments: [])),
                       [LensCaption(text: "are we on", translation: "", final: false)])
        XCTAssertEqual(c.update(.init(partial: "are we on", segments: [])), [])
        XCTAssertEqual(c.update(.init(partial: "are we on", segments: [seg(1, "Maya", "Are we on?")])),
                       [LensCaption(text: "Maya — Are we on?", translation: "", final: true)])
    }

    func testTheCommittedEchoOfTheLastLineIsNotRepeated() {
        var c = LiveCaptionComposer()
        _ = c.begin(.init(partial: "", segments: []))
        _ = c.update(.init(partial: "", segments: [seg(1, "Maya", "Are we on?")]))
        XCTAssertEqual(c.update(.init(partial: "Are we on?", segments: [seg(1, "Maya", "Are we on?")])), [])
    }

    func testALateTranslationResendsThatLineOnce() {
        var c = LiveCaptionComposer()
        _ = c.begin(.init(partial: "", segments: []))
        _ = c.update(.init(partial: "", segments: [seg(1, "Luis", "¿Nos vemos a las seis?")]))
        let s = LiveCaptionSnapshot(partial: "", segments: [seg(1, "Luis", "¿Nos vemos a las seis?", "Are we meeting at six?")])
        XCTAssertEqual(c.update(s), [LensCaption(text: "Luis — ¿Nos vemos a las seis?", translation: "Are we meeting at six?", final: true)])
        XCTAssertEqual(c.update(s), [])
    }

    func testBeginShowsOnlyTheLatestLineAndNothingOlderIsReplayed() {
        var c = LiveCaptionComposer()
        let history = LiveCaptionSnapshot(partial: "", segments: [seg(7, "Maya", "one"), seg(8, "Pranav", "two")])
        XCTAssertEqual(c.begin(history), LensCaption(text: "Pranav — two", translation: "", final: true))
        XCTAssertEqual(c.update(history), [])
        XCTAssertEqual(c.update(.init(partial: "", segments: history.segments + [seg(9, "Maya", "three")])),
                       [LensCaption(text: "Maya — three", translation: "", final: true)])
    }

    func testBeginPrefersTheWordsBeingSpoken() {
        var c = LiveCaptionComposer()
        XCTAssertEqual(c.begin(.init(partial: "right now", segments: [seg(1, "Maya", "before")])),
                       LensCaption(text: "right now", translation: "", final: false))
    }

    func testARevisedLineIsResent() {
        var c = LiveCaptionComposer()
        _ = c.begin(.init(partial: "", segments: []))
        _ = c.update(.init(partial: "", segments: [seg(1, "Speaker 2", "see you at sex")]))
        XCTAssertEqual(c.update(.init(partial: "", segments: [seg(1, "Maya", "see you at six")])),
                       [LensCaption(text: "Maya — see you at six", translation: "", final: true)])
    }

    func testLongCaptionsKeepTheMostRecentWords() {
        let long = (1...60).map { "word\($0)" }.joined(separator: " ")
        let fit = LiveCaptionComposer.fit(long)
        XCTAssertLessThanOrEqual(fit.count, LiveCaptionComposer.maxChars)
        XCTAssertTrue(fit.hasPrefix("…"))
        XCTAssertTrue(fit.hasSuffix("word60"))
        XCTAssertFalse(fit.dropFirst().hasPrefix(" "))
        XCTAssertEqual(LiveCaptionComposer.fit("short"), "short")
    }

    /// Review C1: a new Live session numbers its lines from 1 again.
    func testANewSessionStartsCountingAgain() {
        var c = LiveCaptionComposer()
        _ = c.begin(.init(partial: "", segments: [seg(40, "Maya", "old")], session: "a"))
        XCTAssertEqual(c.update(.init(partial: "", segments: [seg(1, "Luis", "new day")], session: "b")),
                       [LensCaption(text: "Luis — new day", translation: "", final: true)])
        XCTAssertEqual(c.update(.init(partial: "", segments: [seg(1, "Luis", "new day"), seg(2, "Maya", "hi")], session: "b")),
                       [LensCaption(text: "Maya — hi", translation: "", final: true)])
    }

    /// Review C1: the transcript was cleared under us (same session id).
    func testATranscriptThatStartedOverIsNotIgnored() {
        var c = LiveCaptionComposer()
        _ = c.begin(.init(partial: "", segments: [seg(40, "Maya", "old")]))
        XCTAssertEqual(c.update(.init(partial: "", segments: [seg(1, "Luis", "again")])),
                       [LensCaption(text: "Luis — again", translation: "", final: true)])
    }

    /// Review I7: a long line keeps its speaker's name.
    func testALongLineKeepsTheName() {
        var c = LiveCaptionComposer()
        _ = c.begin(.init(partial: "", segments: []))
        let words = (1...60).map { "word\($0)" }.joined(separator: " ")
        let out = c.update(.init(partial: "", segments: [seg(1, "Maya", words)]))
        XCTAssertTrue(out.first?.text.hasPrefix("Maya — …") ?? false)
        XCTAssertLessThanOrEqual(out.first?.text.count ?? 999, LiveCaptionComposer.maxChars)
    }

    /// Review I6: a late translation for an older line must not put it back on the lens.
    func testALateTranslationForAnOlderLineIsNotResent() {
        var c = LiveCaptionComposer()
        _ = c.begin(.init(partial: "", segments: []))
        _ = c.update(.init(partial: "", segments: [seg(1, "Luis", "hola"), seg(2, "Maya", "hi")]))
        XCTAssertEqual(c.update(.init(partial: "", segments: [seg(1, "Luis", "hola", "hello"), seg(2, "Maya", "hi")])), [])
    }
}
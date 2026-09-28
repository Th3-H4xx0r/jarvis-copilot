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
                       [LensCaption(text: "Maya: Are we on for six?", translation: "", final: true)])
    }

    func testPartialWordsGoUpUnnamedThenTheFinalReplacesThem() {
        var c = LiveCaptionComposer()
        _ = c.begin(.init(partial: "", segments: []))
        XCTAssertEqual(c.update(.init(partial: "are we on", segments: [])),
                       [LensCaption(text: "are we on", translation: "", final: false)])
        XCTAssertEqual(c.update(.init(partial: "are we on", segments: [])), [])
        XCTAssertEqual(c.update(.init(partial: "are we on", segments: [seg(1, "Maya", "Are we on?")])),
                       [LensCaption(text: "Maya: Are we on?", translation: "", final: true)])
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
        XCTAssertEqual(c.update(s), [LensCaption(text: "Luis: ¿Nos vemos a las seis?", translation: "Are we meeting at six?", final: true)])
        XCTAssertEqual(c.update(s), [])
    }

    func testBeginShowsOnlyTheLatestLineAndNothingOlderIsReplayed() {
        var c = LiveCaptionComposer()
        let history = LiveCaptionSnapshot(partial: "", segments: [seg(7, "Maya", "one"), seg(8, "Pranav", "two")])
        XCTAssertEqual(c.begin(history), LensCaption(text: "Pranav: two", translation: "", final: true))
        XCTAssertEqual(c.update(history), [])
        XCTAssertEqual(c.update(.init(partial: "", segments: history.segments + [seg(9, "Maya", "three")])),
                       [LensCaption(text: "Maya: three", translation: "", final: true)])
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
                       [LensCaption(text: "Maya: see you at six", translation: "", final: true)])
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
}

import XCTest
@testable import JarvisCopilot

/// The karaoke word-highlight model ported from `voice_controller.dart`'s
/// `_Seg` / `_plainSpeech` / `_splitForSpeech` (no Flutter test existed).
final class VoiceKaraokeTests: XCTestCase {

    // MARK: - plainSpeech (must match the server's `_speakable`)

    func testStripsFencedCodeBlocks() {
        XCTAssertEqual(voicePlainSpeech("before\n```\nlet x = 1\n```\nafter"), "before\n \nafter")
    }

    func testKeepsLinkTextAndDropsTheUrl() {
        XCTAssertEqual(voicePlainSpeech("see [the docs](https://x.test/a)"), "see the docs")
    }

    func testUnwrapsInlineCode() {
        XCTAssertEqual(voicePlainSpeech("run `make test` now"), "run make test now")
    }

    func testStripsHeadingsBlockquotesAndBullets() {
        XCTAssertEqual(voicePlainSpeech("## Title\n> quoted\n- one\n* two"),
                       "Title\nquoted\none\ntwo")
    }

    func testStripsEmphasisMarkers() {
        XCTAssertEqual(voicePlainSpeech("**bold** and _italic_ and ~~gone~~"),
                       "bold and italic and gone")
    }

    func testCollapsesRunsOfBlankLinesAndTrims() {
        XCTAssertEqual(voicePlainSpeech("  a\n\n\n\nb  "), "a\n\nb")
    }

    // MARK: - wordTokens

    func testTokenizesOnWhitespaceRuns() {
        XCTAssertEqual(voiceWordTokens("  hello   there\nworld "), ["hello", "there", "world"])
        XCTAssertEqual(voiceWordTokens("   "), [])
    }

    // MARK: - splitForSpeech

    func testSplitsOnSentenceEndsAndNewlines() {
        let out = voiceSplitForSpeech(
            "The weather is clear today. Winds are light out of the west. Enjoy it.")
        XCTAssertEqual(out.count, 2)
        XCTAssertTrue(out[0].hasPrefix("The weather"))
    }

    func testMergesVeryShortFragmentsSoThereIsNoClipPerWord() {
        // Each fragment is under 40 chars → they merge into one chunk.
        XCTAssertEqual(voiceSplitForSpeech("Yes. No. Sure."), ["Yes. No. Sure."])
    }

    func testDropsEmptyFragments() {
        XCTAssertEqual(voiceSplitForSpeech("\n\n  \n"), [])
    }

    func testEveryWordSurvivesTheSplit() {
        let text = "One sentence here that is quite long indeed. Another one follows it. Third."
        let joined = voiceSplitForSpeech(text).joined(separator: " ")
        XCTAssertEqual(voiceWordTokens(joined), voiceWordTokens(text))
    }

    // MARK: - VoiceSegment scheduling

    func testScheduleSpreadsWordsAcrossTheClipStartingAtZero() {
        var seg = VoiceSegment("one two three four", wordOffset: 0)
        seg.schedule(1000)
        XCTAssertEqual(seg.durMs, 1000)
        XCTAssertEqual(seg.starts.count, 4)
        XCTAssertEqual(seg.starts[0], 0, accuracy: 0.001)
        // Monotonically increasing, all inside the clip.
        for i in 1..<seg.starts.count {
            XCTAssertGreaterThan(seg.starts[i], seg.starts[i - 1])
            XCTAssertLessThan(seg.starts[i], 1000)
        }
    }

    func testSentenceEndingWordsTakeLongerThanClauseBreaks() {
        var a = VoiceSegment("aaa. bbb ccc", wordOffset: 0)
        var b = VoiceSegment("aaa, bbb ccc", wordOffset: 0)
        a.schedule(1000)
        b.schedule(1000)
        // The word after a full stop starts later than after a comma, because
        // the sentence break carries more weight.
        XCTAssertGreaterThan(a.starts[1], b.starts[1])
    }

    func testAdvanceIsMonotonicAndNeverStepsBackward() {
        var seg = VoiceSegment("one two three four five", wordOffset: 0)
        seg.schedule(1000)
        seg.advance(600)
        let reached = seg.localSpoken
        XCTAssertGreaterThan(reached, 0)
        seg.advance(10) // a jittery late report from earlier in the clip
        XCTAssertEqual(seg.localSpoken, reached)
    }

    func testAdvanceToTheEndOfTheClipSpeaksEveryWord() {
        var seg = VoiceSegment("one two three", wordOffset: 0)
        seg.schedule(500)
        seg.advance(500)
        XCTAssertEqual(seg.localSpoken, 3)
    }

    func testAnEmptySegmentSchedulesNothing() {
        var seg = VoiceSegment("", wordOffset: 7)
        seg.schedule(1000)
        XCTAssertTrue(seg.starts.isEmpty)
        seg.advance(1000)
        XCTAssertEqual(seg.localSpoken, 0)
    }
}

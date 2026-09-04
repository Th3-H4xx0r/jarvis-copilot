import XCTest
@testable import Runner

final class WatchBridgeTests: XCTestCase {
    // The real server emits assistant text as `token` events and terminates
    // with `stream_end` (see webui/api/streaming.py) — NOT delta/done.
    func testAccumulateTokens() {
        let sse = """
        event: token
        data: {"text": "It's "}

        event: token
        data: {"text": "72\u{00B0}."}

        event: stream_end
        data: {"session": {}, "usage": {}}
        """
        let r = WatchRelay.accumulateSSE(sse)
        XCTAssertEqual(r.text, "It's 72\u{00B0}.")
        XCTAssertTrue(r.done)
        XCTAssertFalse(r.errored)
    }

    func testHeartbeatsAndBlankLinesIgnored() {
        let sse = ": heartbeat\n\nevent: token\ndata: {\"text\": \"hi\"}\n\n: heartbeat\n"
        let r = WatchRelay.accumulateSSE(sse)
        XCTAssertEqual(r.text, "hi")
        XCTAssertFalse(r.errored)
    }

    func testApperrorEventMarksErrored() {
        let r = WatchRelay.accumulateSSE("event: apperror\ndata: {\"error\": \"boom\"}")
        XCTAssertTrue(r.errored)
    }

    func testDoneAndCancelStillHandled() {
        XCTAssertTrue(WatchRelay.accumulateSSE("event: done\ndata: {}").done)
        XCTAssertTrue(WatchRelay.accumulateSSE("event: cancel\ndata: {}").errored)
    }

    func testSessionIdTopLevelAndNested() {
        XCTAssertEqual(WatchRelay.extractSessionId(["session_id": "abc"]), "abc")
        XCTAssertEqual(WatchRelay.extractSessionId(["session": ["session_id": "def"]]), "def")
        XCTAssertNil(WatchRelay.extractSessionId(["nope": 1]))
        XCTAssertNil(WatchRelay.extractSessionId(["session_id": ""]))
    }
}

// MARK: - WatchRelay.SentenceSplitter (plan 1.6a)
//
// Mirrors the server's `_take_complete_sentences` (webui/api/voice.py:1105):
// the FIRST sentence flushes at any terminator (min_len 0, for a near-instant
// ack); every later one only once the buffer holds >=110 chars.
final class SentenceSplitterTests: XCTestCase {
    func testFirstSentenceFlushesImmediatelyOnTerminator() {
        let s = WatchRelay.SentenceSplitter()
        XCTAssertEqual(s.feed("Hi there."), ["Hi there."])
    }

    func testNoEmissionWithoutTerminator() {
        let s = WatchRelay.SentenceSplitter()
        XCTAssertEqual(s.feed("Hi there"), [])
    }

    func testQuestionAndExclamationAreTerminators() {
        XCTAssertEqual(WatchRelay.SentenceSplitter().feed("Really?"), ["Really?"])
        XCTAssertEqual(WatchRelay.SentenceSplitter().feed("Wow!"), ["Wow!"])
    }

    func testTrailingQuoteAfterTerminatorStillMatches() {
        let s = WatchRelay.SentenceSplitter()
        XCTAssertEqual(s.feed("He said \"hi.\" "), ["He said \"hi.\""])
    }

    func testDecimalPointIsNotASentenceBoundary() {
        // "3.14" — the period isn't followed by whitespace/end, so it must
        // NOT be treated as a sentence terminator.
        let s = WatchRelay.SentenceSplitter()
        XCTAssertEqual(s.feed("Pi is 3.14 roughly."), ["Pi is 3.14 roughly."])
    }

    func testSecondSentenceWaitsForMinLength() {
        let s = WatchRelay.SentenceSplitter()
        XCTAssertEqual(s.feed("Hi."), ["Hi."])
        // Short second sentence — below the 110-char min for non-first
        // sentences, so it must NOT flush yet even though it's terminated.
        XCTAssertEqual(s.feed("Ok."), [])
    }

    func testSecondSentenceFlushesOnceLongEnough() {
        let s = WatchRelay.SentenceSplitter()
        XCTAssertEqual(s.feed("Hi."), ["Hi."])
        let filler = String(repeating: "a", count: 108)
        XCTAssertEqual(s.feed(filler + "."), [])       // still short of 110
        let emitted = s.feed(" more.")                  // now over 110
        XCTAssertEqual(emitted, [filler + ". more."])
    }

    func testIncrementalCharByCharFeedStillEmits() {
        let s = WatchRelay.SentenceSplitter()
        var emitted: [String] = []
        for ch in "Hi there." {
            emitted += s.feed(String(ch))
        }
        XCTAssertEqual(emitted, ["Hi there."])
    }

    func testFinishFlushesRemainderWithoutTerminator() {
        let s = WatchRelay.SentenceSplitter()
        XCTAssertEqual(s.feed("Hi."), ["Hi."])
        XCTAssertEqual(s.feed("no punctuation here"), [])
        XCTAssertEqual(s.finish(), "no punctuation here")
    }

    func testFinishReturnsNilWhenNothingPending() {
        let s = WatchRelay.SentenceSplitter()
        XCTAssertEqual(s.feed("Hi."), ["Hi."])
        XCTAssertNil(s.finish())
    }

    func testMultipleTerminatorsInOneFeedGroupIntoOneChunk() {
        // Matches the server: one call takes everything up to the LAST
        // terminator in the buffer, not each sentence individually.
        let s = WatchRelay.SentenceSplitter()
        XCTAssertEqual(s.feed("Hi. There."), ["Hi. There."])
    }
}

// MARK: - WatchRelay.AckTimer (plan 1.6c)
//
// This is the pure decision function behind the watch's instant spoken ack.
// It lives (in duplicate) as `AckTimer.decide` in
// `JarvisWatch Watch App/AckTimer.swift` too, but that target has no test
// target wired up in project.pbxproj — see F-report.md finding 1 — so it's
// tested here, against the copy in `WatchRelay`, which both targets keep in
// lockstep with a hand comment since there's no shared framework between
// Runner and the Watch App to hang a single copy off of.
final class AckTimerTests: XCTestCase {
    func testClipArrivedWinsRegardlessOfElapsedOrPreference() {
        XCTAssertEqual(WatchRelay.AckTimer.decide(elapsedMs: 0, clipArrived: true, preferLocalVoice: false), .clipWon)
        XCTAssertEqual(WatchRelay.AckTimer.decide(elapsedMs: 5000, clipArrived: true, preferLocalVoice: true), .clipWon)
    }

    func testPreferLocalVoiceSpeaksImmediatelyEvenAtZeroElapsed() {
        XCTAssertEqual(WatchRelay.AckTimer.decide(elapsedMs: 0, clipArrived: false, preferLocalVoice: true), .speakLocally)
    }

    func testWaitsBeforeThreshold() {
        XCTAssertEqual(WatchRelay.AckTimer.decide(elapsedMs: 0, clipArrived: false, preferLocalVoice: false), .wait)
        XCTAssertEqual(WatchRelay.AckTimer.decide(elapsedMs: 699, clipArrived: false, preferLocalVoice: false), .wait)
    }

    func testSpeaksLocallyAtOrAfterThreshold() {
        XCTAssertEqual(WatchRelay.AckTimer.decide(elapsedMs: 700, clipArrived: false, preferLocalVoice: false), .speakLocally)
        XCTAssertEqual(WatchRelay.AckTimer.decide(elapsedMs: 5000, clipArrived: false, preferLocalVoice: false), .speakLocally)
    }

    func testThresholdConstantMatchesPlan() {
        XCTAssertEqual(WatchRelay.AckTimer.localVoiceFallbackMs, 700)
    }

    func testClipCheckedBeforePreference() {
        // Even with preferLocalVoice true, an already-arrived clip still wins
        // (there's nothing left to speak locally for).
        XCTAssertEqual(WatchRelay.AckTimer.decide(elapsedMs: 0, clipArrived: true, preferLocalVoice: true), .clipWon)
    }
}


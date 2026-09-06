import XCTest
@testable import JarvisCopilot

/// Every SSE frame the server can send, folded into the live turn. Pure state —
/// no sockets, no store, no main actor.
final class ChatStreamReducerTests: XCTestCase {

    private var state = ChatStreamState()
    private let t0 = Date(timeIntervalSince1970: 1_000)

    override func setUp() {
        super.setUp()
        state = ChatStreamState(startedAt: t0)
    }

    private func apply(_ name: String, _ payload: [String: Any] = [:], at seconds: TimeInterval = 0) -> Bool {
        ChatStreamReducer.apply(chatEvent(name, payload), to: &state, now: t0.addingTimeInterval(seconds))
    }

    // MARK: started

    func testStartedRecordsTheStreamID() {
        XCTAssertTrue(apply("started", ["stream_id": "s-9", "session_id": "sess-1"]))
        XCTAssertEqual(state.streamID, "s-9")
        XCTAssertEqual(state.sessionID, "sess-1")
        XCTAssertTrue(state.receivedAnyEvent)
        XCTAssertNil(state.outcome, "the turn is only getting going")
    }

    // MARK: text deltas

    func testDeltaAndTokenBothAppendText() {
        _ = apply("delta", ["text": "one"])
        _ = apply("token", ["text": " two"])
        XCTAssertEqual(state.message.plainText, "one two")
    }

    func testDeltaAcceptsTheAlternateFieldNames() {
        _ = apply("delta", ["delta": "a"])
        _ = apply("delta", ["content": "b"])
        XCTAssertEqual(state.message.plainText, "ab")
    }

    func testAnEmptyDeltaChangesNothing() {
        XCTAssertFalse(apply("delta", ["text": ""]), "no state change → the store shouldn't re-render")
        XCTAssertTrue(state.message.blocks.isEmpty)
    }

    func testFirstTextRecordsTimeToFirstToken() {
        _ = apply("reasoning", ["text": "thinking"], at: 0.5)
        XCTAssertNil(state.message.stats?.firstTokenMs, "reasoning is not visible output")
        _ = apply("delta", ["text": "hi"], at: 2)
        XCTAssertEqual(state.message.stats?.firstTokenMs, 2_000)
        _ = apply("delta", ["text": " more"], at: 4)
        XCTAssertEqual(state.message.stats?.firstTokenMs, 2_000, "only the first one counts")
    }

    // MARK: thinking / reasoning

    func testThinkingAndReasoningBothAppendToTheTrace() {
        _ = apply("thinking", ["text": "step 1 "])
        _ = apply("reasoning", ["delta": "step 2"])
        XCTAssertEqual(state.message.reasoning, "step 1 step 2")
        XCTAssertTrue(state.message.isThinking, "no visible text yet → the UI shows the thinking dots")
    }

    // MARK: interim assistant text

    func testInterimAssistantTextIsAdoptedOnlyWhenNothingStreamed() {
        _ = apply("interim_assistant", ["text": "between tools"])
        XCTAssertEqual(state.message.plainText, "between tools")

        state = ChatStreamState(startedAt: t0)
        _ = apply("delta", ["text": "streamed"])
        _ = apply("interim_assistant", ["text": "streamed"])
        XCTAssertEqual(state.message.plainText, "streamed", "never double-print what already arrived as tokens")
    }

    func testInterimAssistantRespectsTheAlreadyStreamedFlag() {
        XCTAssertFalse(apply("interim_assistant", ["text": "x", "already_streamed": true]))
        XCTAssertEqual(state.message.plainText, "")
    }

    // MARK: tools

    func testToolStartsACardWithArgsAndAnIDFromTheServer() {
        _ = apply("tool", ["tid": "t7", "name": "web_search", "args": ["q": "swift", "limit": 3]])
        let tool = state.message.tools.first
        XCTAssertEqual(tool?.id, "t7")
        XCTAssertEqual(tool?.name, "web_search")
        XCTAssertEqual(tool?.args["q"], .string("swift"))
        XCTAssertEqual(tool?.args["limit"], .number(3))
        XCTAssertEqual(tool?.done, false)
    }

    func testToolAliasesAndPreviewFallbackFromArgs() {
        _ = apply("tool_start", ["name": "read_file", "args": ["path": "/tmp/a"]])
        XCTAssertEqual(state.message.tools.first?.detailLine, "path: /tmp/a", "no server preview → summarise the args")

        state = ChatStreamState(startedAt: t0)
        _ = apply("tool_call", ["name": "read_file", "preview": "reading /tmp/a"])
        XCTAssertEqual(state.message.tools.first?.preview, "reading /tmp/a")
    }

    func testAToolWithNoIDStillGetsAStableOne() {
        _ = apply("tool", ["name": "a"])
        _ = apply("tool", ["name": "b"])
        let ids = state.message.tools.map(\.id)
        XCTAssertEqual(Set(ids).count, 2, "SwiftUI needs distinct ids for the tool rows")
        XCTAssertFalse(ids.contains(""))
    }

    func testTheClarifyToolIsNotShownAsAToolRow() {
        XCTAssertFalse(apply("tool", ["name": "clarify"]), "the clarify event carries the question instead")
        XCTAssertTrue(state.message.tools.isEmpty)
        XCTAssertFalse(apply("tool_complete", ["name": "clarify"]))
    }

    func testToolResultToolEndAndToolCompleteAllCloseTheCall() {
        for name in ["tool_result", "tool_end", "tool_complete"] {
            state = ChatStreamState(startedAt: t0)
            _ = apply("tool", ["tid": "t1", "name": "run"])
            XCTAssertTrue(apply(name, ["tid": "t1", "name": "run", "duration": 1.25]), name)
            XCTAssertEqual(state.message.tools.first?.done, true, name)
            XCTAssertEqual(state.message.tools.first?.durationSec, 1.25, name)
        }
    }

    func testToolResultCarriesTheResultPreviewAndErrorFlag() {
        _ = apply("tool", ["name": "run"])
        _ = apply("tool_result", ["name": "run", "result": "exit 1", "is_error": true])
        XCTAssertEqual(state.message.tools.first?.result, "exit 1")
        XCTAssertTrue(state.message.tools.first?.isError == true)
    }

    func testToolResultAcceptsSnippetAsTheResultText() {
        _ = apply("tool", ["name": "run"])
        _ = apply("tool_end", ["name": "run", "snippet": "3 files"])
        XCTAssertEqual(state.message.tools.first?.result, "3 files")
    }

    func testToolTextAfterAToolOpensAFreshBlock() {
        _ = apply("delta", ["text": "before"])
        _ = apply("tool", ["name": "run"])
        _ = apply("tool_complete", ["name": "run"])
        _ = apply("delta", ["text": "after"])
        XCTAssertEqual(state.message.blocks.count, 3, "text · tool · text, in arrival order")
        XCTAssertEqual(state.message.plainText, "before\n\nafter")
    }

    // MARK: usage / metering

    func testMeteringReadsUsageFromEveryNestingTheServerUses() {
        let shapes: [[String: Any]] = [
            ["input_tokens": 11, "output_tokens": 7],
            ["usage": ["input_tokens": 11, "output_tokens": 7]],
            ["data": ["input_tokens": 11, "output_tokens": 7]],
            ["data": ["usage": ["input_tokens": 11, "output_tokens": 7]]],
            ["usage": ["prompt_tokens": 11, "completion_tokens": 7]],
        ]
        for shape in shapes {
            state = ChatStreamState(startedAt: t0)
            XCTAssertTrue(apply("metering", shape), "\(shape)")
            XCTAssertEqual(state.message.stats?.inputTokens, 11, "\(shape)")
            XCTAssertEqual(state.message.stats?.outputTokens, 7, "\(shape)")
        }
    }

    func testMeteringAlsoLandsOnTheLiveMirrorAndTheCost() {
        _ = apply("metering", ["usage": ["input_tokens": 3, "output_tokens": 4, "estimated_cost": 0.02],
                               "tps": 31.5, "estimated": true])
        XCTAssertEqual(state.inputTokens, 3)
        XCTAssertEqual(state.outputTokens, 4)
        XCTAssertEqual(state.estimatedCost, 0.02)
        XCTAssertEqual(state.message.stats?.tokensPerSecond, 31.5)
        XCTAssertTrue(state.message.stats?.estimated == true)
    }

    func testUsageEventIsTreatedLikeMetering() {
        _ = apply("usage", ["input_tokens": 1, "output_tokens": 2])
        XCTAssertEqual(state.message.stats?.inputTokens, 1)
    }

    func testMeteringWithNothingUsefulChangesNothing() {
        XCTAssertFalse(apply("metering", ["note": "hi"]))
    }

    func testUnavailableTokensPerSecondIsDropped() {
        _ = apply("metering", ["tps": 12.0, "tps_available": false, "usage": ["input_tokens": 1]])
        XCTAssertNil(state.message.stats?.tokensPerSecond)
    }

    // MARK: clarify

    func testClarifyOpensAPromptWithItsChoices() {
        XCTAssertTrue(apply("clarify", ["question": "Which one?", "choices_offered": ["a", "b"]]))
        XCTAssertEqual(state.clarify?.question, "Which one?")
        XCTAssertEqual(state.clarify?.choices, ["a", "b"])
        XCTAssertNil(state.outcome, "the turn is blocked, not finished")
    }

    func testClarifyAcceptsAPlainChoicesKeyAndIgnoresAnEmptyQuestion() {
        _ = apply("clarify", ["question": "Q", "choices": ["x"]])
        XCTAssertEqual(state.clarify?.choices, ["x"])
        state = ChatStreamState(startedAt: t0)
        XCTAssertFalse(apply("clarify", ["question": "  "]))
        XCTAssertNil(state.clarify)
    }

    // MARK: title

    func testTitleNamesTheSession() {
        XCTAssertTrue(apply("title", ["title": "  Dinner plans "]))
        XCTAssertEqual(state.sessionTitle, "Dinner plans")
        XCTAssertFalse(apply("title", ["title": " "]))
    }

    // MARK: done

    func testDoneAppliesUsagePicksUpTheTitleAndEndsTheTurn() {
        _ = apply("delta", ["text": "hi"])
        XCTAssertTrue(apply("done", [
            "usage": ["input_tokens": 100, "output_tokens": 20],
            "session": ["title": "Named by the server"],
        ], at: 3.2))
        XCTAssertEqual(state.outcome, .done)
        XCTAssertEqual(state.sessionTitle, "Named by the server")
        XCTAssertEqual(state.message.stats?.inputTokens, 100)
        XCTAssertEqual(state.message.stats?.outputTokens, 20)
    }

    func testStreamEndIsDone() {
        _ = apply("stream_end", [:])
        XCTAssertEqual(state.outcome, .done)
    }

    func testDoneAdoptsItsOwnAnswerWhenNothingStreamed() {
        _ = apply("done", ["answer": "the whole reply"])
        XCTAssertEqual(state.message.plainText, "the whole reply")
    }

    func testDoneDoesNotDuplicateTextThatAlreadyStreamed() {
        _ = apply("delta", ["text": "streamed"])
        _ = apply("done", ["text": "streamed"])
        XCTAssertEqual(state.message.plainText, "streamed")
    }

    // MARK: error / cancel

    func testErrorAndAppErrorFailTheTurnWithTheServersMessage() {
        _ = apply("error", ["message": "model exploded"])
        XCTAssertEqual(state.outcome, .failed("model exploded"))

        state = ChatStreamState(startedAt: t0)
        _ = apply("apperror", ["error": "quota exceeded"])
        XCTAssertEqual(state.outcome, .failed("quota exceeded"))

        state = ChatStreamState(startedAt: t0)
        _ = apply("error", [:])
        XCTAssertEqual(state.outcome, .failed("Request failed"))
    }

    func testCancelEndsTheTurnAsCancelled() {
        _ = apply("cancel", [:])
        XCTAssertEqual(state.outcome, .cancelled)
    }

    // MARK: unknown events

    func testUnknownEventsAreIgnoredButStillCountAsTraffic() {
        XCTAssertFalse(apply("something_new", ["x": 1]), "future server additions must not break the turn")
        XCTAssertNil(state.outcome)
        XCTAssertTrue(state.receivedAnyEvent, "the stream is alive, so the stall watchdog should not fire")
    }

    // MARK: finish / fail

    func testFinishStampsTheDurationAndStopsStreaming() {
        _ = apply("delta", ["text": "hi"])
        ChatStreamReducer.finish(&state, now: t0.addingTimeInterval(3.25))
        XCTAssertFalse(state.message.streaming)
        XCTAssertEqual(state.message.stats?.durationMs, 3_250)
        XCTAssertEqual(state.outcome, .done)
    }

    func testFinishDropsTheTrailingEmptyTextBlockOfAToolOnlyTurn() {
        _ = apply("tool", ["name": "run"])
        _ = apply("tool_complete", ["name": "run"])
        _ = apply("delta", ["text": "   "])
        ChatStreamReducer.finish(&state, now: t0)
        XCTAssertEqual(state.message.blocks.count, 1)
        XCTAssertEqual(state.message.tools.count, 1)
    }

    func testFinishLeavesACancelledMarkerOnlyWhenNothingWasSaid() {
        ChatStreamReducer.finish(&state, cancelled: true, now: t0)
        XCTAssertEqual(state.message.plainText, "_(cancelled)_")
        XCTAssertEqual(state.outcome, .cancelled)

        state = ChatStreamState(startedAt: t0)
        _ = apply("delta", ["text": "partial answer"])
        ChatStreamReducer.finish(&state, cancelled: true, now: t0)
        XCTAssertEqual(state.message.plainText, "partial answer", "keep whatever the turn managed to say")
    }

    func testFinishClosesEveryOpenToolRow() {
        _ = apply("tool", ["name": "a"])
        _ = apply("tool", ["name": "b"])
        ChatStreamReducer.finish(&state, now: t0)
        XCTAssertTrue(state.message.tools.allSatisfy(\.done), "no spinner may survive the end of the turn")
    }

    func testFailMarksTheTurnAndShowsTheMessageInTheBubble() {
        _ = apply("delta", ["text": "   "])
        ChatStreamReducer.fail(&state, "Can't reach the server")
        XCTAssertTrue(state.message.isError)
        XCTAssertFalse(state.message.streaming)
        XCTAssertEqual(state.message.plainText, "Can't reach the server")
        XCTAssertEqual(state.outcome, .failed("Can't reach the server"))
    }

    func testFailKeepsPartialTextAboveTheError() {
        _ = apply("delta", ["text": "half an answer"])
        ChatStreamReducer.fail(&state, "connection lost")
        XCTAssertEqual(state.message.plainText, "half an answer\n\nconnection lost")
    }

    // MARK: history fallback

    func testAdoptingASnapshotFillsAnEmptyTurnFromTheServersRecord() {
        let snap = SessionSnapshot(activeStreamID: nil, lastAssistantText: "server's copy", lastToolNames: ["search"])
        XCTAssertTrue(ChatStreamReducer.adopt(snap, into: &state))
        XCTAssertEqual(state.message.plainText, "server's copy")
    }

    func testAdoptingASnapshotNeverOverwritesWhatWeAlreadyStreamed() {
        _ = apply("delta", ["text": "ours"])
        let snap = SessionSnapshot(activeStreamID: nil, lastAssistantText: "server's copy", lastToolNames: [])
        XCTAssertFalse(ChatStreamReducer.adopt(snap, into: &state))
        XCTAssertEqual(state.message.plainText, "ours")
    }
}

/// The 45-second silence watchdog. The server's per-turn event queue is
/// single-consumer, so another client draining it leaves our socket open and
/// empty — indistinguishable from a wedged turn until the clock says otherwise.
final class ChatStallDetectorTests: XCTestCase {

    func testSilenceLongerThanTheLimitSurfacesAsStalled() async {
        let clock = ManualChatClock()
        let (upstream, feed) = AsyncThrowingStream<Int, Error>.makeStream()
        let collector = StreamCollector<Int>()
        collector.consume(withStallDetection(upstream, limit: 45, step: 5, clock: clock))

        feed.yield(1)
        await waitUntil("the first event to arrive") { collector.all == [1] }
        await waitUntil("the watchdog to park") { clock.parked > 0 }
        clock.advance(50)

        await waitUntil("the stall to surface") { collector.error != nil }
        XCTAssertEqual(collector.error as? ChatStreamError, .stalled)
        XCTAssertEqual(collector.all, [1], "whatever arrived before the silence is kept")
        feed.finish()
    }

    func testAStreamThatKeepsTalkingNeverStalls() async {
        let clock = ManualChatClock()
        let (upstream, feed) = AsyncThrowingStream<Int, Error>.makeStream()
        let collector = StreamCollector<Int>()
        collector.consume(withStallDetection(upstream, limit: 45, step: 5, clock: clock))

        for i in 1...3 {
            feed.yield(i)
            await waitUntil("event \(i)") { collector.all.count == i }
            await waitUntil("the watchdog to park") { clock.parked > 0 }
            clock.advance(40)   // under the limit, every time
        }
        feed.finish()
        await waitUntil("the stream to end") { collector.finished }
        XCTAssertNil(collector.error)
        XCTAssertEqual(collector.all, [1, 2, 3])
    }

    func testTheUpstreamsOwnFailureIsPassedThroughUnchanged() async {
        let clock = ManualChatClock()
        let (upstream, feed) = AsyncThrowingStream<Int, Error>.makeStream()
        let collector = StreamCollector<Int>()
        collector.consume(withStallDetection(upstream, limit: 45, step: 5, clock: clock))

        feed.finish(throwing: APIError.http(status: 500, message: "boom"))
        await waitUntil("the failure to surface") { collector.error != nil }
        XCTAssertEqual(collector.error as? APIError, .http(status: 500, message: "boom"))
        clock.releaseAll()
    }

    func testACleanEndOfStreamIsNotAStall() async {
        let clock = ManualChatClock()
        let (upstream, feed) = AsyncThrowingStream<Int, Error>.makeStream()
        let collector = StreamCollector<Int>()
        collector.consume(withStallDetection(upstream, limit: 45, step: 5, clock: clock))

        feed.yield(7)
        feed.finish()
        await waitUntil("the stream to end") { collector.finished }
        XCTAssertNil(collector.error)
        XCTAssertEqual(collector.all, [7])
        clock.releaseAll()
    }
}

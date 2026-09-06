import XCTest
@testable import JarvisCopilot

final class CodingStreamReducerTests: XCTestCase {

    private func msg(_ i: Int, _ role: String = "assistant", _ text: String = "") -> CodingChatMessage {
        CodingChatMessage(i: i, role: role, text: text.isEmpty ? "m\(i)" : text)
    }

    private func transcript(_ count: Int) -> CodingTranscript {
        var t = CodingTranscript()
        t.messages = (0..<count).map { msg($0) }
        t.loading = false
        return t
    }

    // MARK: - Cursor / reconcile cadence

    func testCursorIsTheTailWeHoldUnlessReconciling() {
        let t = transcript(7)
        XCTAssertEqual(CodingStreamReducer.cursor(t, full: false), 7)
        XCTAssertEqual(CodingStreamReducer.cursor(t, full: true), 0)
    }

    func testEveryTwelfthIncrementalPollReconciles() {
        XCTAssertFalse(CodingStreamReducer.shouldFullReconcile(tick: 1))
        XCTAssertFalse(CodingStreamReducer.shouldFullReconcile(tick: 11))
        XCTAssertTrue(CodingStreamReducer.shouldFullReconcile(tick: 12))
        XCTAssertTrue(CodingStreamReducer.shouldFullReconcile(tick: 24))
    }

    // MARK: - Merging pages

    func testFullPageReplacesEverything() {
        var t = transcript(3)
        let page = CodingChatPage(messages: [msg(0, "user", "hi")], total: 1,
                                  activityState: "idle", status: "running")
        let outcome = CodingStreamReducer.apply(page, full: true, to: &t)
        XCTAssertEqual(outcome, .applied(hadNew: true, hadNewAssistant: false))
        XCTAssertEqual(t.messages.map(\.i), [0])
        XCTAssertEqual(t.messages[0].text, "hi")
        XCTAssertEqual(t.activityState, "idle")
        XCTAssertEqual(t.status, "running")
        XCTAssertFalse(t.loading)
        XCTAssertFalse(t.noTranscript)
    }

    func testIncrementalPageAppendsTheTail() {
        var t = transcript(2)
        let page = CodingChatPage(messages: [msg(2, "user", "next")], total: 3,
                                  activityState: "working")
        let outcome = CodingStreamReducer.apply(page, full: false, to: &t)
        XCTAssertEqual(outcome, .applied(hadNew: true, hadNewAssistant: false))
        XCTAssertEqual(t.messages.map(\.i), [0, 1, 2])
        XCTAssertEqual(t.messages[2].text, "next")
        XCTAssertEqual(t.activityState, "working")
    }

    func testANewAssistantMessageIsFlaggedSoTheThinkingBubbleRetires() {
        var t = transcript(2)
        let page = CodingChatPage(messages: [msg(2)], total: 3)
        XCTAssertEqual(CodingStreamReducer.apply(page, full: false, to: &t),
                       .applied(hadNew: true, hadNewAssistant: true))
    }

    func testATailOfTwoOrMoreTakesTheFullReloadPath() {
        // The Flutter guard measures every index against the PRE-merge length, so
        // a two-message tail (i == count and i == count + 1) reads as a gap and
        // heals with a full reload. Wasteful but never lossy — kept for parity.
        var t = transcript(2)
        let page = CodingChatPage(messages: [msg(2), msg(3)], total: 4)
        XCTAssertEqual(CodingStreamReducer.apply(page, full: false, to: &t), .needsFullReload)
        XCTAssertEqual(t.messages.count, 2, "the old list stands until the reload lands")
    }

    func testAnExistingMessageIsUpdatedInPlace() {
        // The server rewrites a message when a tool result lands.
        var t = transcript(3)
        let updated = CodingChatMessage(i: 1, role: "assistant", text: "now with text",
                                        tools: [CodingChatTool(name: "Read", ok: true)])
        let page = CodingChatPage(messages: [updated], total: 3)
        let outcome = CodingStreamReducer.apply(page, full: false, to: &t)
        XCTAssertEqual(outcome, .applied(hadNew: false, hadNewAssistant: false),
                       "an in-place update must not trigger an auto-scroll")
        XCTAssertEqual(t.messages.count, 3)
        XCTAssertEqual(t.messages[1].text, "now with text")
        XCTAssertEqual(t.messages[1].tools.count, 1)
    }

    func testAShrunkHistoryAsksForAFullReload() {
        // /clear or a re-parse server-side.
        var t = transcript(5)
        let page = CodingChatPage(messages: [], total: 2)
        XCTAssertEqual(CodingStreamReducer.apply(page, full: false, to: &t), .needsFullReload)
        XCTAssertEqual(t.messages.count, 5, "the old list is kept until the reload lands")
    }

    func testAnIndexGapAsksForAFullReload() {
        var t = transcript(2)
        // We hold 0…1 but the server hands us index 5 — something was missed.
        let page = CodingChatPage(messages: [msg(5)], total: 6)
        XCTAssertEqual(CodingStreamReducer.apply(page, full: false, to: &t), .needsFullReload)
    }

    func testAFullPageNeverAsksForAReload() {
        var t = transcript(5)
        let page = CodingChatPage(messages: [msg(0), msg(9)], total: 2)
        XCTAssertEqual(CodingStreamReducer.apply(page, full: true, to: &t),
                       .applied(hadNew: true, hadNewAssistant: false))
    }

    func testAnEmptyIncrementalPageIsANoOp() {
        var t = transcript(3)
        let before = t
        let page = CodingChatPage(messages: [], total: 3, activityState: "idle", status: "idle")
        XCTAssertEqual(CodingStreamReducer.apply(page, full: false, to: &t),
                       .applied(hadNew: false, hadNewAssistant: false))
        XCTAssertEqual(t.messages, before.messages)
        XCTAssertEqual(t.activityState, "idle")
    }

    func testAPageWithoutAContextGaugeKeepsTheOldOne() {
        var t = transcript(1)
        t.context = ChatContext(used: 100, window: 200_000, pct: 1)
        _ = CodingStreamReducer.apply(CodingChatPage(total: 1), full: false, to: &t)
        XCTAssertEqual(t.context?.used, 100)
        _ = CodingStreamReducer.apply(
            CodingChatPage(total: 1, context: ChatContext(used: 500, window: 200_000, pct: 1)),
            full: false, to: &t)
        XCTAssertEqual(t.context?.used, 500)
    }

    // MARK: - Failures

    func testA409MeansNoTranscriptYet() {
        var t = transcript(3)
        CodingStreamReducer.applyFetchFailure(APIError.http(status: 409, message: "no transcript"), to: &t)
        XCTAssertTrue(t.noTranscript)
        XCTAssertTrue(t.messages.isEmpty)
        XCTAssertFalse(t.loading)
    }

    func testOtherFailuresKeepTheTranscript() {
        var t = transcript(3)
        CodingStreamReducer.applyFetchFailure(APIError.http(status: 502, message: ""), to: &t)
        XCTAssertFalse(t.noTranscript)
        XCTAssertEqual(t.messages.count, 3)
        XCTAssertFalse(t.loading, "the spinner still has to stop")
        CodingStreamReducer.applyFetchFailure(URLError(.timedOut), to: &t)
        XCTAssertEqual(t.messages.count, 3)
    }

    // MARK: - Live state derived from the page

    func testIsLivePrefersTheMessagesStatusAndIsNilWhenAbsent() {
        var t = CodingTranscript()
        XCTAssertNil(t.isLive, "no status yet ⇒ fall back to the polled detail")
        t.status = "running"
        XCTAssertEqual(t.isLive, true)
        t.status = "idle"
        XCTAssertEqual(t.isLive, true)
        t.status = "stopped"
        XCTAssertEqual(t.isLive, false)
    }

    func testPollIntervalTracksTheLiveState() {
        XCTAssertEqual(CodingStreamReducer.pollInterval(activityState: "working", showThinking: false), 2.5)
        XCTAssertEqual(CodingStreamReducer.pollInterval(activityState: "waiting", showThinking: false), 2.5)
        XCTAssertEqual(CodingStreamReducer.pollInterval(activityState: nil, showThinking: true), 2.5)
        XCTAssertEqual(CodingStreamReducer.pollInterval(activityState: "idle", showThinking: false), 4)
        XCTAssertEqual(CodingStreamReducer.pollInterval(activityState: nil, showThinking: false), 4)
    }

    // MARK: - The thinking bubble

    func testShowThinking() {
        let now = Date(timeIntervalSince1970: 1_781_006_400)
        // The real state wins.
        XCTAssertTrue(CodingStreamReducer.showThinking(activityState: "working", messageCount: 2,
                                                       localWorkingUntil: nil, now: now))
        // Waiting for input is never "thinking".
        XCTAssertFalse(CodingStreamReducer.showThinking(activityState: "waiting", messageCount: 2,
                                                        localWorkingUntil: now.addingTimeInterval(5), now: now))
        // An empty transcript shows nothing.
        XCTAssertFalse(CodingStreamReducer.showThinking(activityState: "working", messageCount: 0,
                                                        localWorkingUntil: nil, now: now))
        // The optimistic window covers the ~5s pane-scan lag…
        XCTAssertTrue(CodingStreamReducer.showThinking(activityState: "idle", messageCount: 1,
                                                       localWorkingUntil: now.addingTimeInterval(1), now: now))
        // …and then expires.
        XCTAssertFalse(CodingStreamReducer.showThinking(activityState: "idle", messageCount: 1,
                                                        localWorkingUntil: now.addingTimeInterval(-1), now: now))
        XCTAssertFalse(CodingStreamReducer.showThinking(activityState: nil, messageCount: 1,
                                                        localWorkingUntil: nil, now: now))
    }

    func testRetireLocalWorking() {
        XCTAssertTrue(CodingStreamReducer.retireLocalWorking(activityState: "working", hadNewAssistant: false))
        XCTAssertTrue(CodingStreamReducer.retireLocalWorking(activityState: "waiting", hadNewAssistant: false))
        // A fast reply can go straight back to idle — the new answer retires it.
        XCTAssertTrue(CodingStreamReducer.retireLocalWorking(activityState: "idle", hadNewAssistant: true))
        XCTAssertFalse(CodingStreamReducer.retireLocalWorking(activityState: "idle", hadNewAssistant: false))
        XCTAssertFalse(CodingStreamReducer.retireLocalWorking(activityState: nil, hadNewAssistant: false))
    }

    // MARK: - Queued sends

    func testAQueuedSendIsRetiredByItsEcho() {
        let now = Date(timeIntervalSince1970: 1_781_006_400)
        let pending = [PendingSend(text: "  run the tests  ", ts: now.addingTimeInterval(-3)),
                       PendingSend(text: "and lint", ts: now.addingTimeInterval(-2))]
        let page = CodingChatPage(messages: [CodingChatMessage(i: 4, role: "user", text: "run the tests")])
        let left = CodingStreamReducer.expirePendingSends(pending, page: page, messages: [], now: now)
        XCTAssertEqual(left.map(\.text), ["and lint"], "the echo is matched on trimmed text")
    }

    func testAQueuedSendIsAlsoRetiredByTheMergedTranscript() {
        let now = Date()
        let pending = [PendingSend(text: "hello", ts: now)]
        let merged = [CodingChatMessage(i: 0, role: "user", text: "hello ")]
        XCTAssertTrue(CodingStreamReducer.expirePendingSends(pending, page: CodingChatPage(),
                                                             messages: merged, now: now).isEmpty)
    }

    func testAnAssistantEchoDoesNotRetireASend() {
        let now = Date()
        let pending = [PendingSend(text: "hello", ts: now)]
        let page = CodingChatPage(messages: [CodingChatMessage(i: 0, role: "assistant", text: "hello")])
        XCTAssertEqual(CodingStreamReducer.expirePendingSends(pending, page: page, messages: [],
                                                              now: now).count, 1)
    }

    func testQueuedSendsExpireOnTimeAndSlashCommandsExpireFast() {
        let now = Date(timeIntervalSince1970: 1_781_006_400)
        let slash = PendingSend(text: "/compact", ts: now.addingTimeInterval(-26))
        let text = PendingSend(text: "keep me", ts: now.addingTimeInterval(-26))
        let old = PendingSend(text: "too old", ts: now.addingTimeInterval(-91))
        let left = CodingStreamReducer.expirePendingSends([slash, text, old],
                                                          page: CodingChatPage(), messages: [], now: now)
        XCTAssertEqual(left.map(\.text), ["keep me"])
        XCTAssertEqual(slash.lifetime, 25)
        XCTAssertEqual(text.lifetime, 90)
    }

    // MARK: - Terminal frames

    func testTerminalEventParsing() {
        XCTAssertEqual(CodingTerminalEvent(["event": "output", "text": "hi"]), .output("hi"))
        XCTAssertEqual(CodingTerminalEvent(["event": "output"]), .output(""))
        XCTAssertEqual(CodingTerminalEvent(["event": "terminal_closed", "reason": "ended"]),
                       .closed(reason: "ended"))
        XCTAssertEqual(CodingTerminalEvent(["event": "terminal_closed"]), .closed(reason: ""))
        XCTAssertEqual(CodingTerminalEvent(["event": "terminal_error", "error": "pty gone"]),
                       .failed(message: "pty gone"))
        XCTAssertEqual(CodingTerminalEvent(["event": "ping"]), .other("ping"))
        XCTAssertEqual(CodingTerminalEvent([:]), .other("message"))
    }

    func testCloseNoticesExplainWhatHappened() {
        XCTAssertTrue(CodingTerminalEvent.notice(closedBecause: "ended").contains("session ended"))
        XCTAssertTrue(CodingTerminalEvent.notice(closedBecause: "reconnecting").contains("retrying"))
        XCTAssertTrue(CodingTerminalEvent.notice(closedBecause: "disconnected").contains("dropped its connection"))
        XCTAssertTrue(CodingTerminalEvent.notice(closedBecause: "").contains("detached"))
        XCTAssertTrue(CodingTerminalEvent.notice(error: "boom").contains("[terminal error: boom]"))
        // The notices are terminal frames, CRLF-wrapped like the Flutter build.
        XCTAssertTrue(CodingTerminalEvent.notice(closedBecause: "ended").hasPrefix("\r\n"))
    }

    func testOnlyASoftReconnectHealsItself() {
        XCTAssertTrue(CodingTerminalEvent.shouldReattach(afterCloseReason: "reconnecting"))
        XCTAssertFalse(CodingTerminalEvent.shouldReattach(afterCloseReason: "ended"))
        XCTAssertFalse(CodingTerminalEvent.shouldReattach(afterCloseReason: "disconnected"))
    }

    func testReattachBackoffIsBounded() {
        XCTAssertEqual(CodingTerminalEvent.reattachDelay(attempt: 1), 1.5)
        XCTAssertEqual(CodingTerminalEvent.reattachDelay(attempt: 4), 6)
        XCTAssertNil(CodingTerminalEvent.reattachDelay(attempt: 5),
                     "a truly offline Mac must not loop forever")
        XCTAssertNil(CodingTerminalEvent.reattachDelay(attempt: 0))
    }
}

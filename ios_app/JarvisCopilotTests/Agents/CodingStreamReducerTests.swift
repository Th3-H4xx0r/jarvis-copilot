import XCTest
@testable import JarvisCopilot

/// The session screen's transcript reducer (lifted from the old Coding tab).
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

    /// A poll re-reads the last message we hold (the server grows a turn in
    /// place) and anything past it; a reconcile re-reads the window.
    func testCursorIsTheLastMessageWeHoldUnlessReconciling() {
        let t = transcript(7)
        XCTAssertEqual(CodingStreamReducer.cursor(t, full: false), 6)
        XCTAssertEqual(CodingStreamReducer.cursor(t, full: true), 0)
        XCTAssertEqual(CodingStreamReducer.cursor(CodingTranscript(), full: false), 0)
    }

    /// The server folds a whole agent turn into one message: polls must keep
    /// re-reading it, or tool results and the final answer never appear (sweep).
    func testPollsReReadTheGrowingLastMessage() {
        var t = window(60..<100)
        XCTAssertEqual(CodingStreamReducer.cursor(t, full: false), 99)
        let grown = CodingChatPage(messages: [msg(99, "assistant", "All 12 tests pass.")], total: 100)
        _ = CodingStreamReducer.apply(grown, full: false, to: &t)
        XCTAssertEqual(t.messages.last?.text, "All 12 tests pass.")
        XCTAssertEqual(t.messages.count, 40)
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

    func testATailOfTwoOrMoreIsAppended() {
        // A prompt and its answer often land in one fetch. That's no gap: a
        // full reload here re-downloaded the whole window every turn.
        var t = transcript(2)
        let page = CodingChatPage(messages: [msg(1), msg(2), msg(3)], total: 4, start: 1)
        XCTAssertEqual(CodingStreamReducer.apply(page, full: false, to: &t),
                       .applied(hadNew: true, hadNewAssistant: true))
        XCTAssertEqual(t.messages.map(\.i), [0, 1, 2, 3])
    }

    // MARK: - A copy still on its way from the Mac

    func testASyncingPageKeepsWhatIsShown() {
        var t = transcript(3)
        let page = CodingChatPage(syncing: CodingSyncProgress(have: 5, of: 50))
        XCTAssertEqual(CodingStreamReducer.apply(page, full: false, to: &t),
                       .applied(hadNew: false, hadNewAssistant: false))
        XCTAssertEqual(t.messages.map(\.i), [0, 1, 2], "not its oldest part")
        XCTAssertEqual(t.syncing, CodingSyncProgress(have: 5, of: 50))
    }

    func testAChatWhoseCopyIsOnItsWayWaitsForItThenOpensOnItsEnd() {
        var t = CodingTranscript()
        _ = CodingStreamReducer.apply(CodingChatPage(syncing: CodingSyncProgress(have: 5, of: 50)),
                                      full: true, to: &t)
        XCTAssertTrue(t.messages.isEmpty)
        XCTAssertFalse(t.loading)
        XCTAssertEqual(CodingStreamReducer.limit(t, paged: true), CodingStreamReducer.pageSize,
                       "the next fetch still asks for the last page")
        _ = CodingStreamReducer.apply(CodingChatPage(messages: (60..<100).map { msg($0) }, total: 100,
                                                     start: 60), full: true, to: &t)
        XCTAssertNil(t.syncing)
        XCTAssertEqual(t.start, 60)
    }

    func testThePageSaysHowFarTheCopyIs() {
        let page = CodingChatPage(json: ["messages": [], "total": 0, "syncing": ["have": 5, "of": 50]])
        XCTAssertEqual(page.syncing, CodingSyncProgress(have: 5, of: 50))
        XCTAssertEqual(page.syncing?.fraction ?? 0, 0.1, accuracy: 0.0001)
        XCTAssertNil(CodingChatPage(json: ["messages": [], "total": 0]).syncing)
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

    // MARK: - Paging (a long chat opens on its last page)

    private func window(_ range: Range<Int>) -> CodingTranscript {
        var t = CodingTranscript()
        t.start = range.lowerBound
        t.messages = range.map { msg($0) }
        t.loading = false
        return t
    }

    func testTheFirstPageIsTheTailAndPollsAskOnlyForWhatIsNew() {
        var t = CodingTranscript()
        XCTAssertEqual(CodingStreamReducer.cursor(t, full: false), 0)
        XCTAssertEqual(CodingStreamReducer.limit(t, paged: true), CodingStreamReducer.pageSize)
        XCTAssertNil(CodingStreamReducer.limit(t, paged: false))       // the Coding chat keeps its whole window
        let first = CodingChatPage(messages: (60..<100).map { msg($0) }, total: 100, start: 60)
        _ = CodingStreamReducer.apply(first, full: true, to: &t)
        XCTAssertEqual(t.start, 60)
        XCTAssertTrue(t.hasOlder)
        XCTAssertEqual(CodingStreamReducer.cursor(t, full: false), 99)   // the last message, and what's new
        XCTAssertEqual(CodingStreamReducer.cursor(t, full: true), 60)  // a reconcile re-reads the window we hold
        XCTAssertNil(CodingStreamReducer.limit(t, paged: true))        // only the first page is limited
        let next = CodingChatPage(messages: [msg(70, "assistant", "edited"), msg(100, "user", "new")], total: 101)
        XCTAssertEqual(CodingStreamReducer.apply(next, full: false, to: &t), .applied(hadNew: true, hadNewAssistant: false))
        XCTAssertEqual(t.messages.first?.i, 60)
        XCTAssertEqual(t.messages.last?.i, 100)
        XCTAssertEqual(t.messages[10].text, "edited")
    }

    func testScrollingUpPrependsThePageAbove() {
        var t = window(60..<100)
        XCTAssertEqual(CodingStreamReducer.before(t), 60)
        let older = CodingChatPage(messages: (20..<60).map { msg($0) }, total: 100, start: 20)
        XCTAssertTrue(CodingStreamReducer.applyOlder(older, to: &t))
        XCTAssertEqual(t.start, 20)
        XCTAssertEqual(t.messages.map(\.i), Array(20..<100))
        // A page that doesn't end right above what we hold isn't stitched in.
        var u = window(60..<100)
        let off = CodingChatPage(messages: (10..<50).map { msg($0) }, total: 100, start: 10)
        XCTAssertFalse(CodingStreamReducer.applyOlder(off, to: &u))
        XCTAssertEqual(u.start, 60)
        XCTAssertEqual(u.messages.count, 40)
    }

    func testAWindowHealsGapsAndShrinksAgainstItsEnd() {
        var t = window(60..<100)
        XCTAssertEqual(CodingStreamReducer.apply(CodingChatPage(messages: [msg(102)], total: 103), full: false, to: &t),
                       .needsFullReload)
        XCTAssertEqual(CodingStreamReducer.apply(CodingChatPage(messages: [], total: 90), full: false, to: &t),
                       .needsFullReload)
    }

    /// Past the server's cap (400) a reply starts mid-transcript, and an older
    /// server says so only through the indices: polls must not reload forever.
    func testALongTranscriptFromAnOlderServerKeepsItsWindow() {
        var t = CodingTranscript()
        let capped = CodingChatPage(messages: (360..<760).map { msg($0) }, total: 760)   // no `start`
        _ = CodingStreamReducer.apply(capped, full: true, to: &t)
        XCTAssertEqual(t.start, 360)
        XCTAssertEqual(CodingStreamReducer.apply(CodingChatPage(messages: [], total: 760), full: false, to: &t),
                       .applied(hadNew: false, hadNewAssistant: false))
    }
}


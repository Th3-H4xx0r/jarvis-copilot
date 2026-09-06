import XCTest
@testable import JarvisCopilot

/// Spin until `condition` holds — the terminal pump and the SSE stream run in
/// their own tasks. (Named for this area: the Chat tests declare an internal
/// `waitUntil` with the same signature, and even a `private` twin collides.)
@MainActor
private func codingWaitUntil(_ description: String, timeout: TimeInterval = 3,
                       file: StaticString = #filePath, line: UInt = #line,
                       _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("timed out waiting for \(description)", file: file, line: line)
}

private func query(_ request: URLRequest?) -> [String: String] {
    guard let url = request?.url,
          let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [:] }
    var out: [String: String] = [:]
    for item in comps.queryItems ?? [] { out[item.name] = item.value ?? "" }
    return out
}

@MainActor
final class CodingSessionStoreTests: XCTestCase {

    private func makeStore(visible: @escaping () -> Bool = { true })
        -> (CodingSessionStore, MockTransport) {
        let (client, transport) = JarvisAPI.mocked()
        return (CodingSessionStore(sessionId: "s1", api: CodingSessionsAPI(api: client),
                                   isVisible: visible), transport)
    }

    private func page(_ messages: [[String: Any]], total: Int,
                      activity: String? = nil, status: String = "running") -> [String: Any] {
        var out: [String: Any] = ["messages": messages, "total": total, "status": status]
        if let activity { out["activity_state"] = activity }
        return out
    }

    // MARK: - Transcript fetching

    func testFirstFetchLoadsTheWholeTranscript() async {
        let (store, t) = makeStore()
        t.enqueue(json: page([["i": 0, "role": "user", "text": "hi"],
                              ["i": 1, "role": "assistant", "text": "hello"]],
                             total: 2, activity: "idle"))
        await store.fetch(full: true)
        XCTAssertEqual(query(t.lastRequest), ["after": "0"])
        XCTAssertEqual(store.transcript.messages.map(\.i), [0, 1])
        XCTAssertEqual(store.transcript.activityState, "idle")
        XCTAssertEqual(store.transcript.isLive, true)
        XCTAssertFalse(store.transcript.loading)
        XCTAssertEqual(store.appendTick, 1)
    }

    func testIncrementalFetchAsksOnlyForTheTail() async {
        let (store, t) = makeStore()
        t.enqueue(json: page([["i": 0, "role": "user", "text": "hi"]], total: 1))
        await store.fetch(full: true)
        t.enqueue(json: page([["i": 1, "role": "assistant", "text": "reply"]], total: 2))
        await store.fetch()
        XCTAssertEqual(query(t.lastRequest), ["after": "1"])
        XCTAssertEqual(store.transcript.messages.map(\.text), ["hi", "reply"])
        XCTAssertEqual(store.appendTick, 2)
    }

    func testAServerRewindHealsWithOneFullReload() async {
        let (store, t) = makeStore()
        t.enqueue(json: page([["i": 0], ["i": 1], ["i": 2]], total: 3))
        await store.fetch(full: true)
        XCTAssertEqual(store.transcript.messages.count, 3)

        // /clear ran on the Mac: the incremental reply reports a shorter history…
        t.enqueue(json: page([], total: 0))
        // …so the store immediately refetches everything.
        t.enqueue(json: page([["i": 0, "role": "user", "text": "fresh start"]], total: 1))
        await store.fetch()
        XCTAssertEqual(query(t.lastRequest), ["after": "0"], "the heal refetches from scratch")
        XCTAssertEqual(store.transcript.messages.map(\.text), ["fresh start"])
    }

    func testAnIndexGapHealsWithAFullReload() async {
        let (store, t) = makeStore()
        t.enqueue(json: page([["i": 0]], total: 1))
        await store.fetch(full: true)
        t.enqueue(json: page([["i": 4, "role": "assistant", "text": "late"]], total: 5))
        t.enqueue(json: page([["i": 0], ["i": 1], ["i": 2], ["i": 3],
                              ["i": 4, "role": "assistant", "text": "late"]], total: 5))
        await store.fetch()
        XCTAssertEqual(store.transcript.messages.count, 5, "no message may vanish into a gap")
    }

    func testA409ShowsTheNoTranscriptState() async {
        let (store, t) = makeStore()
        t.enqueue(json: ["error": "no transcript yet"], status: 409)
        await store.fetch(full: true)
        XCTAssertTrue(store.transcript.noTranscript)
        XCTAssertTrue(store.transcript.messages.isEmpty)
        XCTAssertFalse(store.transcript.loading)
    }

    func testATransientFetchFailureKeepsTheMessages() async {
        let (store, t) = makeStore()
        t.enqueue(json: page([["i": 0, "role": "user", "text": "hi"]], total: 1))
        await store.fetch(full: true)
        t.enqueue(json: ["error": "bad gateway"], status: 502)
        await store.fetch()
        XCTAssertEqual(store.transcript.messages.count, 1)
        XCTAssertFalse(store.transcript.noTranscript)
    }

    func testPollTickDoesNoNetworkWorkWhileHidden() async {
        var visible = false
        let (store, t) = makeStore(visible: { visible })
        let value1 = await store.pollTick()
        XCTAssertFalse(value1)
        XCTAssertTrue(t.requests.isEmpty)

        visible = true
        t.enqueue(json: page([["i": 0]], total: 1))
        let value2 = await store.pollTick()
        XCTAssertTrue(value2)
        XCTAssertEqual(t.requests.count, 1)
    }

    // MARK: - Interactive prompt

    func testAWaitingSessionPopsThePromptOnceAndNotAgainAfterDismissal() async {
        let (store, t) = makeStore()
        let waitingPage = page([["i": 0, "role": "user", "text": "delete it"]],
                               total: 1, activity: "waiting")
        let promptBody: [String: Any] = [
            "waiting": true, "question": "Do you want to make this edit?",
            "options": [["key": "1", "label": "Yes"], ["key": "2", "label": "No"]],
            "raw": "╭─ Edit ─╮",
        ]
        // fetch → prompt, then the dismissal's refetch → prompt again.
        t.enqueue(json: waitingPage)
        t.enqueue(json: promptBody)
        t.enqueue(json: waitingPage)
        t.enqueue(json: promptBody)

        await store.fetch(full: true)
        XCTAssertTrue(store.shouldPresentPrompt)
        XCTAssertEqual(store.prompt?.options.map(\.key), ["1", "2"])
        let signature = store.prompt!.signature

        await store.promptSheetClosed(store.prompt!)
        XCTAssertEqual(store.dismissedPromptSignature, signature)
        XCTAssertFalse(store.shouldPresentPrompt,
                       "the same prompt must not re-pop while the pane scan catches up")
        XCTAssertFalse(store.promptOpen)
    }

    func testAResolvedPromptIsForgottenSoTheNextOnePopsFresh() async {
        let (store, t) = makeStore()
        t.enqueue(json: page([["i": 0]], total: 1, activity: "waiting"))
        t.enqueue(json: ["waiting": true, "question": "Run this?"])
        await store.fetch(full: true)
        XCTAssertNotNil(store.prompt)

        t.enqueue(json: page([], total: 1, activity: "idle"))
        await store.fetch()
        XCTAssertNil(store.prompt)
        XCTAssertNil(store.dismissedPromptSignature)
        XCTAssertFalse(store.shouldPresentPrompt)
    }

    func testPromptForBannerFetchesOnDemand() async {
        let (store, t) = makeStore()
        t.enqueue(json: ["waiting": true, "question": "Run this?"])
        let p = await store.promptForBanner()
        XCTAssertEqual(p?.question, "Run this?")
        // A non-waiting reply gives nothing to show.
        let (store2, t2) = makeStore()
        t2.enqueue(json: ["waiting": false])
        let value3 = await store2.promptForBanner()
        XCTAssertNil(value3)
    }

    // MARK: - Input through the PTY

    func testSendTextTypesTheBytesThenEnterAndQueuesABubble() async {
        let (store, t) = makeStore()
        t.route("/terminal/start", json: ["ok": true])
        t.route("/api/terminal/input", json: ["ok": true])
        t.enqueueSSE("") // the attach's output stream
        let value4 = await store.sendText("run the tests")
        XCTAssertTrue(value4)
        XCTAssertEqual(store.pendingSends.map(\.text), ["run the tests"])
        let inputs = t.requests
            .filter { $0.url?.path == "/api/terminal/input" }
            .compactMap { $0.httpBody }
            .compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            .compactMap { $0["data"] as? String }
        XCTAssertEqual(inputs, ["run the tests", "\r"])
    }

    func testSendRawGoesStraightToThePTYAndMarksClaudeWorking() async {
        let (store, t) = makeStore()
        t.route("/terminal/start", json: ["ok": true])
        t.route("/api/terminal/input", json: ["ok": true])
        // A transcript with a message is needed for the thinking bubble to show.
        t.enqueue(json: page([["i": 0, "role": "user", "text": "hi"]], total: 1, activity: "idle"))
        t.enqueueSSE("") // the attach's output stream
        await store.fetch(full: true)
        XCTAssertFalse(store.showThinking)
        let value5 = await store.sendRaw("1")
        XCTAssertTrue(value5)
        XCTAssertTrue(store.showThinking, "answering a prompt puts Claude back to work")
    }

    func testSendTerminalInputReattachesInsteadOfSilentlyNoOping() async {
        let (store, t) = makeStore()
        t.route("/terminal/start", json: ["ok": true])
        t.route("/api/terminal/input", json: ["ok": true])
        t.enqueueSSE("") // the attach's output stream
        XCTAssertFalse(store.terminalAttached)
        let value6 = await store.sendTerminalInput("q")
        XCTAssertTrue(value6)
        XCTAssertTrue(store.terminalAttached)
        let value7 = await store.sendTerminalInput("")
        XCTAssertFalse(value7, "empty input is never sent")
    }

    func testSendTerminalInputReportsAFailedPost() async {
        let (store, t) = makeStore()
        t.route("/terminal/start", json: ["ok": true])
        t.route("/api/terminal/input", json: ["error": "gone"], status: 500)
        t.enqueueSSE("") // the attach's output stream
        let value8 = await store.sendTerminalInput("q")
        XCTAssertFalse(value8)
        // A keystroke that never lands has to say so somewhere: the key bar and
        // the prompt sheet have no other channel.
        XCTAssertEqual(store.terminalError, "Keystrokes aren’t reaching the session: gone")
    }

    func testSendComposerUploadsAttachmentsThenTypesTheMessage() async {
        let (store, t) = makeStore()
        t.route("/api/coding/upload", json: ["path": "/srv/up/shot.png"])
        t.route("/terminal/start", json: ["ok": true])
        t.route("/api/terminal/input", json: ["ok": true])
        t.enqueueSSE("") // the attach's output stream
        store.attachments.add(name: "shot.png", data: Data("PNG".utf8))
        let r = await store.sendComposer("  look at this  ")
        XCTAssertTrue(r.sent)
        XCTAssertEqual(r.failed, 0)
        XCTAssertEqual(store.pendingSends.map(\.text), ["look at this @/srv/up/shot.png"])
        XCTAssertTrue(store.attachments.isEmpty)
    }

    func testSendComposerIgnoresAnEmptyComposer() async {
        let (store, t) = makeStore()
        let r = await store.sendComposer("   ")
        XCTAssertFalse(r.sent)
        XCTAssertTrue(t.requests.isEmpty)
    }

    func testTheCommandSheetOffersTheClaudeCodeSlashCommands() {
        XCTAssertEqual(CodingSessionStore.commands.map(\.command),
                       ["/compact", "/clear", "/context", "/cost", "/model", "/todos"])
    }

    // MARK: - Live terminal

    func testTerminalOutputLandsInTheBuffer() async {
        let (store, t) = makeStore()
        t.route("/terminal/start", json: ["ok": true])
        t.enqueueSSE("""
        event: output
        data: {"text":"$ swift build\\r\\n"}

        event: output
        data: {"text":"Compiling\\u001b[0m done\\r\\n"}


        """)
        await store.startTerminal(rows: 30, cols: 100)
        XCTAssertTrue(store.terminalAttached)
        XCTAssertNil(store.terminalError)
        XCTAssertEqual(store.terminal.rows, 30)
        XCTAssertEqual(store.terminal.cols, 100)
        await codingWaitUntil("the second frame to arrive") { store.terminal.text.contains("done") }
        XCTAssertEqual(store.terminal.lines, ["$ swift build", "Compiling done", ""])
        XCTAssertGreaterThan(store.outputTick, 1)
    }

    func testAClosedTerminalWritesANoticeAndResetsTheAttachGuard() async {
        let (store, t) = makeStore()
        t.route("/terminal/start", json: ["ok": true])
        t.enqueueSSE("""
        event: output
        data: {"text":"bye\\r\\n"}

        event: terminal_closed
        data: {"reason":"ended"}


        """)
        await store.startTerminal()
        await codingWaitUntil("the close notice") { !store.terminalAttached }
        XCTAssertTrue(store.terminal.text.contains("[session ended"))
        XCTAssertFalse(store.terminalStarting)
        // The guard is clear, so re-tapping the session can attach again (the old
        // bug left it set and reopen was a no-op forever).
        t.enqueueSSE("")
        await store.startTerminal()
        XCTAssertTrue(store.terminalAttached)
    }

    func testATerminalErrorFrameIsShownInline() async {
        let (store, t) = makeStore()
        t.route("/terminal/start", json: ["ok": true])
        t.enqueueSSE("""
        event: terminal_error
        data: {"error":"pty vanished"}


        """)
        await store.startTerminal()
        await codingWaitUntil("the error notice") { store.terminal.text.contains("terminal error") }
        XCTAssertTrue(store.terminal.text.contains("[terminal error: pty vanished]"))
        XCTAssertTrue(store.terminalAttached, "an error frame doesn't detach us")
    }

    func testAnOfflineDevicePointsAtResumeOnTheServer() async {
        let (store, t) = makeStore()
        t.route("/terminal/start", json: ["error": "device offline", "can_resume": true], status: 409)
        await store.startTerminal()
        XCTAssertFalse(store.terminalAttached)
        XCTAssertEqual(store.terminalError,
                       "Your Mac is offline — resume this session on the server to keep working.")
        XCTAssertFalse(store.terminalStarting)
    }

    func testAnyOtherAttachFailureShowsTheServerMessage() async {
        let (store, t) = makeStore()
        t.route("/terminal/start", json: ["error": "tmux is gone"], status: 500)
        await store.startTerminal()
        XCTAssertEqual(store.terminalError, "tmux is gone")
        XCTAssertFalse(store.terminalAttached)
    }

    func testStartTerminalIsIdempotentWhileAttached() async {
        let (store, t) = makeStore()
        t.route("/terminal/start", json: ["ok": true])
        t.enqueueSSE("")
        await store.startTerminal()
        let count = t.requests.filter { $0.url?.path.hasSuffix("/terminal/start") == true }.count
        await store.startTerminal()
        XCTAssertEqual(t.requests.filter { $0.url?.path.hasSuffix("/terminal/start") == true }.count,
                       count)
    }

    func testResizePushesTheGeometryAndReflowsLocally() async {
        let (store, t) = makeStore()
        t.route("/terminal/start", json: ["ok": true])
        t.route("/api/terminal/resize", json: ["ok": true])
        t.enqueueSSE("")
        await store.startTerminal()
        store.resizeTerminal(rows: 40, cols: 120)
        XCTAssertEqual(store.terminal.cols, 120)
        await codingWaitUntil("the resize POST") {
            t.requests.contains { $0.url?.path == "/api/terminal/resize" }
        }
    }

    /// The empty `catch` around the SSE pump left `terminalAttached == true`, so
    /// every later keystroke POST reported success into a PTY nobody was reading.
    func testADroppedTerminalStreamClearsTheAttachGuardAndSaysSo() async {
        let (store, t) = makeStore()
        t.route("/terminal/start", json: ["ok": true])
        t.enqueue(error: URLError(.networkConnectionLost))
        await store.startTerminal()
        XCTAssertTrue(store.terminalAttached, "the attach itself succeeded")

        await codingWaitUntil("the stream drop to clear the attach guard") {
            !store.terminalAttached
        }
        XCTAssertFalse(store.terminalStarting)
        XCTAssertNotNil(store.terminalError)
        XCTAssertTrue(store.terminal.text.contains("[terminal error:"),
                      "the drop is written into the buffer like a close notice")
    }

    /// `start()`'s bootstrap awaited the network before arming the poll, so a
    /// `stop()` while it was in flight was undone a moment later.
    func testStopBeforeTheBootstrapLandsDoesNotRearmThePoll() async {
        let (store, t) = makeStore()
        t.route("/terminal/start", json: ["ok": true])
        t.route("/messages", json: page([["i": 0]], total: 1))
        t.enqueueSSE("")
        store.start()
        store.stop()
        // Give the bootstrap's fetch time to land and (wrongly) re-arm.
        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertNil(store.pollTask, "a stopped session must not re-arm its poll")

        // The happy path still arms exactly one loop, and start() is idempotent.
        store.start()
        await codingWaitUntil("the bootstrap to arm the poll") { store.pollTask != nil }
        let armed = store.pollTask
        store.start()
        XCTAssertEqual(armed, store.pollTask, "a second start() must not stack a poll loop")
        store.stop()
        XCTAssertNil(store.pollTask)
    }

    /// Cancelling between the bytes and the submit `\r` must not be reported as
    /// a send — the TUI is left holding un-submitted text.
    func testSendTextCancelledBeforeEnterReportsAFailure() async {
        let (store, t) = makeStore()
        t.route("/terminal/start", json: ["ok": true])
        t.route("/api/terminal/input", json: ["ok": true])
        t.enqueueSSE("")
        let task = Task { await store.sendText("half a message") }
        task.cancel()
        let sent = await task.value
        XCTAssertFalse(sent)
        XCTAssertTrue(store.pendingSends.isEmpty, "nothing was submitted, so nothing is queued")
        let inputs = t.requests
            .filter { $0.url?.path == "/api/terminal/input" }
            .compactMap { $0.httpBody }
            .compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            .compactMap { $0["data"] as? String }
        XCTAssertFalse(inputs.contains("\r"), "the submit must not follow a cancellation")
    }

    /// A close that never lands leaks the server PTY and the NEXT attach 409s.
    func testAFailedTerminalCloseIsRetriedThenReported() async {
        let (store, t) = makeStore()
        t.route("/terminal/start", json: ["ok": true])
        t.route("/api/terminal/close", json: ["error": "pty busy"], status: 500)
        t.enqueueSSE("")
        await store.startTerminal()
        store.detachTerminal()
        await codingWaitUntil("both close attempts") {
            t.requests.filter { $0.url?.path == "/api/terminal/close" }.count >= 2
        }
        await codingWaitUntil("the close failure to surface") { store.terminalError != nil }
        XCTAssertTrue(store.terminalError?.contains("Couldn’t release the terminal") == true)
    }

    func testDetachIsIdempotentAndReleasesThePTY() async {
        let (store, t) = makeStore()
        t.route("/terminal/start", json: ["ok": true])
        t.route("/api/terminal/close", json: ["ok": true])
        t.enqueueSSE("")
        await store.startTerminal()
        store.detachTerminal()
        XCTAssertFalse(store.terminalAttached)
        await codingWaitUntil("the close POST") {
            t.requests.contains { $0.url?.path == "/api/terminal/close" }
        }
        let closes = t.requests.filter { $0.url?.path == "/api/terminal/close" }.count
        store.detachTerminal() // no second close — we're already detached
        XCTAssertEqual(t.requests.filter { $0.url?.path == "/api/terminal/close" }.count, closes)
    }
}

// MARK: - Attachments

@MainActor
final class CodingAttachmentsTests: XCTestCase {

    private func make() -> (CodingAttachments, MockTransport) {
        let (client, transport) = JarvisAPI.mocked()
        return (CodingAttachments(api: CodingSessionsAPI(api: client)), transport)
    }

    func testPickedFilesKeepOnlyTheirBasenameAndSniffImages() {
        let (a, _) = make()
        a.add(name: "/private/tmp/IMG_0001.HEIC", data: Data("x".utf8))
        a.add(name: "notes.pdf", data: Data("y".utf8))
        XCTAssertEqual(a.items.map(\.name), ["IMG_0001.HEIC", "notes.pdf"])
        XCTAssertEqual(a.items.map(\.isImage), [true, false])
        a.remove(a.items[0])
        XCTAssertEqual(a.items.map(\.name), ["notes.pdf"])
        a.clear()
        XCTAssertTrue(a.isEmpty)
    }

    func testConsumeFoldsPathRefsIntoTheMessage() async {
        let (a, t) = make()
        a.add(name: "shot.png", data: Data("A".utf8))
        a.add(name: "notes.pdf", data: Data("B".utf8))
        t.enqueue(json: ["path": "/srv/up/shot.png"])
        t.enqueue(json: ["path": "/srv/up/notes.pdf"])
        let r = await a.consume(into: "  look at these  ", sessionId: "cs_1")
        XCTAssertEqual(r.text, "look at these @/srv/up/shot.png @/srv/up/notes.pdf",
                       "space-joined — a newline would submit the TUI input early")
        XCTAssertEqual(r.failed, 0)
        XCTAssertTrue(a.isEmpty)
        XCTAssertNil(a.error)
    }

    func testConsumeWithNoTextIsJustTheRefs() async {
        let (a, t) = make()
        a.add(name: "shot.png", data: Data("A".utf8))
        t.enqueue(json: ["path": "/srv/up/shot.png"])
        let value9 = await a.consume(into: "", sessionId: "cs_1").text
        XCTAssertEqual(value9, "@/srv/up/shot.png")
    }

    func testEveryUploadFailing() async {
        let (a, t) = make()
        a.add(name: "shot.png", data: Data("A".utf8))
        t.enqueue(json: ["error": "disk full"], status: 500)
        let r = await a.consume(into: "hi", sessionId: "cs_1")
        XCTAssertEqual(r.text, "hi", "the message is unchanged when nothing uploaded")
        XCTAssertEqual(r.failed, 1)
        XCTAssertEqual(a.error, "Attachments failed to upload")
        XCTAssertTrue(a.isEmpty, "the tray is cleared either way — no silent retry queue")
    }

    func testAPartialFailureIsCounted() async {
        let (a, t) = make()
        a.add(name: "ok.png", data: Data("A".utf8))
        a.add(name: "bad.png", data: Data("B".utf8))
        t.enqueue(json: ["path": "/srv/up/ok.png"])
        t.enqueue(json: ["path": ""]) // the server produced no path
        let r = await a.consume(into: "two", sessionId: "cs_1")
        XCTAssertEqual(r.text, "two @/srv/up/ok.png")
        XCTAssertEqual(r.failed, 1)
        XCTAssertEqual(a.error, "1 attachment(s) failed to upload")
    }

    func testConsumeIsANoOpWithoutAttachmentsOrASession() async {
        let (a, t) = make()
        let value10 = await a.consume(into: "hi", sessionId: "cs_1").text
        XCTAssertEqual(value10, "hi")
        a.add(name: "shot.png", data: Data("A".utf8))
        let value11 = await a.consume(into: "hi", sessionId: "").text
        XCTAssertEqual(value11, "hi")
        XCTAssertFalse(a.isEmpty, "nothing was uploaded, so nothing was consumed")
        XCTAssertTrue(t.requests.isEmpty)
    }
}

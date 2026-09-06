import XCTest
@testable import JarvisCopilot

@MainActor
final class ChatStoreTests: XCTestCase {

    private var transport: ScriptedTransport!
    private var clock: ManualChatClock!
    private var clipboard: FakeClipboard!
    private var bus: ChatSyncBus!
    private var store: ChatStore!

    /// A full turn: some thinking, a tool round, text, usage, done.
    private let fullTurn = sseFrames([
        ("thinking", ["text": "let me look"]),
        ("tool", ["tid": "t1", "name": "web_search", "args": ["q": "swift"]]),
        ("tool_result", ["tid": "t1", "name": "web_search", "result": "3 hits", "duration": 0.5]),
        ("delta", ["text": "Found "]),
        ("delta", ["text": "three."]),
        ("metering", ["usage": ["input_tokens": 1_200, "output_tokens": 8]]),
        ("done", ["session": ["title": "Swift search"]]),
    ])

    override func setUp() {
        super.setUp()
        ChatAPI.streamingStartSupported = nil
        transport = ScriptedTransport()
        clock = ManualChatClock()
        clipboard = FakeClipboard()
        bus = ChatSyncBus()
        store = makeStore()
    }

    override func tearDown() {
        transport.closeHeldStreams()
        clock.releaseAll()
        ChatAPI.streamingStartSupported = nil
        super.tearDown()
    }

    private func makeStore(onDevice: OnDeviceChatHandler? = nil) -> ChatStore {
        ChatStore(api: JarvisAPI(credentials: TestCredentials(), transport: transport),
                  selection: ModelSelection(store: MemoryKeyValueStore()),
                  bus: bus,
                  clock: clock,
                  clipboard: clipboard,
                  onDevice: onDevice,
                  resilience: ChatResilience(idleLimit: 45, checkStep: 5, maxReattach: 3))
    }

    /// Every turn ends with a quiet list refresh; script it so the store has
    /// something to talk to.
    private func allowListRefresh(_ times: Int = 4) {
        for _ in 0..<times { transport.on("GET /api/sessions", .json(["sessions": []])) }
    }

    // MARK: A plain turn

    func testSendStreamsAWholeTurnIntoTheTranscript() async {
        store.sessionID = "s1"
        transport.on("POST /api/chat/start", .sse(fullTurn))
        allowListRefresh()

        await store.send("find swift")

        XCTAssertEqual(store.messages.count, 2)
        XCTAssertEqual(store.messages[0].role, .user)
        XCTAssertEqual(store.messages[0].plainText, "find swift")

        let reply = store.messages[1]
        XCTAssertEqual(reply.role, .assistant)
        XCTAssertEqual(reply.plainText, "Found three.")
        XCTAssertEqual(reply.reasoning, "let me look")
        XCTAssertEqual(reply.tools.map(\.name), ["web_search"])
        XCTAssertTrue(reply.tools[0].done)
        XCTAssertEqual(reply.tools[0].result, "3 hits")
        XCTAssertEqual(reply.stats?.inputTokens, 1_200)
        XCTAssertEqual(reply.stats?.outputTokens, 8)
        XCTAssertNotNil(reply.stats?.durationMs, "the stats line needs the elapsed seconds")
        XCTAssertFalse(reply.streaming)
        XCTAssertFalse(store.streaming)
        XCTAssertNil(store.error)
        XCTAssertEqual(store.sessionTitle, "Swift search", "the server named the session mid-turn")
        XCTAssertEqual(store.inputTokens, 1_200, "the live usage mirror the composer shows")
    }

    func testSendPassesTheSelectedModelAndProvider() async {
        store.sessionID = "s1"
        let selection = ModelSelection(store: MemoryKeyValueStore())
        selection.set(.chat, model: "anthropic/opus", provider: "anthropic")
        store = ChatStore(api: JarvisAPI(credentials: TestCredentials(), transport: transport),
                          selection: selection, bus: bus, clock: clock)
        store.sessionID = "s1"
        transport.on("POST /api/chat/start", .sse(sseFrames([("done", [:])])))
        allowListRefresh()

        await store.send("hi")
        let body = transport.lastBody(for: "POST /api/chat/start")
        XCTAssertEqual(body["model"] as? String, "anthropic/opus")
        XCTAssertEqual(body["model_provider"] as? String, "anthropic")
    }

    /// Picking a model out of the catalogue has to send the CANONICAL provider
    /// id, not the name the picker shows. The server routes on `model_provider`,
    /// so "Anthropic" instead of "anthropic" quietly ran the turn on the default
    /// model (Flutter sends `_ModelOption.providerForSave`).
    func testSendPassesTheCanonicalProviderIDNotTheDisplayName() async {
        transport.on("GET /api/models", .json(["groups": [
            ["provider": "Anthropic", "provider_id": "anthropic",
             "models": [["id": "anthropic/opus", "label": "Opus"]]],
        ]]))
        await store.loadModels()
        let opus = store.models?.models.first
        XCTAssertEqual(opus?.provider, "Anthropic")
        store.selectModel(opus)
        XCTAssertEqual(store.selectedProviderID, "anthropic")

        store.sessionID = "s1"
        transport.on("POST /api/chat/start", .sse(sseFrames([("done", [:])])))
        allowListRefresh()
        await store.send("hi")

        let body = transport.lastBody(for: "POST /api/chat/start")
        XCTAssertEqual(body["model"] as? String, "anthropic/opus")
        XCTAssertEqual(body["model_provider"] as? String, "anthropic")
    }

    func testSendCreatesTheSessionOnTheFirstMessage() async {
        transport.on("POST /api/session/new", .json(["session_id": "new-1"]))
        transport.on("POST /api/chat/start", .sse(sseFrames([("delta", ["text": "hi"]), ("done", [:])])))
        allowListRefresh()

        XCTAssertFalse(store.hasSession)
        await store.send("hello")

        XCTAssertEqual(store.sessionID, "new-1", "an empty session writes nothing to disk until the first message")
        XCTAssertEqual(transport.lastBody(for: "POST /api/chat/start")["session_id"] as? String, "new-1")
    }

    func testSendIgnoresAnEmptyDraftAndDoesNothingWhileStreaming() async {
        store.sessionID = "s1"
        await store.send("   ")
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertEqual(transport.log, [])

        transport.on("POST /api/chat/start", .sseHolding(sseFrames([("delta", ["text": "working"])])))
        let first = Task { await store.send("one") }
        await waitUntil("the turn to start") { self.store.streaming }
        await store.send("two")
        XCTAssertEqual(store.messages.count, 2, "a second send while streaming is dropped")

        store.cancelLocally()
        transport.closeHeldStreams()
        _ = await first.value
    }

    // MARK: Attachments

    func testSendUploadsAttachmentsAndClearsTheComposer() async {
        store.sessionID = "s1"
        store.addAttachment(ChatPendingAttachment(name: "a.png", data: Data([1]), isImage: true))
        store.addAttachment(ChatPendingAttachment(name: "clip.mov", data: Data([2]), isVideo: true, posterData: Data([3])))
        transport.on("POST /api/upload", .json(["path": "/u/a.png", "is_image": true]))
        transport.on("POST /api/upload", .json(["path": "/u/clip.mov"]))
        transport.on("POST /api/upload", .json(["path": "/u/clip.mov.poster.jpg", "is_image": true]))
        transport.on("POST /api/chat/start", .sse(sseFrames([("done", [:])])))
        allowListRefresh()

        await store.send("look at these")

        XCTAssertEqual(transport.count("POST /api/upload"), 3, "the video's poster frame uploads as a vision image too")
        XCTAssertTrue(store.pendingAttachments.isEmpty, "the composer empties on send")
        XCTAssertEqual(store.messages[0].attachments.map(\.name), ["a.png", "clip.mov"])
        XCTAssertEqual(store.messages[0].attachments[0].thumbnail, Data([1]), "the bubble shows a real preview this session")
        XCTAssertEqual((transport.lastBody(for: "POST /api/chat/start")["attachments"] as? [[String: Any]])?.count, 3)
    }

    func testAnAttachmentOnlyMessageStillSends() async {
        store.sessionID = "s1"
        store.addAttachment(ChatPendingAttachment(name: "a.png", data: Data([1]), isImage: true))
        transport.on("POST /api/upload", .json(["path": "/u/a.png"]))
        transport.on("POST /api/chat/start", .sse(sseFrames([("done", [:])])))
        allowListRefresh()

        await store.send("")
        XCTAssertEqual(store.messages.count, 2)
        XCTAssertEqual(transport.count("POST /api/chat/start"), 1)
    }

    func testRemoveAttachmentDropsItFromTheComposer() {
        let a = ChatPendingAttachment(name: "a.png", data: Data([1]), isImage: true)
        store.addAttachment(a)
        store.removeAttachment(a)
        XCTAssertTrue(store.pendingAttachments.isEmpty)
    }

    // MARK: Resilience — 409, stalls, history fallback

    func testAConflictAttachesToTheTurnAlreadyRunningOnTheSession() async {
        store.sessionID = "s1"
        transport.on("POST /api/chat/start", .json(["error": "busy"], status: 409))
        transport.on("GET /api/session", .json(["session": ["active_stream_id": "live-9"]]))
        transport.on("GET /api/chat/stream", .sse(sseFrames([("delta", ["text": "riding along"]), ("done", [:])])))
        allowListRefresh()

        await store.send("hi")

        XCTAssertEqual(transport.count("POST /api/chat/start"), 1, "never re-submit — the turn is already running")
        XCTAssertEqual(transport.query("GET /api/chat/stream", "stream_id"), "live-9")
        XCTAssertEqual(store.messages.last?.plainText, "riding along")
        XCTAssertNil(store.error)
        XCTAssertFalse(store.messages.last!.isError)
    }

    func testAConflictWithNoActiveStreamSurfacesAsAnError() async {
        store.sessionID = "s1"
        transport.on("POST /api/chat/start", .json(["error": "busy"], status: 409))
        transport.on("GET /api/session", .json(["session": ["active_stream_id": ""]]))
        allowListRefresh()

        await store.send("hi")
        XCTAssertTrue(store.messages.last!.isError)
        XCTAssertFalse(store.streaming)
    }

    func testAStalledStreamSnapshotsAndReAttaches() async {
        store.sessionID = "s1"
        // Our socket stays open but goes quiet — another consumer drained the queue.
        transport.on("POST /api/chat/start", .sseHolding(sseFrames([("delta", ["text": "half "])])))
        transport.on("GET /api/session", .json(["session": ["active_stream_id": "live-2"]]))
        transport.on("GET /api/chat/stream", .sse(sseFrames([("delta", ["text": "an answer"]), ("done", [:])])))
        allowListRefresh()

        let sending = Task { await store.send("hi") }
        await waitUntil("the first delta") { self.store.messages.last?.plainText == "half " }
        await waitUntil("the watchdog to park") { self.clock.parked > 0 }
        clock.advance(50)

        _ = await sending.value
        XCTAssertEqual(store.messages.last?.plainText, "half an answer", "the re-attached stream continues the same turn")
        XCTAssertEqual(transport.count("GET /api/chat/stream"), 1)
        XCTAssertEqual(transport.count("POST /api/chat/start"), 1, "a re-attach must never re-run the turn")
        XCTAssertFalse(store.streaming)
        XCTAssertNil(store.error)
    }

    func testAStallAfterTheTurnFinishedFallsBackToTheServersRecord() async {
        store.sessionID = "s1"
        transport.on("POST /api/chat/start", .sseHolding())
        transport.on("GET /api/session", .json(["session": [
            "active_stream_id": "",
            "messages": [["role": "assistant", "content": "the finished answer"]],
        ]]))
        allowListRefresh()

        let sending = Task { await store.send("hi") }
        await waitUntil("the turn to start") { self.store.streaming }
        await waitUntil("the watchdog to park") { self.clock.parked > 0 }
        clock.advance(50)

        _ = await sending.value
        XCTAssertEqual(store.messages.last?.plainText, "the finished answer",
                       "the turn ended while we weren't listening — take the server's copy")
        XCTAssertFalse(store.messages.last!.isError)
    }

    func testRepeatedStallsGiveUpAfterTheReAttachBudget() async {
        store.sessionID = "s1"
        transport.on("POST /api/chat/start", .sseHolding())
        for _ in 0..<4 {
            transport.on("GET /api/session", .json(["session": ["active_stream_id": "live-x"]]))
            transport.on("GET /api/chat/stream", .sseHolding())
        }
        allowListRefresh()

        let sending = Task { await store.send("hi") }
        for _ in 0..<4 {
            await waitUntil("the watchdog to park") { self.clock.parked > 0 }
            clock.advance(50)
            await Task.yield()
        }
        _ = await sending.value

        XCTAssertTrue(store.messages.last!.isError, "after the budget the turn is reported lost, not left spinning")
        XCTAssertFalse(store.streaming)
    }

    func testAStreamThatEndsSilentlyFallsBackToHistory() async {
        store.sessionID = "s1"
        // The socket closes with no `done` and nothing said.
        transport.on("POST /api/chat/start", .sse(""))
        transport.on("POST /api/chat/start", .json(["stream_id": "s-1"]))
        transport.on("GET /api/chat/stream", .sse(""))
        transport.on("GET /api/session", .json(["session": [
            "messages": [["role": "assistant", "content": "recovered from history"]],
        ]]))
        allowListRefresh()

        await store.send("hi")
        XCTAssertEqual(store.messages.last?.plainText, "recovered from history")
        XCTAssertFalse(store.streaming)
    }

    func testAToolOnlyTurnWithNoTextIsNotReportedEmpty() async {
        store.sessionID = "s1"
        transport.on("POST /api/chat/start", .sse(sseFrames([
            ("tool", ["tid": "t1", "name": "run"]),
            ("tool_result", ["tid": "t1", "name": "run", "result": "ok"]),
            ("done", [:]),
        ])))
        allowListRefresh()

        await store.send("do it")
        XCTAssertEqual(store.messages.last?.tools.count, 1)
        XCTAssertFalse(store.messages.last!.isError)
        XCTAssertEqual(transport.count("GET /api/session"), 0, "a turn that did real work needs no history fallback")
    }

    // MARK: Cancel

    func testCancelStopsTheTurnAndTellsTheServer() async {
        store.sessionID = "s1"
        transport.on("POST /api/chat/start", .json(["stream_id": "live-5"]))
        transport.on("GET /api/chat/stream", .sseHolding())
        transport.on("GET /api/chat/cancel", .json(["ok": true]))
        allowListRefresh()

        let sending = Task { await store.send("hi") }
        await waitUntil("the stream to open") { self.transport.count("GET /api/chat/stream") == 1 }
        await store.cancel()
        transport.closeHeldStreams()
        _ = await sending.value

        XCTAssertFalse(store.streaming)
        XCTAssertFalse(store.messages.last!.streaming)
        XCTAssertEqual(store.messages.last?.plainText, "_(cancelled)_")
        XCTAssertEqual(transport.query("GET /api/chat/cancel", "stream_id"), "live-5")
    }

    func testCancelKeepsWhateverTheTurnAlreadySaid() async {
        store.sessionID = "s1"
        transport.on("POST /api/chat/start", .sseHolding(sseFrames([("delta", ["text": "partial"])])))
        transport.on("GET /api/chat/cancel", .json(["ok": true]))
        allowListRefresh()

        let sending = Task { await store.send("hi") }
        await waitUntil("the first delta") { self.store.messages.last?.plainText == "partial" }
        await store.cancel()
        transport.closeHeldStreams()
        _ = await sending.value
        XCTAssertEqual(store.messages.last?.plainText, "partial")
    }

    // MARK: Errors

    func testAnErrorEventSurfacesInTheReplyBubble() async {
        store.sessionID = "s1"
        transport.on("POST /api/chat/start", .sse(sseFrames([("error", ["message": "the model is over quota"])])))
        allowListRefresh()

        await store.send("hi")
        XCTAssertTrue(store.messages.last!.isError)
        XCTAssertEqual(store.messages.last?.plainText, "the model is over quota")
        XCTAssertFalse(store.streaming)
    }

    func testAnUnreachableServerSurfacesAUserFacingLine() async {
        store.sessionID = "s1"
        transport.on("POST /api/chat/start", .failing(URLError(.notConnectedToInternet)))
        transport.on("POST /api/chat/start", .failing(URLError(.notConnectedToInternet)))
        allowListRefresh()

        await store.send("hi")
        XCTAssertTrue(store.messages.last!.isError)
        XCTAssertEqual(store.messages.last?.plainText, "No internet connection")
    }

    func testAFailureToCreateTheSessionIsReported() async {
        transport.on("POST /api/session/new", .json(["error": "nope"], status: 500))
        await store.send("hi")
        XCTAssertTrue(store.messages.last!.isError)
        XCTAssertFalse(store.streaming)
    }

    // MARK: Sessions list

    func testLoadSessionsDropsArchivedRowsAndSortsByRecency() async {
        transport.on("GET /api/sessions", .json(["sessions": [
            ["session_id": "old", "updated_at": 5],
            ["session_id": "new", "updated_at": 50],
            ["session_id": "gone", "updated_at": 99, "archived": true],
            ["session_id": "", "updated_at": 100],
        ]]))
        await store.loadSessions()
        XCTAssertEqual(store.sessions.map(\.id), ["new", "old"])
        XCTAssertFalse(store.sessionsLoading)
        XCTAssertNil(store.error)
    }

    func testLoadSessionsReportsItsFailureButAQuietRefreshDoesNot() async {
        transport.on("GET /api/sessions", .json(["error": "boom"], status: 500))
        await store.loadSessions()
        XCTAssertNotNil(store.error)
        XCTAssertTrue(store.error!.contains("chats"), store.error!)

        store.error = nil
        transport.on("GET /api/sessions", .json(["error": "boom"], status: 500))
        await store.loadSessions(quiet: true)
        XCTAssertNil(store.error, "a background refresh must never stomp the view")
    }

    func testOpenInitialOpensTheMostRecentSessionOrStartsFresh() async {
        transport.on("GET /api/sessions", .json(["sessions": [["session_id": "a", "updated_at": 1]]]))
        transport.on("GET /api/session", .json(["session": ["title": "A", "messages": []]]))
        await store.openInitial()
        XCTAssertEqual(store.sessionID, "a")

        let fresh = makeStore()
        transport.on("GET /api/sessions", .json(["sessions": []]))
        await fresh.openInitial()
        XCTAssertNil(fresh.sessionID)
        XCTAssertEqual(fresh.sessionTitle, "New chat")
    }

    // MARK: Open / switch / new session

    func testOpenSessionLoadsTheHistoryAndTheTitle() async {
        transport.on("GET /api/session", .json(["session": [
            "title": "Dinner",
            "messages": [
                ["role": "user", "content": "what's for dinner"],
                ["role": "assistant", "content": "pasta", "thinking": "checking the fridge"],
            ],
        ]]))
        await store.openSession("s1")

        XCTAssertEqual(store.sessionID, "s1")
        XCTAssertEqual(store.sessionTitle, "Dinner")
        XCTAssertEqual(store.messages.count, 2)
        XCTAssertEqual(store.messages[1].reasoning, "checking the fridge")
        XCTAssertFalse(store.historyLoading)
        XCTAssertFalse(store.isEmpty)
    }

    func testOpenSessionReportsAFailureAndLeavesNoSpinner() async {
        transport.on("GET /api/session", .json(["error": "gone"], status: 404))
        await store.openSession("s1")
        XCTAssertNotNil(store.error)
        XCTAssertFalse(store.historyLoading)
    }

    func testSwitchingSessionsCancelsTheLiveTurnFirst() async {
        store.sessionID = "s1"
        transport.on("POST /api/chat/start", .json(["stream_id": "live-1"]))
        transport.on("GET /api/chat/stream", .sseHolding())
        transport.on("GET /api/chat/cancel", .json(["ok": true]))
        transport.on("GET /api/session", .json(["session": ["title": "Other", "messages": []]]))
        allowListRefresh()

        let sending = Task { await store.send("hi") }
        await waitUntil("the stream to open") { self.transport.count("GET /api/chat/stream") == 1 }
        await store.openSession("s2")
        transport.closeHeldStreams()
        _ = await sending.value

        XCTAssertEqual(store.sessionID, "s2")
        XCTAssertEqual(store.sessionTitle, "Other")
        XCTAssertTrue(store.messages.isEmpty, "the old thread is gone")
        XCTAssertFalse(store.streaming)
        XCTAssertEqual(transport.count("GET /api/chat/cancel"), 1)
    }

    func testStartNewSessionClearsTheViewWithoutTouchingTheServer() async {
        transport.on("GET /api/session", .json(["session": ["title": "Old", "messages": [["role": "user", "content": "hi"]]]]))
        await store.openSession("s1")
        store.inputTokens = 5

        store.startNewSession()
        XCTAssertNil(store.sessionID)
        XCTAssertEqual(store.sessionTitle, "New chat")
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertTrue(store.isEmpty)
        XCTAssertNil(store.inputTokens)
        XCTAssertEqual(transport.count("POST /api/session/new"), 0, "deferred until the first message")
    }

    // MARK: Session mutations

    func testRenameUpdatesTheRowAndTheOpenTitle() async {
        transport.on("GET /api/sessions", .json(["sessions": [["session_id": "s1", "title": "Old"]]]))
        await store.loadSessions()
        store.sessionID = "s1"
        transport.on("POST /api/session/rename", .json([:]))

        await store.renameSession("s1", title: "New name")
        XCTAssertEqual(store.sessions.first?.title, "New name")
        XCTAssertEqual(store.sessionTitle, "New name")
    }

    func testPinFlipsTheRow() async {
        transport.on("GET /api/sessions", .json(["sessions": [["session_id": "s1"]]]))
        await store.loadSessions()
        transport.on("POST /api/session/pin", .json([:]))
        await store.pinSession("s1", pinned: true)
        XCTAssertTrue(store.sessions.first!.pinned)
    }

    func testDeletingTheOpenSessionOpensTheNextOne() async {
        transport.on("GET /api/sessions", .json(["sessions": [
            ["session_id": "s1", "updated_at": 9], ["session_id": "s2", "updated_at": 1],
        ]]))
        await store.loadSessions()
        store.sessionID = "s1"
        transport.on("POST /api/session/delete", .json([:]))
        transport.on("GET /api/session", .json(["session": ["title": "Second", "messages": []]]))

        await store.deleteSession("s1")
        XCTAssertEqual(store.sessions.map(\.id), ["s2"])
        XCTAssertEqual(store.sessionID, "s2")
    }

    func testDeletingTheLastSessionStartsAFreshOne() async {
        transport.on("GET /api/sessions", .json(["sessions": [["session_id": "s1"]]]))
        await store.loadSessions()
        store.sessionID = "s1"
        transport.on("POST /api/session/delete", .json([:]))

        await store.deleteSession("s1")
        XCTAssertNil(store.sessionID)
        XCTAssertEqual(store.sessionTitle, "New chat")
    }

    // MARK: Clarify

    func testAClarifyEventOpensThePromptAndATypedReplyAnswersIt() async {
        store.sessionID = "s1"
        transport.on("POST /api/chat/start", .sse(sseFrames([
            ("clarify", ["question": "Which file?", "choices_offered": ["a.txt", "b.txt"]]),
            ("done", [:]),
        ])))
        transport.on("POST /api/clarify/respond", .json(["ok": true]))
        allowListRefresh()

        await store.send("edit the file")
        XCTAssertEqual(store.pendingClarify?.question, "Which file?")
        XCTAssertEqual(store.pendingClarify?.choices, ["a.txt", "b.txt"])

        await store.send("a.txt")
        XCTAssertNil(store.pendingClarify)
        XCTAssertEqual(transport.lastBody(for: "POST /api/clarify/respond")["response"] as? String, "a.txt")
        XCTAssertEqual(store.messages.count, 2, "answering a clarify must not start a second turn")
    }

    func testAnsweringAClarifyWithNothingIsIgnored() async {
        store.sessionID = "s1"
        store.pendingClarify = ClarifyPrompt(question: "Which?", choices: [])
        await store.send("   ")
        XCTAssertNotNil(store.pendingClarify)
        XCTAssertEqual(transport.count("POST /api/clarify/respond"), 0)
    }

    // MARK: On-device turns and "Try on server"

    func testAnOnDeviceHandlerCanAnswerWithoutTouchingTheServer() async {
        let local = FakeOnDeviceHandler(reply: .answered(inputTokens: 4, outputTokens: 9), tokens: ["At ", "your service."])
        store = makeStore(onDevice: local)
        store.sessionID = "s1"
        transport.on("POST /api/session/append", .json([:]))
        allowListRefresh()

        await store.send("hello")

        XCTAssertEqual(transport.count("POST /api/chat/start"), 0, "the local layer handled the whole turn")
        XCTAssertEqual(store.messages.last?.plainText, "At your service.")
        XCTAssertTrue(store.messages.last!.onDevice, "the UI shows the on-device badge")
        XCTAssertEqual(store.messages.last?.stats?.inputTokens, 4)
        XCTAssertEqual(store.messages.last?.stats?.outputTokens, 9)
        XCTAssertEqual(transport.lastBody(for: "POST /api/session/append")["on_device"] as? Bool, true,
                       "the local turn is persisted so it shows on the web too")
    }

    func testAnOnDeviceMissEscalatesToTheServer() async {
        store = makeStore(onDevice: FakeOnDeviceHandler(reply: .escalate))
        store.sessionID = "s1"
        transport.on("POST /api/chat/start", .sse(sseFrames([("delta", ["text": "from the server"]), ("done", [:])])))
        allowListRefresh()

        await store.send("something hard")
        XCTAssertEqual(store.messages.last?.plainText, "from the server")
        XCTAssertFalse(store.messages.last!.onDevice)
    }

    func testAttachmentsAlwaysGoToTheServer() async {
        let local = FakeOnDeviceHandler(reply: .answered(inputTokens: 1, outputTokens: 1), tokens: ["local"])
        store = makeStore(onDevice: local)
        store.sessionID = "s1"
        store.addAttachment(ChatPendingAttachment(name: "a.png", data: Data([1]), isImage: true))
        transport.on("POST /api/upload", .json(["path": "/u/a.png"]))
        transport.on("POST /api/chat/start", .sse(sseFrames([("delta", ["text": "I see it"]), ("done", [:])])))
        allowListRefresh()

        await store.send("what is this")
        XCTAssertEqual(store.messages.last?.plainText, "I see it", "the on-device layer can't take attachments")
        XCTAssertFalse(local.wasAsked)
    }

    func testTryOnServerReAsksTheNearestUserPromptOnTheServer() async {
        let local = FakeOnDeviceHandler(reply: .answered(inputTokens: 1, outputTokens: 1), tokens: ["local answer"])
        store = makeStore(onDevice: local)
        store.sessionID = "s1"
        transport.on("POST /api/session/append", .json([:]))
        allowListRefresh()
        await store.send("what's 2+2")
        XCTAssertEqual(store.messages.count, 2)

        transport.on("POST /api/chat/start", .sse(sseFrames([("delta", ["text": "4, on the server"]), ("done", [:])])))
        await store.retryOnServer(store.messages[1])

        XCTAssertEqual(store.messages.count, 4, "the local reply stays above so you can compare")
        XCTAssertEqual(store.messages[2].plainText, "what's 2+2")
        XCTAssertEqual(store.messages[3].plainText, "4, on the server")
        XCTAssertEqual(transport.lastBody(for: "POST /api/chat/start")["message"] as? String, "what's 2+2")
    }

    func testTryOnServerDoesNothingWithoutAPrecedingPrompt() async {
        store.setMessages([.assistant()])
        await store.retryOnServer(store.messages[0])
        XCTAssertEqual(store.messages.count, 1)
        XCTAssertEqual(transport.log, [])
    }

    func testPersistedLocalRepliesStripInlineBase64Images() {
        let text = "here you go ![art](data:image/png;base64,AAAABBBBCCCC) enjoy"
        XCTAssertEqual(ChatStore.stripPersistedImages(text), "here you go [generated image] enjoy")
        XCTAssertEqual(ChatStore.stripPersistedImages("plain"), "plain")
    }

    // MARK: Live refresh

    func testTheSyncBusRefreshesTheListAndTheOpenThread() async {
        transport.on("GET /api/session", .json(["session": ["title": "T", "messages": []]]))
        await store.openSession("s1")
        transport.on("GET /api/sessions", .json(["sessions": [["session_id": "s1", "title": "T"]]]))
        transport.on("GET /api/session", .json(["session": [
            "title": "T", "messages": [["role": "user", "content": "added by voice"]],
        ]]))

        await waitUntil("the store to subscribe to the bus") { self.bus.subscriberCount == 1 }
        bus.sessionChanged("s1")
        await waitUntil("the thread to re-hydrate") { self.store.messages.count == 1 }
        XCTAssertEqual(store.messages.first?.plainText, "added by voice")
        XCTAssertEqual(store.sessions.count, 1)
    }

    func testAQuietRefreshNeverClobbersALiveTurn() async {
        store.sessionID = "s1"
        transport.on("POST /api/chat/start", .sseHolding(sseFrames([("delta", ["text": "streaming"])])))
        allowListRefresh()

        let sending = Task { await store.send("hi") }
        await waitUntil("the first delta") { self.store.messages.last?.plainText == "streaming" }
        await store.refreshActiveQuietly()
        XCTAssertEqual(store.messages.count, 2, "no history re-hydrate mid-stream")
        XCTAssertEqual(transport.count("GET /api/session"), 0)

        store.cancelLocally()
        transport.closeHeldStreams()
        _ = await sending.value
    }

    func testRefreshOnFocusPullsTheListAndTheThread() async {
        store.sessionID = "s1"
        transport.on("GET /api/sessions", .json(["sessions": [["session_id": "s1"]]]))
        transport.on("GET /api/session", .json(["session": ["title": "Focused", "messages": []]]))
        await store.refreshOnFocus()
        XCTAssertEqual(store.sessionTitle, "Focused")
        XCTAssertEqual(store.sessions.count, 1)
    }

    func testAClarifyAnswerTheServerRefusesPutsTheQuestionBack() async {
        store.sessionID = "s1"
        store.pendingClarify = ClarifyPrompt(question: "Which file?", choices: ["a.txt"])
        // Nothing scripted for POST /api/clarify/respond: the post fails.
        await store.respondClarify("a.txt")

        XCTAssertEqual(store.pendingClarify?.question, "Which file?",
                       "the turn is still blocked on the server, so the question stays open")
        XCTAssertNotNil(store.error)
    }

    func testACancelTheServerRefusesSaysTheTurnMayStillBeRunning() async {
        store.sessionID = "s1"
        transport.on("POST /api/chat/start", .json(["stream_id": "live-9"]))
        transport.on("GET /api/chat/stream", .sseHolding())
        allowListRefresh()

        let sending = Task { await store.send("hi") }
        await waitUntil("the stream to open") { self.transport.count("GET /api/chat/stream") == 1 }
        await store.cancel()          // nothing scripted for GET /api/chat/cancel
        transport.closeHeldStreams()
        _ = await sending.value

        XCTAssertFalse(store.streaming)
        XCTAssertEqual(store.error, "Stopped locally — the server may still be running this turn.")
    }

    func testAnAttachmentThatFailsToUploadIsCalledOutInTheComposer() async {
        store.sessionID = "s1"
        store.addAttachment(ChatPendingAttachment(name: "a.png", data: Data([1]), isImage: true))
        // Nothing scripted for POST /api/upload: the upload fails.
        transport.on("POST /api/chat/start", .sse(sseFrames([("done", [:])])))
        allowListRefresh()

        await store.send("look at this")

        XCTAssertEqual(store.attachError, "Couldn't upload a.png — it was left out of this message.")
        XCTAssertNil(transport.lastBody(for: "POST /api/chat/start")["attachments"],
                     "the text still sends, just without the file")
    }

    // MARK: What the view reads

    func testRowsGroupConsecutiveMessagesBySpeaker() async {
        transport.on("GET /api/session", .json(["session": ["messages": [
            ["role": "user", "content": "a"],
            ["role": "user", "content": "b"],
            ["role": "assistant", "content": "c"],
        ]]]))
        await store.openSession("s1")
        XCTAssertEqual(store.rows.map(\.continuesSpeaker), [false, true, false])
    }

    /// ``ChatStore/rows`` is cached rather than recomputed per `body`, so the
    /// cache has to survive every kind of transcript change (swift-correctness H9).
    func testRowsAndTheScrollTickTrackEveryTranscriptChange() async {
        XCTAssertTrue(store.rows.isEmpty)
        let start = store.messagesTick

        store.setMessages([.user("a"), .assistant()])
        XCTAssertEqual(store.rows.map(\.continuesSpeaker), [false, false])
        XCTAssertEqual(store.rows.map(\.id), store.messages.map(\.id))
        XCTAssertGreaterThan(store.messagesTick, start)

        store.sessionID = "s1"
        transport.on("POST /api/chat/start", .sse(sseFrames([("delta", ["text": "hi"]), ("done", [:])])))
        allowListRefresh()
        let beforeSend = store.messagesTick
        await store.send("go")

        XCTAssertEqual(store.rows.count, store.messages.count)
        XCTAssertEqual(store.rows.map(\.id), store.messages.map(\.id))
        XCTAssertEqual(store.rows.last?.message.plainText, "hi", "the cached row carries the streamed text")
        XCTAssertGreaterThan(store.messagesTick, beforeSend)

        store.startNewSession()
        XCTAssertTrue(store.rows.isEmpty)
    }

    func testCopyPutsAMessagesTextOnTheClipboard() async {
        var m = ChatMessage.assistant()
        m.appendToken("copy me")
        store.copy(m)
        XCTAssertEqual(clipboard.copied, ["copy me"])
    }

    func testCanSendReflectsTheComposerState() {
        XCTAssertFalse(store.canSend(draft: "   "))
        XCTAssertTrue(store.canSend(draft: "hi"))
        store.addAttachment(ChatPendingAttachment(name: "a.png", data: Data([1])))
        XCTAssertTrue(store.canSend(draft: ""), "an attachment alone is enough to send")
    }

    // MARK: Models

    func testLoadModelsFillsTheCatalogueForThePicker() async {
        transport.on("GET /api/models", .json([
            "default_model": "a/b",
            "groups": [["provider": "p", "models": [["id": "a/b", "label": "AB"]]]],
        ]))
        await store.loadModels()
        XCTAssertEqual(store.models?.models.map(\.id), ["a/b"])
        XCTAssertEqual(store.models?.defaultModel, "a/b")
    }

    func testLoadModelsKeepsTheLastGoodCatalogueAndOnlySpeaksUpWhenEmpty() async {
        await store.loadModels()   // nothing scripted for GET /api/models
        XCTAssertNil(store.models)
        XCTAssertNotNil(store.error, "an empty picker with no explanation is the bug")

        transport.on("GET /api/models", .json([
            "default_model": "a/b",
            "groups": [["provider": "p", "models": [["id": "a/b", "label": "AB"]]]],
        ]))
        store.error = nil
        await store.loadModels()
        XCTAssertEqual(store.models?.models.map(\.id), ["a/b"])

        await store.loadModels()   // fails again
        XCTAssertEqual(store.models?.models.map(\.id), ["a/b"], "a stale catalogue beats a blank one")
        XCTAssertNil(store.error)
    }

    // MARK: Sessions-list polling

    func testSetListPollingArmsOnceSkipsWhileStreamingAndCancels() async {
        transport.on("GET /api/sessions", .json(["sessions": [["id": "s1", "title": "One", "updated_at": 2]]]))

        store.setListPolling(true)
        await waitUntil("the poll to arm") { self.clock.parked == 1 }
        store.setListPolling(true)
        XCTAssertEqual(clock.parked, 1, "a second call must not stack a second poll")
        XCTAssertTrue(store.listPolling)

        clock.advance(6)
        await waitUntil("the first quiet refresh") {
            self.transport.count("GET /api/sessions") == 1 && self.clock.parked == 1
        }
        XCTAssertEqual(store.sessions.map(\.id), ["s1"])

        store.streaming = true
        clock.advance(6)
        await waitUntil("the poll to re-arm") { self.clock.parked == 1 }
        XCTAssertEqual(transport.count("GET /api/sessions"), 1, "a live turn is not interrupted for the list")
        store.streaming = false

        store.setListPolling(false)
        await waitUntil("the poll to stop") { self.clock.parked == 0 }
        XCTAssertFalse(store.listPolling)
    }

    /// The wedge this guards: a poll loop that ends on its own leaves a finished
    /// task in the handle, and "is a task installed" then answers "yes" forever
    /// (swift-correctness M26).
    func testAPollThatEndsOnItsOwnCanBeArmedAgain() async {
        clock.failSleeps = true
        store.setListPolling(true)
        await waitUntil("the poll to give up") { !self.store.listPolling }

        clock.failSleeps = false
        store.setListPolling(true)
        await waitUntil("the poll to re-arm") { self.clock.parked == 1 }
        XCTAssertTrue(store.listPolling)
        store.setListPolling(false)
    }

    func testAQuietRefreshOnlyReachesTheErrorBarAfterARunOfFailures() async {
        for _ in 0..<(ChatStore.quietFailureLimit - 1) { await store.loadSessions(quiet: true) }
        XCTAssertNil(store.error, "one blip stays quiet")

        await store.loadSessions(quiet: true)
        XCTAssertNotNil(store.error, "a list that has been stale for a while has to say so")

        transport.on("GET /api/sessions", .json(["sessions": []]))
        store.error = nil
        await store.loadSessions(quiet: true)   // success resets the run
        await store.loadSessions(quiet: true)   // fails, but it is the first again
        XCTAssertNil(store.error)
    }

    func testSelectingAModelPersistsItForTheChatSurface() {
        let selection = ModelSelection(store: MemoryKeyValueStore())
        store = ChatStore(api: JarvisAPI(credentials: TestCredentials(), transport: transport),
                          selection: selection, bus: bus, clock: clock)
        store.selectModel(ChatModel(id: "a/b", label: "AB", provider: "p"))
        XCTAssertEqual(selection.model(for: .chat), "a/b")
        XCTAssertEqual(store.selectedModelID, "a/b")

        store.selectModel(nil)
        XCTAssertNil(selection.model(for: .chat))
    }
}

// MARK: - Test doubles

final class FakeClipboard: ChatClipboard, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    var copied: [String] { lock.lock(); defer { lock.unlock() }; return items }
    func copy(_ text: String) { lock.lock(); items.append(text); lock.unlock() }
}

@MainActor
final class FakeOnDeviceHandler: OnDeviceChatHandler {
    let reply: OnDeviceReply
    let tokens: [String]
    private(set) var wasAsked = false

    init(reply: OnDeviceReply, tokens: [String] = []) {
        self.reply = reply
        self.tokens = tokens
    }

    func answer(_ text: String, emit: (String) -> Void) async -> OnDeviceReply {
        wasAsked = true
        for token in tokens { emit(token) }
        return reply
    }
}

final class ChatSyncBusTests: XCTestCase {

    func testEverySubscriberSeesEveryChange() async {
        let bus = ChatSyncBus()
        let a = StreamCollector<String?>()
        let b = StreamCollector<String?>()
        a.consume(bus.changes())
        b.consume(bus.changes())
        await waitUntil("both subscribers to attach") { bus.subscriberCount == 2 }

        bus.sessionChanged("s1")
        bus.sessionChanged(nil)
        await waitUntil("a to see both") { a.all.count == 2 }
        await waitUntil("b to see both") { b.all.count == 2 }
        XCTAssertEqual(a.all.map { $0 ?? "-" }, ["s1", "-"])
        XCTAssertEqual(b.all.map { $0 ?? "-" }, ["s1", "-"])
    }

    func testAFinishedSubscriberIsForgotten() async {
        let bus = ChatSyncBus()
        let collector = StreamCollector<String?>()
        let task = collector.consume(bus.changes())
        await waitUntil("the subscriber to attach") { bus.subscriberCount == 1 }
        task.cancel()
        await waitUntil("the subscriber to be dropped") { bus.subscriberCount == 0 }
        bus.sessionChanged("s1")   // must not trap
    }
}

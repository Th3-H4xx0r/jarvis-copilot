import XCTest
@testable import JarvisCopilot

/// Port of `test/api/chat_test.dart`: the `?stream=1` fast path, its
/// feature-detection fallback, and the rule that a fallback is only safe
/// *before* the first event reached the caller (otherwise the turn
/// double-submits).
final class ChatAPITests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Process-wide feature-detect flag (one server per app session) — reset it
        // before every test so tests don't leak into each other.
        ChatAPI.streamingStartSupported = nil
    }

    override func tearDown() {
        ChatAPI.streamingStartSupported = nil
        super.tearDown()
    }

    private let turn = sseFrames([("delta", ["text": "hello"]), ("done", ["usage": ["output_tokens": 2]])])

    private func drain(_ api: JarvisAPI) async throws -> [SSEEvent] {
        try await collect(ChatAPI(api: api).sendMessage(sessionID: "s1", text: "hi"))
    }

    // MARK: The four corners of the start matrix

    func testSSEReplyNeedsNoFallback() async throws {
        let (api, t) = JarvisAPI.scripted()
        t.on("POST /api/chat/start", .sse(turn))

        let events = try await drain(api)
        XCTAssertEqual(events.map(\.event), ["delta", "done"])
        XCTAssertEqual(t.count("POST /api/chat/start"), 1)
        XCTAssertEqual(t.count("GET /api/chat/stream"), 0)
        XCTAssertEqual(t.query("POST /api/chat/start", "stream"), "1")
        XCTAssertEqual(ChatAPI.streamingStartSupported, true)
    }

    func testJSONReplyMeansOldServerSoItStreamsTheReturnedStreamID() async throws {
        let (api, t) = JarvisAPI.scripted()
        t.on("POST /api/chat/start", .json(["stream_id": "stream-1"]))
        t.on("GET /api/chat/stream", .sse(turn))

        let events = try await drain(api)
        XCTAssertEqual(events.map(\.event), ["started", "delta", "done"])
        XCTAssertEqual(events.first?.string("stream_id"), "stream-1")
        XCTAssertEqual(t.query("GET /api/chat/stream", "stream_id"), "stream-1")
        XCTAssertEqual(t.count("POST /api/chat/start"), 1, "the JSON reply already started the turn — never re-post it")
        XCTAssertEqual(ChatAPI.streamingStartSupported, false, "stop paying the probe on this server")
    }

    func testJSONReplyWithoutAStreamIDIsAnError() async {
        let (api, t) = JarvisAPI.scripted()
        t.on("POST /api/chat/start", .json(["ok": true]))
        do {
            _ = try await drain(api)
            XCTFail("expected a failure")
        } catch {
            XCTAssertTrue("\(error)".contains("stream_id"), "\(error)")
        }
        XCTAssertEqual(t.count("POST /api/chat/start"), 1,
                       "the server already took the turn — a missing stream_id must not re-post it")
    }

    /// The Flutter matrix: SocketException / TimeoutException / HandshakeException /
    /// HttpException / StateError(404) all fall back to the classic two-step flow.
    func testFallsBackToTheClassicTwoStepFlowOnAnyPreFirstEventFailure() async throws {
        let failures: [Error] = [
            URLError(.cannotConnectToHost),
            URLError(.timedOut),
            URLError(.secureConnectionFailed),
            URLError(.networkConnectionLost),
            APIError.badResponse("not JSON"),
        ]
        for failure in failures {
            ChatAPI.streamingStartSupported = nil
            let (api, t) = JarvisAPI.scripted()
            t.on("POST /api/chat/start", .failing(failure))
            t.on("POST /api/chat/start", .json(["stream_id": "stream-1"]))
            t.on("GET /api/chat/stream", .sse(turn))

            let events = try await drain(api)
            XCTAssertEqual(events.map(\.event), ["started", "delta", "done"], "\(failure)")
            XCTAssertEqual(t.count("POST /api/chat/start"), 2, "should have fallen back to POST /api/chat/start (\(failure))")
            XCTAssertEqual(t.count("GET /api/chat/stream"), 1, "\(failure)")
        }
    }

    func testFallsBackWhenTheServerHasNoStreamQueryParameterYet() async throws {
        for status in [404, 405, 501] {
            ChatAPI.streamingStartSupported = nil
            let (api, t) = JarvisAPI.scripted()
            t.on("POST /api/chat/start", .json(["error": "not found"], status: status))
            t.on("POST /api/chat/start", .json(["stream_id": "s9"]))
            t.on("GET /api/chat/stream", .sse(turn))

            let events = try await drain(api)
            XCTAssertEqual(events.map(\.event), ["started", "delta", "done"], "HTTP \(status)")
            XCTAssertEqual(t.count("POST /api/chat/start"), 2, "HTTP \(status)")
        }
    }

    func testDoesNotFallBackOrDoubleSubmitOnceAnEventWasYielded() async {
        let (api, t) = JarvisAPI.scripted()
        t.on("POST /api/chat/start", .sse(sseFrames([("delta", ["text": "partial"])]),
                                          then: URLError(.networkConnectionLost)))
        do {
            _ = try await drain(api)
            XCTFail("expected the mid-stream failure to surface")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
        }
        XCTAssertEqual(t.count("POST /api/chat/start"), 1, "must not re-submit the turn after streaming had started")
    }

    /// A 2xx event-stream that says nothing still ran the turn on the server, so
    /// the stream ends silently and ``ChatStore`` recovers the reply from the
    /// session snapshot. Re-posting would ask the agent the same thing twice
    /// (swift-correctness H13).
    func testAnEmptyEventStreamIsCommittedAndNeverReposted() async throws {
        let (api, t) = JarvisAPI.scripted()
        t.on("POST /api/chat/start", .sse(""))

        let events = try await drain(api)
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(t.count("POST /api/chat/start"), 1, "the turn is already running; do not submit it again")
        XCTAssertEqual(ChatAPI.streamingStartSupported, true, "the server did open a stream")
    }

    /// The same rule for the other 2xx shapes: once the POST landed, nothing
    /// retries it — a body we cannot read surfaces as an error instead.
    func testAnUnreadableSuccessBodyIsAnErrorNotARetry() async {
        let (api, t) = JarvisAPI.scripted()
        t.on("POST /api/chat/start", .init(contentType: "text/html", body: Data("<html>proxy</html>".utf8)))
        do {
            _ = try await drain(api)
            XCTFail("expected the unreadable body to surface")
        } catch let error as APIError {
            guard case .badResponse = error else { return XCTFail("wrong error \(error)") }
        } catch { XCTFail("wrong error \(error)") }
        XCTAssertEqual(t.count("POST /api/chat/start"), 1)
    }

    func testResetFeatureDetectionForgetsThePreviousServer() {
        ChatAPI.streamingStartSupported = false
        ChatAPI.resetFeatureDetection()
        XCTAssertNil(ChatAPI.streamingStartSupported, "a re-pair must re-probe the new server")
    }

    /// Deviation from Flutter (which falls back on every non-2xx): 409 means a turn
    /// is already running on this session, and `ChatStore` attaches to it. Re-posting
    /// would either 409 again or start a duplicate turn, so it surfaces immediately.
    func testConflictIsSurfacedRatherThanRetried() async {
        let (api, t) = JarvisAPI.scripted()
        t.on("POST /api/chat/start", .json(["error": "busy"], status: 409))
        do {
            _ = try await drain(api)
            XCTFail("expected the 409 to surface")
        } catch APIError.http(let status, _) {
            XCTAssertEqual(status, 409)
        } catch {
            XCTFail("expected APIError.http, got \(error)")
        }
        XCTAssertEqual(t.count("POST /api/chat/start"), 1)
    }

    func testAKnownOldServerSkipsTheProbeEntirely() async throws {
        ChatAPI.streamingStartSupported = false
        let (api, t) = JarvisAPI.scripted()
        t.on("POST /api/chat/start", .json(["stream_id": "s3"]))
        t.on("GET /api/chat/stream", .sse(turn))

        let events = try await drain(api)
        XCTAssertEqual(events.map(\.event), ["started", "delta", "done"])
        XCTAssertEqual(t.count("POST /api/chat/start"), 1)
        XCTAssertNil(t.query("POST /api/chat/start", "stream"), "no probe on a server we know is old")
    }

    func testNotPairedIsNotRetried() async {
        let api = JarvisAPI(credentials: UnpairedCredentials(), transport: ScriptedTransport())
        do {
            _ = try await drain(api)
            XCTFail("expected notPaired")
        } catch {
            XCTAssertEqual(error as? APIError, .notPaired)
        }
    }

    // MARK: Request shapes

    func testStartBodyCarriesEveryOptionalFieldItWasGiven() async throws {
        let (api, t) = JarvisAPI.scripted()
        t.on("POST /api/chat/start", .sse(turn))
        _ = try await collect(ChatAPI(api: api).sendMessage(
            sessionID: "s1", text: "hi", model: "m", provider: "p",
            workspace: "w", profile: "prof",
            attachments: [["path": "/u/a.png"]]))

        let body = t.lastBody(for: "POST /api/chat/start")
        XCTAssertEqual(body["session_id"] as? String, "s1")
        XCTAssertEqual(body["message"] as? String, "hi")
        XCTAssertEqual(body["model"] as? String, "m")
        XCTAssertEqual(body["model_provider"] as? String, "p")
        XCTAssertEqual(body["workspace"] as? String, "w")
        XCTAssertEqual(body["profile"] as? String, "prof")
        XCTAssertEqual((body["attachments"] as? [[String: Any]])?.count, 1)
    }

    func testStartBodyOmitsEmptyOptionalFields() async throws {
        let (api, t) = JarvisAPI.scripted()
        t.on("POST /api/chat/start", .sse(turn))
        _ = try await collect(ChatAPI(api: api).sendMessage(
            sessionID: "s1", text: "hi", model: "", provider: nil, attachments: []))

        let body = t.lastBody(for: "POST /api/chat/start")
        XCTAssertEqual(Set(body.keys), ["session_id", "message"])
    }

    func testUploadFilePostsMultipartToTheUploadEndpoint() async throws {
        let (api, t) = JarvisAPI.scripted()
        t.on("POST /api/upload", .json(["filename": "a.png", "path": "/u/a.png", "is_image": true]))

        let result = try await ChatAPI(api: api).uploadFile(sessionID: "s1", data: Data([1, 2, 3]), filename: "a.png")
        XCTAssertEqual(result["path"] as? String, "/u/a.png")

        let request = t.requests.last!
        let contentType = request.value(forHTTPHeaderField: "Content-Type") ?? ""
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="), contentType)
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"session_id\"\r\n\r\ns1"), body)
        XCTAssertTrue(body.contains("name=\"file\"; filename=\"a.png\""), body)
        XCTAssertTrue(body.contains("Content-Type: image/png"), "the mime type comes from the extension")
    }

    func testCancelAndClarifyHitTheirEndpoints() async throws {
        let (api, t) = JarvisAPI.scripted()
        t.on("GET /api/chat/cancel", .json(["ok": true]))
        t.on("POST /api/clarify/respond", .json(["ok": true]))

        let chat = ChatAPI(api: api)
        _ = try await chat.cancel("stream-7")
        XCTAssertEqual(t.query("GET /api/chat/cancel", "stream_id"), "stream-7")

        try await chat.respondClarify(sessionID: "s1", answer: "the second one")
        XCTAssertEqual(t.lastBody(for: "POST /api/clarify/respond")["response"] as? String, "the second one")
        XCTAssertEqual(t.lastBody(for: "POST /api/clarify/respond")["session_id"] as? String, "s1")
    }

    func testStreamEventsSubscribesWithTheStreamID() async throws {
        let (api, t) = JarvisAPI.scripted()
        t.on("GET /api/chat/stream", .sse(turn))
        let events = try await collect(ChatAPI(api: api).streamEvents("abc"))
        XCTAssertEqual(events.map(\.event), ["delta", "done"])
        XCTAssertEqual(t.query("GET /api/chat/stream", "stream_id"), "abc")
    }
}

/// A server we were never paired with.
struct UnpairedCredentials: APICredentials {
    var baseURL: URL? { nil }
    var headers: [String: String] { [:] }
}

final class SessionsAPITests: XCTestCase {

    func testListParsesTheSessionRows() async throws {
        let (api, t) = JarvisAPI.scripted()
        t.on("GET /api/sessions", .json(["sessions": [
            ["session_id": "a", "title": "One", "updated_at": 2],
            ["session_id": "b", "title": "Two", "updated_at": 9],
        ]]))
        let rows = try await SessionsAPI(api: api).list()
        XCTAssertEqual(rows.map(\.id), ["a", "b"], "order is the store's business")
        XCTAssertEqual(rows.last?.title, "Two")
    }

    func testListCanAskForEveryProfile() async throws {
        let (api, t) = JarvisAPI.scripted()
        t.on("GET /api/sessions", .json(["sessions": []]))
        _ = try await SessionsAPI(api: api).list(allProfiles: true)
        XCTAssertEqual(t.query("GET /api/sessions", "all_profiles"), "1")
    }

    func testGetHydratesTitleMessagesAndTheActiveStream() async throws {
        let (api, t) = JarvisAPI.scripted()
        t.on("GET /api/session", .json(["session": [
            "session_id": "s1",
            "title": "  Dinner  ",
            "active_stream_id": "live-1",
            "messages": [
                ["role": "user", "content": "hi"],
                ["role": "assistant", "content": "", "tool_calls": [["id": "c1", "function": ["name": "search", "arguments": "{}"]]]],
                ["role": "tool", "tool_call_id": "c1", "content": "3 results"],
            ],
        ]]))
        let detail = try await SessionsAPI(api: api).get("s1")
        XCTAssertEqual(detail.title, "Dinner")
        XCTAssertEqual(detail.activeStreamID, "live-1")
        XCTAssertEqual(detail.messages.count, 2)
        XCTAssertEqual(detail.messages.last?.tools.first?.result, "3 results")
        XCTAssertEqual(t.query("GET /api/session", "messages"), "1")
        XCTAssertEqual(t.query("GET /api/session", "resolve_model"), "0")
    }

    func testGetAcceptsAnUnwrappedBody() async throws {
        let (api, t) = JarvisAPI.scripted()
        t.on("GET /api/session", .json(["title": "Bare", "messages": [["role": "user", "content": "yo"]]]))
        let detail = try await SessionsAPI(api: api).get("s1")
        XCTAssertEqual(detail.title, "Bare")
        XCTAssertEqual(detail.messages.count, 1)
        XCTAssertNil(detail.activeStreamID)
    }

    func testCreateReadsTheIDFromEitherShape() async throws {
        for payload in [["session_id": "n1"], ["session": ["session_id": "n1"]], ["session": ["id": "n1"]]] as [[String: Any]] {
            let (api, t) = JarvisAPI.scripted()
            t.on("POST /api/session/new", .json(payload))
            let id = try await SessionsAPI(api: api).create()
            XCTAssertEqual(id, "n1")
        }
    }

    func testCreateWithoutAnIDIsAnError() async {
        let (api, t) = JarvisAPI.scripted()
        t.on("POST /api/session/new", .json(["ok": true]))
        do {
            _ = try await SessionsAPI(api: api).create(title: "T", profile: "P")
            XCTFail("expected a failure")
        } catch {
            XCTAssertTrue("\(error)".lowercased().contains("session"), "\(error)")
        }
    }

    func testRenamePinAndDeletePostTheirBodies() async throws {
        let (api, t) = JarvisAPI.scripted()
        t.on("POST /api/session/rename", .json([:]))
        t.on("POST /api/session/pin", .json([:]))
        t.on("POST /api/session/delete", .json([:]))
        let sessions = SessionsAPI(api: api)

        try await sessions.rename("s1", title: "New name")
        XCTAssertEqual(t.lastBody(for: "POST /api/session/rename")["title"] as? String, "New name")
        try await sessions.pin("s1", pinned: true)
        XCTAssertEqual(t.lastBody(for: "POST /api/session/pin")["pinned"] as? Bool, true)
        try await sessions.delete("s1")
        XCTAssertEqual(t.lastBody(for: "POST /api/session/delete")["session_id"] as? String, "s1")
    }

    func testAppendLocalTurnIsBestEffortAndSkipsEmptyTurns() async {
        let (api, t) = JarvisAPI.scripted()
        let sessions = SessionsAPI(api: api)

        await sessions.appendLocalTurn("s1", user: "  ", assistant: "")
        XCTAssertEqual(t.count("POST /api/session/append"), 0, "nothing to persist")

        // No step scripted → the transport errors, and it must be swallowed.
        await sessions.appendLocalTurn("s1", user: "hi", assistant: "hello")
        XCTAssertEqual(t.count("POST /api/session/append"), 1)

        t.on("POST /api/session/append", .json([:]))
        await sessions.appendLocalTurn("s1", user: "hi", assistant: "hello")
        let body = t.lastBody(for: "POST /api/session/append")
        XCTAssertEqual(body["on_device"] as? Bool, true)
        XCTAssertEqual(body["assistant"] as? String, "hello")
    }

    func testSnapshotFindsTheActiveStreamTheLastReplyAndItsTools() async throws {
        let (api, t) = JarvisAPI.scripted()
        t.on("GET /api/session", .json(["session": [
            "active_stream_id": "live-9",
            "messages": [
                ["role": "user", "content": "hi"],
                ["role": "assistant", "content": "the answer"],
                // A tool-call-only assistant record after the text: the walk back
                // must step over it rather than reporting an empty reply.
                ["role": "assistant", "content": "", "tool_calls": [["function": ["name": "search"]]]],
            ],
        ]]))
        let snap = try await SessionsAPI(api: api).snapshot("s1")
        XCTAssertEqual(snap.activeStreamID, "live-9")
        XCTAssertEqual(snap.lastAssistantText, "the answer")
        XCTAssertEqual(snap.lastToolNames, ["search"])
    }

    func testSnapshotReadsArrayContentAndReportsNoActiveStream() async throws {
        let (api, t) = JarvisAPI.scripted()
        t.on("GET /api/session", .json(["session": [
            "active_stream_id": "",
            "messages": [["role": "assistant", "content": [["type": "text", "text": "parts"]]]],
        ]]))
        let snap = try await SessionsAPI(api: api).snapshot("s1")
        XCTAssertNil(snap.activeStreamID)
        XCTAssertEqual(snap.lastAssistantText, "parts")
    }
}

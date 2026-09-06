import XCTest
@testable import JarvisCopilot

final class SSEParserTests: XCTestCase {
    func testParsesNamedEventWithJSONObject() {
        var p = SSEParser()
        XCTAssertNil(p.feed(line: "event: delta"))
        XCTAssertNil(p.feed(line: "data: {\"text\":\"hi\"}"))
        let ev = p.feed(line: "")
        XCTAssertEqual(ev?.event, "delta")
        XCTAssertEqual(ev?.string("text"), "hi")
    }

    func testServerEventKeyInsidePayloadWins() {
        var p = SSEParser()
        _ = p.feed(line: "data: {\"event\":\"tool\",\"name\":\"search\"}")
        let ev = p.feed(line: "")
        XCTAssertEqual(ev?.event, "tool")
        XCTAssertEqual(ev?.string("name"), "search")
    }

    func testMultiLineDataAndComments() {
        var p = SSEParser()
        _ = p.feed(line: ": keepalive")
        _ = p.feed(line: "data: line one")
        _ = p.feed(line: "data: line two")
        let ev = p.feed(line: "")
        XCTAssertEqual(ev?.event, "message")
        XCTAssertEqual(ev?.object["data"] as? String, "line one\nline two")
    }

    func testBlankLineWithoutDataEmitsNothing() {
        var p = SSEParser()
        XCTAssertNil(p.feed(line: ""))
        XCTAssertNil(p.feed(line: "event: done"))
        XCTAssertNil(p.feed(line: ""))
    }

    func testFinishFlushesTrailingEvent() {
        var p = SSEParser()
        _ = p.feed(line: "data: {\"event\":\"done\"}")
        XCTAssertEqual(p.finish()?.event, "done")
        XCTAssertNil(p.finish())
    }
}

final class MultipartBodyTests: XCTestCase {
    func testEncodesFieldsAndFile() {
        var m = MultipartBody(boundary: "B")
        m.add("session_id", "s1")
        m.add(file: .init(field: "file", filename: "a.png", mime: "image/png", data: Data([1, 2, 3])))
        let s = String(decoding: m.encoded(), as: UTF8.self)
        XCTAssertEqual(m.contentType, "multipart/form-data; boundary=B")
        XCTAssertTrue(s.hasPrefix("--B\r\nContent-Disposition: form-data; name=\"session_id\"\r\n\r\ns1\r\n"))
        XCTAssertTrue(s.contains("name=\"file\"; filename=\"a.png\"\r\nContent-Type: image/png\r\n\r\n"))
        XCTAssertTrue(s.hasSuffix("\r\n--B--\r\n"))
    }
}

final class APIErrorTests: XCTestCase {
    func testPrefersServerErrorField() {
        XCTAssertEqual(APIError.message(status: 400, body: Data("{\"error\":\"nope\"}".utf8)), "nope")
        XCTAssertEqual(APIError.message(status: 400, body: Data("short text".utf8)), "short text")
        // An HTML error page carries nothing a user can act on, so the status is
        // the answer rather than a blank line (swift-correctness M39).
        XCTAssertEqual(APIError.message(status: 502, body: Data("<html>bad gateway</html>".utf8)),
                       "Request failed (502)")
        XCTAssertEqual(APIError.message(status: 500, body: Data()), "Request failed (500)")
        XCTAssertEqual(APIError.http(status: 502, message: "").errorDescription, "Request failed (502)")
    }

    func testURLErrorsBecomeFriendly() {
        let e = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        XCTAssertEqual(apiErrorMessage(e), "No internet connection")
    }
}

final class JarvisAPITests: XCTestCase {
    func testGetBuildsURLWithAuthAndSortedQuery() async throws {
        let (api, t) = JarvisAPI.mocked()
        t.enqueue(json: ["ok": true])
        let r = try await api.get("/api/sessions", query: ["b": "2", "a": "1 x"])
        XCTAssertEqual(try r.object()["ok"] as? Bool, true)
        let req = t.lastRequest!
        XCTAssertEqual(req.url?.absoluteString, "https://jarvis.test/api/sessions?a=1%20x&b=2")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Cookie"), "hermes_session=abc")
        XCTAssertEqual(req.httpMethod, "GET")
    }

    func testPathWithoutLeadingSlashWorks() async throws {
        let (api, t) = JarvisAPI.mocked()
        t.enqueue(json: [:])
        _ = try await api.get("api/models")
        XCTAssertEqual(t.lastRequest?.url?.path, "/api/models")
    }

    func testPostEncodesJSONBody() async throws {
        let (api, t) = JarvisAPI.mocked()
        t.enqueue(json: ["id": "x"])
        _ = try await api.post("/api/session/new", json: ["title": "T", "n": 2])
        XCTAssertEqual(t.lastRequest?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(t.lastBody()["title"] as? String, "T")
        XCTAssertEqual(t.lastBody()["n"] as? Int, 2)
    }

    func testPostEncodesEncodableBodyInSnakeCase() async throws {
        struct Body: Encodable { let sessionId: String }
        let (api, t) = JarvisAPI.mocked()
        t.enqueue(json: [:])
        _ = try await api.post("/x", json: Body(sessionId: "s"))
        XCTAssertEqual(t.lastBody()["session_id"] as? String, "s")
    }

    func testNon2xxThrowsHTTPErrorWithServerMessage() async {
        let (api, t) = JarvisAPI.mocked()
        t.enqueue(json: ["error": "session not found"], status: 404)
        do {
            _ = try await api.get("/api/session")
            XCTFail("expected throw")
        } catch let e as APIError {
            XCTAssertEqual(e, .http(status: 404, message: "session not found"))
        } catch { XCTFail("wrong error \(error)") }
    }

    func testUnpairedThrowsNotPaired() async {
        let api = JarvisAPI(credentials: TestCredentials(baseURL: nil), transport: MockTransport())
        do { _ = try await api.get("/x"); XCTFail() }
        catch { XCTAssertEqual(error as? APIError, .notPaired) }
    }

    func testDecodeUsesSnakeCase() async throws {
        struct S: Decodable, Equatable { let sessionId: String; let tokenCount: Int }
        let (api, t) = JarvisAPI.mocked()
        t.enqueue(json: ["session_id": "s", "token_count": 3])
        let s = try await api.get("/x").decode(S.self)
        XCTAssertEqual(s, S(sessionId: "s", tokenCount: 3))
    }

    func testArrayUnwrapsWrapperObject() async throws {
        let (api, t) = JarvisAPI.mocked()
        t.enqueue(json: ["sessions": [["id": 1], ["id": 2]]])
        let arr = try await api.get("/x").array()
        XCTAssertEqual(arr.count, 2)
    }

    func testStreamSSEYieldsEventsAndSetsAccept() async throws {
        let (api, t) = JarvisAPI.mocked()
        t.enqueueSSE("event: delta\ndata: {\"text\":\"a\"}\n\nevent: delta\ndata: {\"text\":\"b\"}\n\ndata: {\"event\":\"done\"}\n\n")
        let events = try await collect(api.streamSSE("/api/chat/stream", query: ["stream_id": "s"]))
        XCTAssertEqual(events.map(\.event), ["delta", "delta", "done"])
        XCTAssertEqual(events[1].string("text"), "b")
        XCTAssertEqual(t.lastRequest?.value(forHTTPHeaderField: "Accept"), "text/event-stream")
    }

    func testStreamSSEErrorStatusThrowsBeforeAnyEvent() async {
        let (api, t) = JarvisAPI.mocked()
        t.enqueue(Reply: .init(status: 409, body: Data("{\"error\":\"busy\"}".utf8), headers: ["Content-Type": "application/json"]))
        do { _ = try await collect(api.streamSSE("/x")); XCTFail() }
        catch { XCTAssertEqual(error as? APIError, .http(status: 409, message: "busy")) }
    }

    func testPostSSEOrJSONFallsBackToSingleJSON() async throws {
        let (api, t) = JarvisAPI.mocked()
        t.enqueue(json: ["stream_id": "abc"])
        let out = try await collect(api.postSSEOrJSON("/api/chat/start", json: ["message": "hi"], query: ["stream": "1"]))
        XCTAssertEqual(out.count, 1)
        guard case .json(let obj) = out[0] else { return XCTFail("expected json") }
        XCTAssertEqual(obj["stream_id"] as? String, "abc")
        XCTAssertEqual(t.lastRequest?.url?.query, "stream=1")
    }

    func testPostSSEOrJSONStreamsWhenEventStream() async throws {
        let (api, t) = JarvisAPI.mocked()
        t.enqueueSSE("data: {\"event\":\"delta\",\"text\":\"x\"}\n\n")
        let out = try await collect(api.postSSEOrJSON("/api/chat/start", json: [:]))
        guard case .event(let ev) = out.first else { return XCTFail("expected event") }
        XCTAssertEqual(ev.string("text"), "x")
    }

    func testNDJSONSkipsBlankAndMalformedLines() async throws {
        let (api, t) = JarvisAPI.mocked()
        t.enqueue(text: "{\"a\":1}\n\nnot json\n{\"a\":2}\n", contentType: "application/x-ndjson")
        let rows = try await collect(api.streamNDJSON("/x"))
        XCTAssertEqual(rows.compactMap { $0["a"] as? Int }, [1, 2])
    }

    func testMultipartSetsBoundaryHeader() async throws {
        let (api, t) = JarvisAPI.mocked()
        t.enqueue(json: ["path": "/tmp/a"])
        var m = MultipartBody(boundary: "Z"); m.add("session_id", "s")
        _ = try await api.postMultipart("/api/upload", m)
        XCTAssertEqual(t.lastRequest?.value(forHTTPHeaderField: "Content-Type"), "multipart/form-data; boundary=Z")
    }

    func testArrayPrefersAKnownWrapperKeyOverDictionaryOrder() async throws {
        let (api, t) = JarvisAPI.mocked()
        t.enqueue(json: ["warnings": ["only one"], "items": [["id": 1], ["id": 2]]])
        let arr = try await api.get("/x").array()
        XCTAssertEqual(arr.count, 2, "the known wrapper key wins, whatever order the dict iterates in")
    }

    func testArrayWithoutAKnownWrapperKeyThrowsInsteadOfGuessing() async {
        let (api, t) = JarvisAPI.mocked()
        t.enqueue(json: ["rows": [["id": 1]]])
        do { _ = try await api.get("/x").array(); XCTFail("expected throw") }
        catch let e as APIError {
            guard case .badResponse(let why) = e else { return XCTFail("wrong error \(e)") }
            XCTAssertTrue(why.contains("rows"), why)
        } catch { XCTFail("wrong error \(error)") }
    }

    func testArrayWithAnExplicitKeyReadsThatKeyOnly() async throws {
        let (api, t) = JarvisAPI.mocked()
        t.enqueue(json: ["rows": [["id": 1]], "items": [["id": 2], ["id": 3]]])
        let r = try await api.get("/x")
        XCTAssertEqual(try r.array(key: "rows").count, 1)
        do { _ = try r.array(key: "missing"); XCTFail("expected throw") }
        catch { XCTAssertEqual(error as? APIError, .badResponse("expected an array under \"missing\"")) }
    }

    func testPostSSEOrJSONRejectsANonJSONSuccessBody() async {
        let (api, t) = JarvisAPI.mocked()
        t.enqueue(text: "<html>tunnel error</html>", contentType: "text/html")
        do { _ = try await collect(api.postSSEOrJSON("/api/chat/start", json: [:])); XCTFail("expected throw") }
        catch let e as APIError {
            guard case .badResponse(let why) = e else { return XCTFail("wrong error \(e)") }
            XCTAssertTrue(why.contains("text/html"), why)
        } catch { XCTFail("wrong error \(error)") }
    }

    func testPostSSEOrJSONReportsTheOpenResponseBeforeAnyBody() async throws {
        let (api, t) = JarvisAPI.mocked()
        t.enqueueSSE("data: {\"event\":\"delta\",\"text\":\"x\"}\n\n")
        let seen = CoreBox<String?>(nil)
        _ = try await collect(api.postSSEOrJSON("/api/chat/start", json: [:], onOpen: { http in
            seen.value = http.value(forHTTPHeaderField: "Content-Type")
        }))
        XCTAssertEqual(seen.value, "text/event-stream")
    }

    func testPostSSEOrJSONDoesNotReportAnOpenForANonTwoHundred() async {
        let (api, t) = JarvisAPI.mocked()
        t.enqueue(json: ["error": "busy"], status: 409)
        let seen = CoreBox<Bool>(false)
        _ = try? await collect(api.postSSEOrJSON("/api/chat/start", json: [:], onOpen: { _ in seen.value = true }))
        XCTAssertFalse(seen.value, "the POST never landed, so it is not committed")
    }

    func testNDJSONWithNothingParseableIsAnError() async {
        let (api, t) = JarvisAPI.mocked()
        t.enqueue(text: "not json\nalso not json\n", contentType: "application/x-ndjson")
        do { _ = try await collect(api.streamNDJSON("/x")); XCTFail("expected throw") }
        catch let e as APIError {
            guard case .badResponse(let why) = e else { return XCTFail("wrong error \(e)") }
            XCTAssertTrue(why.contains("no JSON rows"), why)
        } catch { XCTFail("wrong error \(error)") }
    }

    // MARK: bytes(absolute:)

    func testBytesRelativeGoesThroughThePairedBaseWithCredentials() async throws {
        let (api, t) = JarvisAPI.mocked()
        t.enqueue(Reply: .init(status: 200, body: Data([9, 9]), headers: ["Content-Type": "image/png"]))
        let data = try await api.bytes("/api/media?path=x")
        XCTAssertEqual(data, Data([9, 9]))
        XCTAssertEqual(t.lastRequest?.url?.host, "jarvis.test")
        XCTAssertEqual(t.lastRequest?.value(forHTTPHeaderField: "Cookie"), "hermes_session=abc")
    }

    func testBytesAbsoluteKeepsCredentialsForThePairedOrigin() async throws {
        let (api, t) = JarvisAPI.mocked()
        t.enqueue(Reply: .init(status: 200, body: Data([1]), headers: [:]))
        _ = try await api.bytes("https://jarvis.test/api/media?path=a.png", absolute: true)
        XCTAssertEqual(t.lastRequest?.value(forHTTPHeaderField: "Cookie"), "hermes_session=abc")
    }

    func testBytesAbsoluteNeverLeaksCredentialsToAnotherHost() async throws {
        let (api, t) = JarvisAPI.mocked()
        t.enqueue(Reply: .init(status: 200, body: Data([1]), headers: [:]))
        _ = try await api.bytes("https://evil.example/cat.png", absolute: true)
        XCTAssertNil(t.lastRequest?.value(forHTTPHeaderField: "Cookie"),
                     "a markdown image URL must not carry the session cookie off-origin")
    }

    func testBytesAbsoluteRejectsAnUnparseableURL() async {
        let (api, _) = JarvisAPI.mocked()
        do { _ = try await api.bytes("ht tp://nope", absolute: true); XCTFail("expected throw") }
        catch { XCTAssertEqual(error as? APIError, .badResponse("bad URL")) }
    }

    func testPairedOriginComparesSchemeHostAndPort() {
        let base = URL(string: "https://jarvis.test")!
        XCTAssertTrue(JarvisAPI.isPairedOrigin(URL(string: "https://jarvis.test/a")!, base: base))
        XCTAssertTrue(JarvisAPI.isPairedOrigin(URL(string: "https://JARVIS.test:443/a")!, base: base))
        XCTAssertFalse(JarvisAPI.isPairedOrigin(URL(string: "http://jarvis.test/a")!, base: base))
        XCTAssertFalse(JarvisAPI.isPairedOrigin(URL(string: "https://jarvis.test:8443/a")!, base: base))
        XCTAssertFalse(JarvisAPI.isPairedOrigin(URL(string: "https://other.test/a")!, base: base))
        XCTAssertFalse(JarvisAPI.isPairedOrigin(URL(string: "https://jarvis.test/a")!, base: nil))
    }

    // MARK: stream failure and cancellation

    func testAMidStreamFailureSurfacesAfterTheEventsItAlreadyDelivered() async {
        let transport = CoreChunkTransport(
            chunks: ["event: delta\ndata: {\"text\":\"a\"}\n\n", "event: delta\ndata: {\"text\":\"b\"}\n\n"],
            failure: APIError.http(status: 500, message: "boom"))
        let api = JarvisAPI(credentials: TestCredentials(), transport: transport)
        let collector = StreamCollector<SSEEvent>()
        collector.consume(api.streamSSE("/api/chat/stream"))
        await waitUntil("the stream to fail") { collector.finished }
        XCTAssertEqual(collector.all.map { $0.string("text") }, ["a", "b"],
                       "everything that arrived before the failure is kept")
        XCTAssertEqual(collector.error as? APIError, .http(status: 500, message: "boom"))
    }

    /// A consumer that walks away mid-stream must take the socket with it — the
    /// server holds this one open forever, so nothing else would end it.
    ///
    /// The stream is deliberately never bound to a local: an `AsyncThrowingStream`
    /// only tears down once BOTH the stream value and its iterator are gone, so
    /// keeping a reference around would keep the transport connected.
    func testAbandoningAStreamCancelsTheTransport() async {
        let transport = CoreChunkTransport(chunks: ["event: delta\ndata: {\"text\":\"a\"}\n\n"], hold: true)
        let api = JarvisAPI(credentials: TestCredentials(), transport: transport)
        let task = Task {
            for try await _ in api.streamSSE("/api/chat/stream") { break }
        }
        _ = try? await task.value
        await waitUntil("the transport stream to be torn down") { transport.terminated }
        XCTAssertTrue(transport.terminated)
    }

    func testDictionaryHelpersCoerce() {
        let d: [String: Any] = ["i": "7", "d": 1, "b": "true", "s": 3, "l": ["a", 1]]
        XCTAssertEqual(d.int("i"), 7)
        XCTAssertEqual(d.double("d"), 1)
        XCTAssertEqual(d.bool("b"), true)
        XCTAssertEqual(d.string("s"), "3")
        XCTAssertEqual(d.strings("l"), ["a"])
        XCTAssertNil(d.string("missing"))
    }
}

/// A boxed value a `@Sendable` callback can write to.
final class CoreBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// Streams pre-baked chunks, then fails, finishes, or stays open — the three
/// endings `MockTransport` cannot script.
final class CoreChunkTransport: APITransport, @unchecked Sendable {
    private let chunks: [String]
    private let failure: Error?
    private let hold: Bool
    private let lock = NSLock()
    private var torn = false
    private var held: AsyncThrowingStream<Data, Error>.Continuation?

    init(chunks: [String], failure: Error? = nil, hold: Bool = false) {
        self.chunks = chunks; self.failure = failure; self.hold = hold
    }

    var terminated: Bool { lock.lock(); defer { lock.unlock() }; return torn }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        _ = request
        throw APIError.badResponse("CoreChunkTransport streams only")
    }

    func stream(_ request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse) {
        let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                   headerFields: ["Content-Type": "text/event-stream"])!
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock(); self.torn = true; self.lock.unlock()
            }
            for chunk in self.chunks { continuation.yield(Data(chunk.utf8)) }
            if let failure = self.failure { continuation.finish(throwing: failure) }
            else if self.hold { self.lock.lock(); self.held = continuation; self.lock.unlock() }
            else { continuation.finish() }
        }
        return (stream, http)
    }
}


private extension MockTransport {
    func enqueue(Reply r: Reply) { enqueue(r) }
}

final class LineSplitterTests: XCTestCase {
    private func stream(_ s: String) -> AsyncThrowingStream<UInt8, Error> {
        AsyncThrowingStream { c in for b in Data(s.utf8) { c.yield(b) }; c.finish() }
    }

    func testKeepsEmptyLinesAndHandlesCRLF() async throws {
        let lines = try await collect(stream("a\r\n\nb\n\n").allLines)
        XCTAssertEqual(lines, ["a", "", "b", ""])
    }

    func testEmitsUnterminatedTail() async throws {
        let lines = try await collect(stream("x\ny").allLines)
        XCTAssertEqual(lines, ["x", "y"])
    }

    /// The production path: the transport vends `Data` chunks that cut wherever
    /// the socket happened to break, so a line must survive being split in two.
    private func chunks(_ parts: [String]) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { c in for p in parts { c.yield(Data(p.utf8)) }; c.finish() }
    }

    func testDataChunksReassembleLinesSplitAcrossThem() async throws {
        let lines = try await collect(chunks(["ev", "ent: del", "ta\r\n\ndata:", " 1\n"]).allLines)
        XCTAssertEqual(lines, ["event: delta", "", "data: 1"])
    }

    func testDataChunksEmitEveryLineOfAChunkAndTheTail() async throws {
        let lines = try await collect(chunks(["a\nb\nc"]).allLines)
        XCTAssertEqual(lines, ["a", "b", "c"])
    }

    func testDataChunksKeepEmptyLinesAtAChunkBoundary() async throws {
        let lines = try await collect(chunks(["a\n", "\n", "b\n"]).allLines)
        XCTAssertEqual(lines, ["a", "", "b"])
    }
}

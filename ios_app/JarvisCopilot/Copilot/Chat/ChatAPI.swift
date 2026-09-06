import Foundation
import UniformTypeIdentifiers

/// One streaming chat turn, ported from `api/chat.dart`. Mirrors the web UI
/// contract: `POST /api/chat/start` creates a run, then `GET /api/chat/stream`
/// (SSE) delivers the frames.
///
/// The frames we care about:
///   - `{ event: "delta"/"token", text }`     — a text chunk
///   - `{ event: "thinking"/"reasoning" }`    — the collapsible trace
///   - `{ event: "tool", name, args }`        — a tool call starting
///   - `{ event: "tool_result", … }`          — that call finishing
///   - `{ event: "metering", usage }`         — tokens for the turn
///   - `{ event: "done" }`                    — end of turn
///
/// Unknown events are surfaced verbatim so future server-side additions don't
/// break us. See ``ChatStreamReducer`` for how they fold into a turn.
struct ChatAPI {
    let api: JarvisAPI

    init(api: JarvisAPI = .shared) { self.api = api }

    // MARK: Feature detection

    /// Whether this server collapses start+stream into one response (plan 5.1).
    /// `nil` = not probed yet; `false` = probed and unsupported (older server), so
    /// we stop paying the probe. Process-wide: one server per app session.
    static var streamingStartSupported: Bool? {
        get { probe.value }
        set { probe.value = newValue }
    }

    /// Forget what we learned about the server we *were* talking to. The probe is
    /// process-wide, so without this a re-pair onto an older (or newer) server
    /// keeps the previous verdict for the life of the app. ``PairStore`` is the
    /// caller that has to invoke it — see the port report.
    static func resetFeatureDetection() { streamingStartSupported = nil }

    private static let probe = FeatureProbe()

    private final class FeatureProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Bool?
        var value: Bool? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    // MARK: Sending

    /// Start a turn and stream its frames.
    ///
    /// Fast path: `POST /api/chat/start?stream=1` answers with the SSE stream
    /// directly, saving a whole tunnel round-trip per turn. It is feature-detected
    /// — an older server answers with the ordinary start JSON, and we fall through
    /// to the classic two-step flow.
    func sendMessage(sessionID: String, text: String, model: String? = nil, provider: String? = nil,
                     workspace: String? = nil, profile: String? = nil,
                     attachments: [[String: Any]]? = nil) -> AsyncThrowingStream<SSEEvent, Error> {
        let body = startBody(sessionID: sessionID, text: text, model: model, provider: provider,
                             workspace: workspace, profile: profile, attachments: attachments)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Declared out here so the `catch` can see it: falling back is only
                    // safe while the turn has NOT reached the server. A 2xx on the POST
                    // means the server took the turn, whatever the body then does — so
                    // the flag is raised at *open*, not on the first event. Re-posting a
                    // committed turn runs it twice (swift-correctness H13).
                    let committed = CommitFlag()
                    if Self.streamingStartSupported != false {
                        do {
                            let stream = api.postSSEOrJSON(
                                "/api/chat/start", json: body, query: ["stream": "1"],
                                onOpen: { response in
                                    let ctype = (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
                                    committed.raise()
                                    Self.streamingStartSupported = ctype.contains("event-stream")
                                })
                            for try await item in stream {
                                switch item {
                                case .json(let object):
                                    // Not a stream — the server answered with the ordinary
                                    // start JSON, so it already accepted the turn. Stream
                                    // its id; never re-post, not even if the body turns out
                                    // to be missing one.
                                    Self.streamingStartSupported = false
                                    continuation.yield(Self.startedEvent(object))
                                    try await pump(streamEvents(try Self.streamID(of: object)), into: continuation)
                                    continuation.finish()
                                    return
                                case .event(let event):
                                    continuation.yield(event)
                                }
                            }
                            // An event-stream that said nothing still ran the turn: the
                            // server has the answer even though the socket carried none
                            // of it. End quietly and let ``ChatStore`` recover the reply
                            // from the session snapshot — re-posting would ask twice.
                            if committed.isSet { continuation.finish(); return }
                            Self.streamingStartSupported = false
                        } catch {
                            guard !committed.isSet, Self.canFallBack(from: error) else { throw error }
                            Self.streamingStartSupported = false
                        }
                    }

                    let start = try await startMessage(
                        sessionID: sessionID, text: text, model: model, provider: provider,
                        workspace: workspace, profile: profile, attachments: attachments)
                    continuation.yield(Self.startedEvent(start))
                    try await pump(streamEvents(try Self.streamID(of: start)), into: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The classic two-step start: returns the raw body, `stream_id` included.
    func startMessage(sessionID: String, text: String, model: String? = nil, provider: String? = nil,
                      workspace: String? = nil, profile: String? = nil,
                      attachments: [[String: Any]]? = nil) async throws -> [String: Any] {
        try await api.post("/api/chat/start", json: startBody(
            sessionID: sessionID, text: text, model: model, provider: provider,
            workspace: workspace, profile: profile, attachments: attachments)).object()
    }

    func streamEvents(_ streamID: String) -> AsyncThrowingStream<SSEEvent, Error> {
        api.streamSSE("/api/chat/stream", query: ["stream_id": streamID])
    }

    @discardableResult
    func cancel(_ streamID: String) async throws -> [String: Any] {
        try await api.get("/api/chat/cancel", query: ["stream_id": streamID]).object()
    }

    /// Answer the agent's open clarify question so the blocked turn resumes.
    func respondClarify(sessionID: String, answer: String) async throws {
        _ = try await api.post("/api/clarify/respond", json: ["session_id": sessionID, "response": answer])
    }

    /// Upload one composer attachment to `/api/upload` (multipart). Returns the
    /// full result map (`{filename, path, mime, size, is_image}`) — the shape
    /// `/api/chat/start` expects in its `attachments[]`.
    func uploadFile(sessionID: String, data: Data, filename: String) async throws -> [String: Any] {
        var form = MultipartBody()
        form.add("session_id", sessionID)
        form.add(file: .init(field: "file", filename: filename,
                             mime: Self.mimeType(for: filename), data: data))
        // Uploads are slow on a phone tunnel; the Flutter client allows a minute.
        return try await api.postMultipart("/api/upload", form, timeout: 60).object()
    }

    // MARK: Plumbing

    private func startBody(sessionID: String, text: String, model: String?, provider: String?,
                           workspace: String?, profile: String?,
                           attachments: [[String: Any]]?) -> [String: Any] {
        var body: [String: Any] = ["session_id": sessionID, "message": text]
        if let model, !model.isEmpty { body["model"] = model }
        if let provider, !provider.isEmpty { body["model_provider"] = provider }
        if let workspace, !workspace.isEmpty { body["workspace"] = workspace }
        if let profile, !profile.isEmpty { body["profile"] = profile }
        if let attachments, !attachments.isEmpty { body["attachments"] = attachments }
        return body
    }

    private func pump(_ stream: AsyncThrowingStream<SSEEvent, Error>,
                      into continuation: AsyncThrowingStream<SSEEvent, Error>.Continuation) async throws {
        for try await event in stream { continuation.yield(event) }
    }

    private static func streamID(of body: [String: Any]) throws -> String {
        guard let id = body.string("stream_id"), !id.isEmpty else {
            throw APIError.badResponse("chat/start did not return stream_id")
        }
        return id
    }

    /// The `started` frame the two-step flow synthesises, so a caller sees the same
    /// event shape whichever path ran.
    private static func startedEvent(_ body: [String: Any]) -> SSEEvent {
        var object = body
        object["event"] = "started"
        let raw = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
        return SSEEvent(event: "started", raw: raw, object: object)
    }

    /// Whether a failed streaming start should be retried on the classic path.
    ///
    /// Connect-level failures (refused, DNS, TLS, dropped mid-handshake) and a
    /// server that doesn't know `?stream=1` are all "unsupported" — fall back
    /// rather than surfacing the turn as failed.
    ///
    /// Deviation from Flutter, which falls back on *every* non-2xx: a 409 means a
    /// turn is already running on this session and ``ChatStore`` attaches to it
    /// instead. Re-posting would either 409 again or start a duplicate turn.
    private static func canFallBack(from error: Error) -> Bool {
        if let apiError = error as? APIError {
            switch apiError {
            case .http(let status, _): return [404, 405, 500, 501, 502, 503].contains(status)
            case .badResponse: return true
            case .notPaired, .cancelled: return false
            }
        }
        if error is CancellationError { return false }
        return (error as NSError).domain == NSURLErrorDomain
    }

    /// A latch the `@Sendable` open callback can raise and the turn body can read.
    private final class CommitFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func raise() { lock.lock(); flag = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    }

    static func mimeType(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext), let mime = type.preferredMIMEType else {
            return "application/octet-stream"
        }
        return mime
    }
}

import Foundation

/// One session as `GET /api/session` describes it.
struct ChatSessionDetail: Equatable, Sendable {
    var id: String = ""
    var title: String = ""
    var messages: [ChatMessage] = []
    /// Set while a turn is running on this session — ours or another client's.
    var activeStreamID: String?
}

/// What the server knows about a session right now: whether a turn is running (and
/// on which stream) and the last assistant text.
///
/// The server's per-turn event queue is single-consumer, so the phone's live stream
/// can be starved when the web UI is open on the same session. This is the fallback
/// that both re-attaches to a running turn and recovers the text of one that
/// finished while we weren't listening.
struct SessionSnapshot: Equatable, Sendable {
    let activeStreamID: String?
    let lastAssistantText: String?
    let lastToolNames: [String]
}

/// `/api/sessions` wrapper, ported from `api/sessions.dart`. Mirrors the web UI's
/// session list shape so the native chat page can render the same list as the
/// desktop sidebar.
struct SessionsAPI {
    let api: JarvisAPI

    init(api: JarvisAPI = .shared) { self.api = api }

    func list(allProfiles: Bool = false) async throws -> [ChatSessionSummary] {
        let response = try await api.get("/api/sessions", query: allProfiles ? ["all_profiles": "1"] : [:])
        return try response.object().list("sessions").map { ChatSessionSummary(json: $0) }
    }

    func get(_ sessionID: String) async throws -> ChatSessionDetail {
        let response = try await api.get("/api/session", query: [
            "session_id": sessionID, "messages": "1", "resolve_model": "0",
        ])
        return Self.detail(from: try response.object(), fallbackID: sessionID)
    }

    /// Creates a session and returns its id. The caller defers this until the
    /// first message, matching the web UI's "an empty session writes nothing to
    /// disk" behaviour.
    func create(title: String? = nil, profile: String? = nil) async throws -> String {
        var body: [String: Any] = [:]
        if let title { body["title"] = title }
        if let profile { body["profile"] = profile }
        let object = try await api.post("/api/session/new", json: body).object()
        guard let id = Self.sessionID(in: object), !id.isEmpty else {
            throw APIError.badResponse("could not create a chat session")
        }
        return id
    }

    func rename(_ sessionID: String, title: String) async throws {
        _ = try await api.post("/api/session/rename", json: ["session_id": sessionID, "title": title])
    }

    func pin(_ sessionID: String, pinned: Bool) async throws {
        _ = try await api.post("/api/session/pin", json: ["session_id": sessionID, "pinned": pinned])
    }

    /// The server deletes via `POST /api/session/delete` (not the DELETE verb) with
    /// the id in the JSON body — matching the web UI client.
    func delete(_ sessionID: String) async throws {
        _ = try await api.post("/api/session/delete", json: ["session_id": sessionID])
    }

    /// Persist a turn handled on-device (no server agent) into the session
    /// transcript so it shows on the web and other devices. Best-effort.
    func appendLocalTurn(_ sessionID: String, user: String, assistant: String) async {
        guard !assistant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        _ = try? await api.post("/api/session/append", json: [
            "session_id": sessionID, "user": user, "assistant": assistant, "on_device": true,
        ])
    }

    func snapshot(_ sessionID: String) async throws -> SessionSnapshot {
        let object = try await api.get("/api/session", query: ["session_id": sessionID]).object()
        let session = object.dict("session") ?? object
        let active = session.string("active_stream_id").flatMap { $0.isEmpty ? nil : $0 }
        var lastText: String?
        var tools: [String] = []
        for record in (session["messages"] as? [[String: Any]] ?? []).reversed() {
            guard record.string("role") == "assistant" else {
                if lastText == nil { continue } else { break }
            }
            if let calls = record["tool_calls"] as? [[String: Any]] {
                tools = calls.compactMap { $0.dict("function")?.string("name") ?? $0.string("name") } + tools
            }
            if lastText == nil {
                if let content = record["content"] as? String,
                   !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lastText = content
                } else if let parts = record["content"] as? [[String: Any]] {
                    let text = parts.compactMap { $0.string("text") }.joined()
                    if !text.isEmpty { lastText = text }
                }
                // A tool-call-only assistant record: keep walking back.
                if lastText == nil { continue }
            } else {
                break
            }
        }
        return SessionSnapshot(activeStreamID: active, lastAssistantText: lastText, lastToolNames: tools)
    }

    // MARK: Parsing

    /// `GET /api/session` sometimes wraps the session and sometimes doesn't.
    static func detail(from object: [String: Any], fallbackID: String = "") -> ChatSessionDetail {
        let session = object.dict("session") ?? object
        let active = session.string("active_stream_id").flatMap { $0.isEmpty ? nil : $0 }
        return ChatSessionDetail(
            id: sessionID(in: session) ?? fallbackID,
            title: (session.string("title") ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            messages: ChatHistory.hydrate(session["messages"] as? [[String: Any]] ?? []),
            activeStreamID: active)
    }

    private static func sessionID(in object: [String: Any]) -> String? {
        if let id = object.string("session_id"), !id.isEmpty { return id }
        if let inner = object.dict("session") {
            if let id = inner.string("session_id"), !id.isEmpty { return id }
            if let id = inner.string("id"), !id.isEmpty { return id }
        }
        if let id = object.string("id"), !id.isEmpty { return id }
        return nil
    }
}

import Foundation

/// Read-only mirror of the web "Todos" panel. There is no todos endpoint: the
/// list is derived from the active session's message history, so this wrapper
/// resolves the session then scans its messages.
struct TodosAPI {
    let api: JarvisAPI

    init(api: JarvisAPI = .shared) { self.api = api }

    /// The active session's current todo list, or `[]`.
    func currentSession() async throws -> [TodoItem] {
        guard let id = try await activeSessionID(), !id.isEmpty else { return [] }
        let messages = try await sessionMessages(id)
        return TodosParser.extractTodos(messages)
    }

    /// The most-recently-updated session's id — the mobile app has no app-level
    /// "active session" singleton, so we mirror what the user sees as their open
    /// chat (`ChatController.openInitial`: sort by `updated_at` desc, take first).
    func activeSessionID() async throws -> String? {
        let response = try await api.get("/api/sessions")
        let body = try response.object()
        let raw = (body["sessions"] as? [Any]) ?? []
        var rows = MoreJSON.mapList(raw)
        guard !rows.isEmpty else { return nil }
        rows.sort { updated($0) > updated($1) }
        for row in rows {
            let id = MoreJSON.text(row["session_id"] ?? row["id"])
            if !id.isEmpty { return id }
        }
        return nil
    }

    /// `GET /api/session?session_id=…&messages=1` → `{session: {…, messages: []}}`;
    /// a bare `messages` key is tolerated.
    func sessionMessages(_ sessionID: String) async throws -> [Any] {
        let response = try await api.get("/api/session", query: [
            "session_id": sessionID,
            "messages": "1",
            "resolve_model": "0",
        ])
        let body = try response.object()
        let session = (body["session"] as? JSONObject) ?? body
        return (session["messages"] as? [Any]) ?? []
    }

    private func updated(_ row: JSONObject) -> Int {
        MoreJSON.int(row["updated_at"] ?? row["last_message_at"])
    }
}

import Foundation

/// REST for More → Notes (`/api/agent-notes/*`, served by
/// `webui/api/agent_notes_routes.py`). The Mac uploads the notes; the phone reads
/// them, ticks to-dos, asks for a new summary or deletes one.
struct NotesAPI {
    let api: JarvisAPI

    init(api: JarvisAPI = .shared) { self.api = api }

    /// `GET /api/agent-notes` → newest first, without transcripts.
    func list() async throws -> [AgentNote] {
        let body = try await api.get("/api/agent-notes").object()
        return CodingJSON.maps(body["notes"]).compactMap(AgentNote.init(json:))
    }

    /// `GET /api/agent-notes/<id>` → the whole note.
    func note(_ id: String) async throws -> AgentNote {
        guard let note = AgentNote(json: try await api.get("/api/agent-notes/\(id)").object()) else {
            throw APIError.badResponse("not a note")
        }
        return note
    }

    /// `GET /api/agent-notes/<id>/markdown?tz=` — dates in the viewer's time zone
    /// (`tz` the JavaScript way: minutes west of UTC).
    func markdown(_ id: String, timeZone: TimeZone = .current) async throws -> (text: String, filename: String) {
        let tz = -timeZone.secondsFromGMT() / 60
        let body = try await api.get("/api/agent-notes/\(id)/markdown", query: ["tz": "\(tz)"]).object()
        return (CodingJSON.text(body["markdown"]), CodingJSON.text(body["filename"], "Notes.md"))
    }

    /// `POST /api/agent-notes/<id> {todos}`.
    func setTodos(_ id: String, _ todos: [[String: Any]]) async throws -> AgentNote {
        try reply(try await api.post("/api/agent-notes/\(id)", json: ["todos": todos]).object())
    }

    /// `POST /api/agent-notes/<id>/summarize` — the server writes it in the background.
    func summarize(_ id: String) async throws -> AgentNote {
        try reply(try await api.post("/api/agent-notes/\(id)/summarize").object())
    }

    /// `DELETE /api/agent-notes/<id>`.
    func delete(_ id: String) async throws {
        _ = try await api.delete("/api/agent-notes/\(id)")
    }

    private func reply(_ body: [String: Any]) throws -> AgentNote {
        guard let note = AgentNote(json: CodingJSON.dict(body["note"]) ?? [:]) else {
            throw APIError.badResponse("not a note")
        }
        return note
    }
}

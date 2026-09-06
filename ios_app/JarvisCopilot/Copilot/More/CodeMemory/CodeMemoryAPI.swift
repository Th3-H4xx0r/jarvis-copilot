import Foundation

/// Client for the shared code-memory store — the per-project code knowledge and
/// session handoffs Claude / the JarvisCopilot agent write while working in a
/// repo. Mirrors the web "Code memory" panel.
///
/// Endpoint shapes verified against `webui/api/routes.py` + `agent/code_memory.py`:
///   GET  /api/code-memory/stats    → flat {projects, knowledge, sessions,
///                                    by_type, last_activity}
///   GET  /api/code-memory/projects → {projects: {slug: {...}}} — a MAP by slug
///   GET  /api/code-memory          → {slug, kind, entries:[{id, ts, entry_type,
///                                    content}]}; id is `slug::kind::ts::ordinal`
///   GET  /api/code-memory/search   → compact rows carrying `first_line`, no body
///   POST /api/code-memory/update       {id, content, entry_type?}
///   POST /api/code-memory/delete-entry {id} (preferred) or {slug, kind, ts}
struct CodeMemoryAPI {
    let api: JarvisAPI

    init(api: JarvisAPI = .shared) { self.api = api }

    func stats() async throws -> CodeMemoryStats {
        CodeMemoryStats(json: try await api.get("/api/code-memory/stats").object())
    }

    func projects() async throws -> [CodeMemoryProject] {
        let body = try await api.get("/api/code-memory/projects").object()
        return CodeMemoryParse.projects(body["projects"] ?? MoreJSON.envelopeList(body, "projects"))
    }

    func entries(_ slug: String,
                 kind: CodeMemoryKind = .knowledge,
                 limit: Int = 500) async throws -> [CodeMemoryEntry] {
        let response = try await api.get("/api/code-memory", query: [
            "project": slug, "kind": kind.rawValue, "limit": "\(limit)",
        ])
        return CodeMemoryParse.entries(try response.object())
    }

    /// Server-side search. Returns COMPACT rows (no full `content`); callers that
    /// need the body hydrate via `byIDs` — the row's `id` is stable.
    func search(_ slug: String, query: String,
                kind: CodeMemoryKind = .knowledge,
                limit: Int = 100) async throws -> [CodeMemoryEntry] {
        let response = try await api.get("/api/code-memory/search", query: [
            "project": slug, "kind": kind.rawValue, "q": query, "limit": "\(limit)",
        ])
        return CodeMemoryParse.entries(try response.object())
    }

    /// Full bodies for the given entry ids, to hydrate compact search rows.
    func byIDs(_ ids: [String]) async throws -> [CodeMemoryEntry] {
        guard !ids.isEmpty else { return [] }
        let response = try await api.get("/api/code-memory/entries",
                                         query: ["ids": ids.joined(separator: ",")])
        return CodeMemoryParse.entries(try response.object())
    }

    /// Edit one entry in place by id, preserving its timestamp/position.
    func update(id: String, content: String, entryType: String? = nil) async throws {
        var body: JSONObject = ["id": id, "content": content]
        if let entryType { body["entry_type"] = entryType }
        _ = try await api.post("/api/code-memory/update", json: body)
    }

    /// Delete a single entry. Prefer the precise `id` form; fall back to
    /// (slug, kind, ts) when no id is available.
    func deleteEntry(id: String) async throws {
        _ = try await api.post("/api/code-memory/delete-entry", json: ["id": id])
    }

    func deleteEntry(slug: String, kind: String, ts: String) async throws {
        _ = try await api.post("/api/code-memory/delete-entry",
                               json: ["slug": slug, "kind": kind, "ts": ts])
    }
}

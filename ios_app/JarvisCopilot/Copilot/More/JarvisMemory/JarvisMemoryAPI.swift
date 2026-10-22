import Foundation

/// Talks to `/api/jarvis-memory/*` — the semantic long-term store behind the web
/// "Long-term memory" panel.
///
/// Shapes come from the real backend (`_handle_jarvis_memory_*` +
/// `jarvis_memory.js`) and every endpoint may fail-soft to
/// `{available:false, error:…}`, so nothing here assumes a key exists.
///
/// Quirks worth keeping (do NOT rename to the obvious thing):
///   * search returns `entries` (NOT `results`); an entry's text is `body`;
///     `id` is a string.
///   * reflections rows are full sqlite rows whose `id` is an INTEGER.
///   * delete / dismiss both POST `{id: …}` — the server does `require(body,"id")`.
///   * reflections/run POSTs an empty body.
struct JarvisMemoryAPI {
    let api: JarvisAPI

    init(api: JarvisAPI = .shared) { self.api = api }

    /// `{available, count, namespaces:[{namespace,count}]}`.
    func stats() async throws -> JSONObject {
        try await api.get("/api/jarvis-memory/stats").object()
    }

    /// `{available, embed_model, embed_dim, extract_model, ollama_running, …}`.
    func status() async throws -> JSONObject {
        try await api.get("/api/jarvis-memory/status").object()
    }

    func search(_ query: String) async throws -> [MemoryEntry] {
        let response = try await api.get("/api/jarvis-memory/search", query: ["q": query])
        return JarvisMemoryParse.entries(try response.object())
    }

    func reflections() async throws -> [MemoryReflection] {
        let response = try await api.get("/api/jarvis-memory/reflections")
        return JarvisMemoryParse.reflections(try response.object())
    }

    /// Forget one memory entry. Entry ids are strings.
    func deleteEntry(_ id: String) async throws {
        _ = try await api.post("/api/jarvis-memory/delete", json: ["id": id])
    }

    /// Dismiss one insight. Reflection ids are integers, so a numeric string is
    /// coerced (the web UI sends `Number(id)`).
    func dismissReflection(_ id: String) async throws {
        let numeric: Any = Int(id) ?? id
        _ = try await api.post("/api/jarvis-memory/reflections/dismiss", json: ["id": numeric])
    }

    /// Kick a reflection tick. The server answers `{ok, new}`; we don't surface it.
    func runReflections() async throws {
        _ = try await api.post("/api/jarvis-memory/reflections/run", json: JSONObject())
    }

    // MARK: Memory map

    func mapSettings() async throws -> MemoryMapSettings {
        try JSONDecoder().decode(MemoryMapSettings.self,
                                 from: try await api.get("/api/jarvis-memory/map-settings").data)
    }

    /// nil = Same as Default. Answers with the saved settings.
    func setMapAgent(_ choice: AgentChoice?) async throws -> MemoryMapSettings {
        let response = try await api.post("/api/jarvis-memory/map-settings",
                                          json: ["agent": IMessageMemoryAgent(choice).json])
        return try JSONDecoder().decode(MemoryMapSettings.self, from: response.data)
    }

    func cleanupStatus() async throws -> MemoryCleanupStatus {
        MemoryCleanupStatus(json: try await api.get("/api/jarvis-memory/cleanup/status").object())
    }

    /// One run at a time: `started` is false when one is already going.
    func startCleanup() async throws {
        _ = try await api.post("/api/jarvis-memory/cleanup/start", json: JSONObject())
    }

    /// Unhide memories the cleanup merged or hid.
    func restore(_ ids: [String]) async throws {
        _ = try await api.post("/api/jarvis-memory/cleanup/restore", json: ["ids": ids])
    }

    /// Ask a running cleanup to stop; the status then reads `stopping` until it has.
    func stopCleanup() async throws {
        _ = try await api.post("/api/jarvis-memory/cleanup/stop", json: JSONObject())
    }

    // MARK: Memory graph (the map screen)

    /// `center` is "me" or an entity id; the filters become types/since/source.
    func graph(center: String, filters: MemoryGraphFilters, now: Date = Date()) async throws -> MemoryGraphPayload {
        let response = try await api.get("/api/jarvis-memory/graph", query: filters.query(center: center, now: now))
        return MemoryGraphPayload(json: try response.object())
    }

    /// The You view lit up on what one recall used.
    func highlight(recallID: String) async throws -> MemoryGraphPayload {
        let response = try await api.get("/api/jarvis-memory/graph/highlight", query: ["recall": recallID])
        return MemoryGraphPayload(json: try response.object())
    }

    func entity(_ id: String, limit: Int = 50) async throws -> MemoryEntityDetail {
        let response = try await api.get("/api/jarvis-memory/entity", query: ["id": id, "limit": String(limit)])
        return MemoryEntityDetail(json: try response.object())
    }

    /// Only what is passed is sent. A rename onto another entity's name merges
    /// into it, and the answer is then the survivor (a different id).
    func updateEntity(_ id: String, label: String? = nil, aliases: [String]? = nil,
                      pinned: Bool? = nil) async throws -> MemoryEntity {
        var body: JSONObject = ["id": id]
        if let label { body["label"] = label }
        if let aliases { body["aliases"] = aliases }
        if let pinned { body["pinned"] = pinned }
        let response = try await api.post("/api/jarvis-memory/entity", json: body)
        return MemoryEntity(json: MoreJSON.map(try response.object()["entity"]))
    }

    /// `from` is deleted on the server; the answer is `into` after the merge.
    func mergeEntity(from: String, into: String) async throws -> MemoryEntity {
        let response = try await api.post("/api/jarvis-memory/entity/merge", json: ["from": from, "into": into])
        return MemoryEntity(json: MoreJSON.map(try response.object()["entity"]))
    }

    func unlink(memoryID: String, entityID: String) async throws {
        _ = try await api.post("/api/jarvis-memory/entity/unlink",
                               json: ["memory_id": memoryID, "entity_id": entityID])
    }

    /// Newest first; `sessionID` narrows to one chat.
    func recalls(limit: Int = 30, sessionID: String? = nil) async throws -> [MemoryRecall] {
        var query = ["limit": String(limit)]
        if let sessionID { query["session_id"] = sessionID }
        let response = try await api.get("/api/jarvis-memory/recalls", query: query)
        return MemoryRecall.list(try response.object())
    }
}

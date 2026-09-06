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
    /// coerced (the web UI sends `Number(id)`). `reflection_id` rides along for
    /// forward-compat but `id` is the key the backend reads.
    func dismissReflection(_ id: String) async throws {
        let numeric: Any = Int(id) ?? id
        _ = try await api.post("/api/jarvis-memory/reflections/dismiss",
                               json: ["id": numeric, "reflection_id": numeric])
    }

    /// Kick a reflection tick. The server answers `{ok, new}`; we don't surface it.
    func runReflections() async throws {
        _ = try await api.post("/api/jarvis-memory/reflections/run", json: JSONObject())
    }
}

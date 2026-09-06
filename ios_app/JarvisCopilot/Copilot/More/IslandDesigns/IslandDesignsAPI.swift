import Foundation

/// REST wrapper for the Dynamic Island Designs API (`/api/island/*`).
///
/// The webui HTTP server has no PUT, so selection/rules use POST and deletes use
/// DELETE (with a POST `/delete` alias available server-side).
struct IslandDesignsAPI {
    let api: JarvisAPI

    init(api: JarvisAPI = .shared) { self.api = api }

    /// `GET /api/island/designs` → `{designs, catalog, selection, data}`.
    /// The bundled demo is merged client-side so an app rebuild always shows the
    /// latest "UI Example (max size)" even when hermes is behind.
    func catalog() async throws -> IslandCatalog {
        var body = try await api.get("/api/island/designs").object()
        IslandDemo.injectBundledDemo(&body)
        return IslandCatalog(json: body)
    }

    /// Create or update a design (the server validates the tree).
    func upsert(_ design: JSONObject) async throws {
        _ = try await api.post("/api/island/designs", json: design)
    }

    func deleteDesign(_ id: String) async throws {
        _ = try await api.delete("/api/island/designs/\(id)")
    }

    /// `{mode, pinnedId?}` — mode is "auto" or "pinned".
    func setSelection(_ mode: String, pinnedID: String? = nil) async throws {
        var body: JSONObject = ["mode": mode]
        if let pinnedID { body["pinnedId"] = pinnedID }
        _ = try await api.post("/api/island/selection", json: body)
    }

    /// `{enabled?, priority?, conditions?, schedule?}` — only the keys given.
    func setRules(_ id: String,
                  enabled: Bool? = nil,
                  priority: Int? = nil,
                  conditions: JSONObject? = nil,
                  schedule: JSONObject? = nil) async throws {
        var body = JSONObject()
        if let enabled { body["enabled"] = enabled }
        if let priority { body["priority"] = priority }
        if let conditions { body["conditions"] = conditions }
        if let schedule { body["schedule"] = schedule }
        _ = try await api.post("/api/island/designs/\(id)/rules", json: body)
    }

    /// Push resolved values for one design.
    func setData(_ id: String, data: JSONObject) async throws {
        _ = try await api.post("/api/island/designs/\(id)/data", json: data)
    }
}

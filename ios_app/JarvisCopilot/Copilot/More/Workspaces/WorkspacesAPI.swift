import Foundation

/// Talks to the server's workspace endpoints (the same ones the web Workspaces
/// panel drives). Workspaces are an ordered list of absolute paths, each with a
/// friendly name; one may be flagged "last used".
struct WorkspacesAPI {
    let api: JarvisAPI

    init(api: JarvisAPI = .shared) { self.api = api }

    /// `GET /api/workspaces` → `{workspaces: [...], last: "..."}`.
    func list() async throws -> WorkspaceList {
        parseWorkspaceList(try await api.get("/api/workspaces").object())
    }

    /// `GET /api/workspaces/suggest?prefix=…` → candidate path strings.
    func suggest(_ prefix: String) async throws -> [String] {
        let body = try await api.get("/api/workspaces/suggest", query: ["prefix": prefix]).object()
        guard let raw = body["suggestions"] as? [Any] else { return [] }
        return raw.map { MoreJSON.text($0) }
    }

    /// Adds (and, server-side, creates if needed) the workspace at `path`.
    func add(_ path: String) async throws {
        _ = try await api.post("/api/workspaces/add", json: ["path": path])
    }

    func remove(_ path: String) async throws {
        _ = try await api.post("/api/workspaces/remove", json: ["path": path])
    }

    /// Renames the friendly display name. The path is the identity and is fixed.
    func rename(_ path: String, name: String) async throws {
        _ = try await api.post("/api/workspaces/rename", json: ["path": path, "name": name])
    }

    /// Rewrites the workspace order to match the given ordered path list.
    func reorder(_ paths: [String]) async throws {
        _ = try await api.post("/api/workspaces/reorder", json: ["paths": paths])
    }
}

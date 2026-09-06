import Foundation

/// Fetches recent self-improvement / self-learning events — skills auto-created
/// or patched, memory updated, and rejected attempts — from
/// `GET /api/self-improvement/recent`, which parses the server's
/// `self_improvement.log`.
///
/// The endpoint returns `{entries: […], total, hint}`; a bare list is tolerated.
struct SelfImprovementAPI {
    let api: JarvisAPI

    init(api: JarvisAPI = .shared) { self.api = api }

    func recent(limit: Int = 100) async throws -> [SelfImprovementEvent] {
        let response = try await api.get("/api/self-improvement/recent",
                                         query: ["limit": "\(limit)"])
        let rows = MoreJSON.mapList(MoreJSON.envelopeList(try response.object(), "entries"))
        return rows.enumerated().map { SelfImprovementEvent(json: $0.element, index: $0.offset) }
    }
}

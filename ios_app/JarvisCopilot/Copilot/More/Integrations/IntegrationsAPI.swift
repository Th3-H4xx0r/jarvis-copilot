import Foundation

/// Client for the Integrations API — the same endpoints the web panel reads.
/// The phone never opens the registry database; everything comes through here.
struct IntegrationsAPI {
    let api: JarvisAPI

    init(api: JarvisAPI = .shared) { self.api = api }

    /// `GET /api/integrations` → `{integrations: [...]}`.
    func list() async throws -> [Integration] {
        let body = try await api.get("/api/integrations").object()
        return MoreJSON.mapList(MoreJSON.envelopeList(body, "integrations")).map(Integration.init(json:))
    }

    /// `GET /api/integrations/<id>` → the space plus its data, skills and schedules.
    func detail(_ id: String) async throws -> IntegrationDetail {
        IntegrationDetail(json: try await api.get("/api/integrations/\(escaped(id))").object())
    }

    /// `GET /api/integrations/<id>/records?collection=…` → newest first.
    func records(_ id: String, collection: String, limit: Int = 100) async throws -> [IntegrationRecord] {
        let response = try await api.get("/api/integrations/\(escaped(id))/records",
                                         query: ["collection": collection, "limit": "\(limit)"])
        let rows = MoreJSON.mapList(MoreJSON.envelopeList(try response.object(), "records"))
        return rows.enumerated().map { IntegrationRecord(json: $0.element, index: $0.offset) }
    }

    /// One stored document, pretty-printed for reading.
    func document(_ id: String, key: String) async throws -> String {
        let body = try await api.get("/api/integrations/\(escaped(id))/documents/\(escaped(key))").object()
        guard let value = body["body"], !(value is NSNull) else { return "" }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value,
                                                     options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return MoreJSON.text(value)
        }
        return text
    }

    func create(name: String) async throws -> Integration {
        Integration(json: try await api.post("/api/integrations", json: ["name": name]).object())
    }

    func setStatus(_ id: String, status: String) async throws {
        _ = try await api.post("/api/integrations/\(escaped(id))/status", json: ["status": status])
    }

    /// Removes the integration, its schedules and everything it stored.
    func delete(_ id: String) async throws {
        _ = try await api.delete("/api/integrations/\(escaped(id))")
    }

    // MARK: Plans

    func plan(_ planID: String) async throws -> IntegrationPlan {
        IntegrationPlan(json: try await api.get("/api/integrations/plans/\(escaped(planID))").object())
    }

    /// Creates everything the plan card listed. Until this, nothing exists.
    func approvePlan(_ planID: String) async throws {
        _ = try await api.post("/api/integrations/plans/\(escaped(planID))/approve")
    }

    func cancelPlan(_ planID: String) async throws {
        _ = try await api.post("/api/integrations/plans/\(escaped(planID))/cancel")
    }

    private func escaped(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }
}

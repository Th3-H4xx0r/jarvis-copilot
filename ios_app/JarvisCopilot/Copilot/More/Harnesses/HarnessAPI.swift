import Foundation

/// REST wrapper for the agent-harness API (`/api/harnesses*`, `/api/session/harness`).
///
/// The webui server has no PUT: saves are POST and deletes use the POST
/// `/delete` alias. A save the server rejects comes back as 400 with
/// `{errors:[{node, edge, message}]}` — read straight off the transport so the
/// editor can draw each problem on its node.
struct HarnessAPI {
    let api: JarvisAPI

    init(api: JarvisAPI = .shared) { self.api = api }

    func snapshot() async throws -> HarnessSnapshot {
        let data = try await api.get("/api/harnesses").data
        return try JSONDecoder().decode(HarnessSnapshot.self, from: data)
    }

    /// `.success(saved)` or `.failure(problems)` for a design the server rejected.
    func save(_ harness: AgentHarness) async throws -> Result<AgentHarness, HarnessSaveRejection> {
        var draft = harness
        draft.problems = nil
        draft.builtin = nil
        let design = try JSONSerialization.jsonObject(with: JSONEncoder().encode(draft))
        let body = try JSONSerialization.data(withJSONObject: ["design": design])
        let req = try api.request("POST", "/api/harnesses/designs",
                                  headers: ["Content-Type": "application/json"], body: body)
        let (data, http) = try await api.transport.send(req)
        if (200..<300).contains(http.statusCode) {
            struct Saved: Decodable { let design: AgentHarness }
            return .success(try JSONDecoder().decode(Saved.self, from: data).design)
        }
        struct Rejected: Decodable { let errors: [HarnessProblem]? }
        if let errors = (try? JSONDecoder().decode(Rejected.self, from: data))?.errors, !errors.isEmpty {
            return .failure(HarnessSaveRejection(problems: errors))
        }
        throw APIError.http(status: http.statusCode,
                            message: APIError.message(status: http.statusCode, body: data))
    }

    func delete(id: String) async throws {
        _ = try await api.post("/api/harnesses/designs/\(id)/delete")
    }

    /// Set the Voice or Chat default harness; returns the new assignments.
    func assign(surface: String, id: String) async throws -> [String: String] {
        let obj = try await api.post("/api/harnesses/assign",
                                     json: ["surface": surface, "harness_id": id]).object()
        return (obj["assignments"] as? [String: String]) ?? [:]
    }

    /// A chat's own harness (`nil` = follow the Chat default).
    func setSessionHarness(sessionID: String, id: String?) async throws {
        let body: [String: Any] = ["session_id": sessionID, "harness_id": (id as Any?) ?? NSNull()]
        _ = try await api.post("/api/session/harness", json: body)
    }
}

struct HarnessSaveRejection: Error, Hashable {
    let problems: [HarnessProblem]
}

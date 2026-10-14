import Foundation

/// REST for the Agents tab: hook-tracked sessions of every coding agent
/// (`/api/coding/agents/*`) and the approval / question endpoints they share
/// with the Coding tab (`/api/coding/permission/*`).
struct AgentsAPI {
    let api: JarvisAPI

    init(api: JarvisAPI = .shared) { self.api = api }

    struct Overview {
        let sessions: [AgentSessionItem]
        let requests: [AgentRequest]
        let usage: AgentPlanUsage?
    }

    /// `GET /api/coding/agents/sessions` → `{sessions, pending, usage}`.
    func overview() async throws -> Overview {
        let body = try await api.get("/api/coding/agents/sessions").object()
        return Overview(sessions: CodingJSON.maps(body["sessions"]).map(AgentSessionItem.init(json:)),
                        requests: ((body["pending"] as? [Any]) ?? []).compactMap(AgentRequest.from),
                        usage: AgentPlanUsage(json: CodingJSON.dict(body["usage"])))
    }

    /// `GET /api/coding/agents/session?key=` → `{session}` with its last turn.
    func session(key: String) async throws -> AgentSessionDetail {
        let body = try await api.get("/api/coding/agents/session", query: ["key": key]).object()
        guard let session = CodingJSON.dict(body["session"]) else {
            throw CodingServerError(message: "That session is gone.")
        }
        return AgentSessionDetail(json: session)
    }

    /// `POST /api/coding/permission/verdict` — the decision goes back to the exact
    /// waiting hook (the server routes it by the request's fingerprint).
    func verdict(requestId: String, decision: String, message: String? = nil,
                 answers: [String: Any]? = nil) async throws -> Bool {
        var body: [String: Any] = ["request_id": requestId, "decision": decision]
        if let message, !message.isEmpty { body["message"] = message }
        if let answers { body["answers"] = answers }
        let reply = try await api.post("/api/coding/permission/verdict", json: body).object()
        return CodingJSON.bool(reply["ok"])
    }

    /// `POST /api/coding/agents/decide` — the same, keyed by the request's
    /// fingerprint (what the Live Activity's Allow / Deny buttons carry).
    func decide(fingerprint: String, decision: String) async throws -> Bool {
        let reply = try await api.post("/api/coding/agents/decide",
                                       json: ["fingerprint": fingerprint, "decision": decision]).object()
        return CodingJSON.bool(reply["ok"])
    }

    /// `POST /api/coding/agents/instruction` → "terminal" (typed into tmux) or
    /// "resume" (the Mac continues the conversation in the background).
    func sendInstruction(key: String, text: String) async throws -> String {
        let reply = try await api.post("/api/coding/agents/instruction",
                                       json: ["key": key, "text": text]).object()
        if let error = CodingJSON.str(reply["error"]) { throw CodingServerError(message: error) }
        return CodingJSON.text(reply["via"])
    }
}

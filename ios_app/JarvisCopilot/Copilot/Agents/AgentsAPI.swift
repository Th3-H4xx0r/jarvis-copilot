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
        var codexUsage: AgentPlanUsage? = nil
    }

    /// `GET /api/coding/agents/sessions` → `{sessions, pending, usage, usage_codex}`.
    func overview() async throws -> Overview {
        let body = try await api.get("/api/coding/agents/sessions").object()
        return Overview(sessions: CodingJSON.maps(body["sessions"]).map(AgentSessionItem.init(json:)),
                        requests: ((body["pending"] as? [Any]) ?? []).compactMap(AgentRequest.from),
                        usage: AgentPlanUsage(json: CodingJSON.dict(body["usage"])),
                        codexUsage: AgentPlanUsage(json: CodingJSON.dict(body["usage_codex"])))
    }

    /// `GET /api/coding/agents/recap?days=&tz=` — the week's numbers, with days
    /// split in this phone's timezone (minutes east of UTC).
    func recap(days: Int = 7, timeZone: TimeZone = .current) async throws -> AgentRecap {
        let tz = timeZone.secondsFromGMT() / 60
        return AgentRecap(json: try await api.get("/api/coding/agents/recap",
                                                  query: ["days": "\(days)", "tz": "\(tz)"]).object())
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

    struct TurnRecord: Identifiable, Equatable {
        let id: Int
        let agent: String
        let project: String
        let startedAt: Date
        let endedAt: Date
        let files: Int
        let added: Int
        let removed: Int
        let commands: Int
        let outcome: String
    }

    /// `GET /api/coding/agents/history` → the last week's finished turns, newest first.
    func history() async throws -> [TurnRecord] {
        let body = try await api.get("/api/coding/agents/history").object()
        return CodingJSON.maps(body["turns"]).map { t in
            TurnRecord(id: CodingJSON.int(t["id"]), agent: AgentNames.display(CodingJSON.text(t["agent"])),
                       project: CodingJSON.text(t["project"], "session"),
                       startedAt: Date(timeIntervalSince1970: CodingJSON.double(t["started_at"]) ?? 0),
                       endedAt: Date(timeIntervalSince1970: CodingJSON.double(t["ended_at"]) ?? 0),
                       files: CodingJSON.int(t["files"]), added: CodingJSON.int(t["added"]),
                       removed: CodingJSON.int(t["removed"]), commands: CodingJSON.int(t["commands"]),
                       outcome: CodingJSON.text(t["outcome"]))
        }
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

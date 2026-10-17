import Foundation

/// REST for the Agents tab: the merged conversation list and its actions
/// (`/api/coding/agents/list`, `/messages`, `/send`, `/continue`, …), the
/// hook-tracked sessions Siri, the widget and the Live Activity read
/// (`/api/coding/agents/sessions`), and the approval / question endpoints
/// (`/api/coding/permission/*`).
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

    // MARK: - The merged list (webui/api/agents_core.py)

    /// `GET /api/coding/agents/list` → `{card, needs_you, projects, usage, usage_codex, ts}`.
    func list() async throws -> AgentsList {
        AgentsList(json: try await api.get("/api/coding/agents/list").object())
    }

    /// `GET /api/coding/agents/messages?ckey=&after=&before=&limit=` — a page of
    /// the server's transcript copy, the same shape the reducer folds in.
    func messages(ckey: String, after: Int = 0, before: Int? = nil, limit: Int? = nil,
                  lite: Bool = true) async throws -> CodingChatPage {
        var query = ["ckey": ckey, "after": "\(after)"]
        if let before { query["before"] = "\(before)" }
        if let limit { query["limit"] = "\(limit)" }
        if !lite { query["lite"] = "0" }
        return CodingChatPage(json: try await api.get("/api/coding/agents/messages", query: query).object())
    }

    /// `POST /api/coding/agents/send {ckey, text, now?}` → `{delivery}` — 200 when
    /// it went (sent / queued / delivered), 409 with the reason when it didn't.
    /// While the agent works a message joins its own queue; `now` sends it
    /// straight in (the terminal's Ctrl+Enter).
    /// Read by hand: the 409's body is the answer, not an error to throw.
    func send(ckey: String, text: String, now: Bool = false) async throws -> AgentDelivery {
        var body: [String: Any] = ["ckey": ckey, "text": text]
        if now { body["now"] = true }
        let req = try api.request("POST", "/api/coding/agents/send",
                                  headers: ["Content-Type": "application/json"],
                                  body: try JSONSerialization.data(withJSONObject: body))
        let (data, http) = try await api.transport.send(req)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let delivery = CodingJSON.dict(obj["delivery"]) { return AgentDelivery(json: delivery) }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(status: http.statusCode,
                                message: APIError.message(status: http.statusCode, body: data))
        }
        throw APIError.badResponse("no delivery in the reply")
    }

    /// `POST /api/coding/agents/continue {ckeys, to, confirm_offline?}` →
    /// `{results: {ckey: {ok, reason?, error?}}}`.
    func continueSessions(_ ckeys: [String], to: String, confirmOffline: Bool = false) async throws
        -> [String: AgentContinueResult] {
        var body: [String: Any] = ["ckeys": ckeys, "to": to]
        if confirmOffline { body["confirm_offline"] = true }
        let reply = try await api.post("/api/coding/agents/continue", json: body).object()
        var out: [String: AgentContinueResult] = [:]
        for (k, v) in CodingJSON.dict(reply["results"]) ?? [:] {
            out[k] = AgentContinueResult(json: CodingJSON.dict(v) ?? [:])
        }
        return out
    }

    /// `POST /api/coding/agents/stop {ckey}` — a 409 says why it couldn't.
    func stop(ckey: String) async throws {
        _ = try await api.post("/api/coding/agents/stop", json: ["ckey": ckey])
    }

    /// `POST /api/coding/agents/resume {ckey, where}` — an ended session, again.
    func resume(ckey: String, where place: String) async throws {
        _ = try await api.post("/api/coding/agents/resume", json: ["ckey": ckey, "where": place])
    }

    /// `POST /api/coding/agents/launch {cwd, where, agent, model?, permission_mode?, prompt?}`.
    func launch(cwd: String, where place: String, agent: String, model: String? = nil,
                permissionMode: String? = nil, prompt: String? = nil) async throws {
        var body: [String: Any] = ["cwd": cwd, "where": place, "agent": agent]
        if let model, !model.isEmpty { body["model"] = model }
        if let permissionMode, !permissionMode.isEmpty { body["permission_mode"] = permissionMode }
        if let prompt, !prompt.isEmpty { body["prompt"] = prompt }
        _ = try await api.post("/api/coding/agents/launch", json: body)
    }

    /// `POST /api/coding/agents/card/dismiss {device_id, ckeys?}` — hide the
    /// Mac-asleep card (or some of its rows).
    func dismissCard(deviceId: String, ckeys: [String]? = nil) async throws {
        var body: [String: Any] = ["device_id": deviceId]
        if let ckeys { body["ckeys"] = ckeys }
        _ = try await api.post("/api/coding/agents/card/dismiss", json: body)
    }

    /// `POST /api/coding/agents/terminal/start {ckey, rows, cols}` → `{terminal_id}`
    /// for the shared `/api/terminal/*` endpoints.
    func terminalStart(ckey: String, rows: Int, cols: Int) async throws -> String {
        let reply = try await api.post("/api/coding/agents/terminal/start",
                                       json: ["ckey": ckey, "rows": rows, "cols": cols]).object()
        guard let id = CodingJSON.str(reply["terminal_id"]) else {
            throw CodingServerError(message: "The server didn’t open a terminal.")
        }
        return id
    }

    /// `POST /api/terminal/input {session_id, data}` — the key bar's keys.
    func terminalInput(_ terminalId: String, data: String) async throws {
        _ = try await api.post("/api/terminal/input", json: ["session_id": terminalId, "data": data])
    }

    /// `POST /api/terminal/close {session_id}` — detach (the session keeps running).
    func terminalClose(_ terminalId: String) async {
        do {
            _ = try await api.post("/api/terminal/close", json: ["session_id": terminalId])
        } catch {
            JcLog.dropped(JcLog.coding, "agents terminal close", error)
        }
    }

    /// `GET /api/coding/permission/pending` → the approvals and questions
    /// waiting on a verdict (each with the request id the cards answer).
    func pending() async throws -> [AgentRequest] {
        let body = try await api.get("/api/coding/permission/pending").object()
        return ((body["pending"] as? [Any]) ?? []).compactMap(AgentRequest.from)
    }

    // MARK: - Projects and launching

    /// `GET /api/coding/projects` → one project's settings.
    func project(_ id: String) async throws -> CodingProject? {
        let body = try await api.get("/api/coding/projects").object()
        return CodingJSON.maps(body["projects"]).map(CodingProject.init(json:)).first { $0.id == id }
    }

    /// `POST /api/coding/project/{id}` — the name and ignore rules.
    func updateProject(_ id: String, name: String, ignoreRules: String) async throws {
        _ = try await api.post("/api/coding/project/\(id)",
                               json: ["name": name, "ignore_rules": ignoreRules])
    }

    /// `POST /api/coding/agents/project/sync {project_id, on}` — the sync switch.
    /// Turning it off is remembered, so auto-sync never turns it back on.
    func setProjectSync(_ id: String, on: Bool) async throws {
        _ = try await api.post("/api/coding/agents/project/sync", json: ["project_id": id, "on": on])
    }

    /// Folder typeahead for the launch sheet, on the server or a paired Mac.
    func dirSuggest(path: String, deviceId: String?) async -> [String] {
        await CodingSessionsAPI(api: api).dirSuggest(path: path, host: deviceId == nil ? "server" : "desktop",
                                                     deviceId: deviceId)
    }

    /// The paired computers a session can be launched on.
    func desktops() async throws -> [CodingDevice] {
        try await CodingSessionsAPI(api: api).listDevices()
    }
}

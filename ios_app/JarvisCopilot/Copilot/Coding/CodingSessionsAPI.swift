import Foundation

/// Server said no, with its own words.
struct CodingServerError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// Live-terminal attach failures that need their own recovery path.
enum CodingTerminalError: LocalizedError, Equatable {
    /// A discovered Mac session whose device is OFFLINE has no process to attach
    /// to — the server answers 409 with `can_resume: true`, meaning "resume this
    /// one on the server instead".
    case deviceOffline

    var errorDescription: String? {
        "Your Mac is offline — resume this session on the server to keep working."
    }
}

/// REST wrapper for the Coding Sessions control plane (`/api/coding/*`) plus the
/// shared live-terminal machinery (`/api/terminal/*`).
///
/// Port of `api/coding_sessions.dart`. Mirrors the server's `coding_sessions`
/// toolset: launch/list/inspect/drive tmux-backed Claude Code sessions, plus
/// restart/delete/settings and a live terminal streamed over SSE.
struct CodingSessionsAPI {
    let api: JarvisAPI

    init(api: JarvisAPI = .shared) { self.api = api }

    // MARK: - Sessions list

    /// `GET /api/coding/sessions` → `{ sessions: [...] }`
    func listSessions() async throws -> [CodingSession] {
        let body = try await api.get("/api/coding/sessions").object()
        return CodingJSON.maps(body["sessions"]).map(CodingSession.init(json:))
    }

    /// The sessions plus the account `usage` block used by the Live Activity
    /// rings. `usage` is nil when the server can't compute it.
    func listSessionsWithUsage() async throws -> (sessions: [CodingSession], usage: CodingUsage?) {
        let body = try await api.get("/api/coding/sessions").object()
        return (CodingJSON.maps(body["sessions"]).map(CodingSession.init(json:)),
                CodingUsage.from(body["usage"]))
    }

    /// `GET /api/coding/usage` → `{usage: {five_hour_pct, weekly_pct, …}|null}`.
    func usage() async throws -> CodingUsage? {
        CodingUsage.from(try await api.get("/api/coding/usage").object()["usage"])
    }

    /// `POST /api/coding/la-token` — register the iOS Live Activity push token so
    /// the server can keep the activity live (APNs push-to-update) while the app
    /// is suspended.
    func registerLaToken(_ token: String, deviceId: String? = nil) async throws {
        var body: [String: Any] = ["token": token]
        if let deviceId, !deviceId.isEmpty { body["device_id"] = deviceId }
        _ = try await api.post("/api/coding/la-token", json: body)
    }

    /// `GET /api/coding/dir-suggest` → `{dirs: [...]}`. Host-aware directory
    /// typeahead for the New-session Working Directory / sync-folder fields:
    /// host='server' lists the SERVER filesystem; a `deviceId` (or host='desktop')
    /// lists that paired device's filesystem over the bridge. Returns [] on
    /// offline/error so the UI degrades gracefully.
    func dirSuggest(path: String, host: String = "server", deviceId: String? = nil) async -> [String] {
        var query = ["path": path, "host": host]
        if let deviceId, !deviceId.isEmpty { query["device_id"] = deviceId }
        do {
            let body = try await api.get("/api/coding/dir-suggest", query: query).object()
            return CodingJSON.strings(body["dirs"])
        } catch {
            // An offline device is the normal case here, so the typeahead stays
            // silent — but "no suggestions" and "the bridge is down" look
            // identical in the field without this.
            JcLog.dropped(JcLog.coding, "dir-suggest", error)
            return []
        }
    }

    // MARK: - Global Code Master settings

    /// `GET /api/coding/settings` → the global settings map
    /// `{events:{finished/needs_input/error:{telegram,mobile,toast,photon}},
    /// usage_display, remote_approvals}`. Returns `[:]` when the body is
    /// malformed so callers can merge over sensible defaults.
    func codeMasterSettings() async throws -> [String: Any] {
        CodingJSON.dict(try await api.get("/api/coding/settings").object()["settings"]) ?? [:]
    }

    /// `POST /api/coding/settings` with the full payload → `{ok, settings}`.
    /// Returns the server's canonical settings (falls back to the sent payload
    /// when absent).
    func saveCodeMasterSettings(_ payload: [String: Any]) async throws -> [String: Any] {
        let body = try await api.post("/api/coding/settings", json: payload).object()
        return CodingJSON.dict(body["settings"]) ?? payload
    }

    // MARK: - Projects

    /// `GET /api/coding/projects` → `{ projects: [...] }`
    func listProjects() async throws -> [CodingProject] {
        let body = try await api.get("/api/coding/projects").object()
        return CodingJSON.maps(body["projects"]).map(CodingProject.init(json:))
    }

    /// `GET /api/coding/projects?expand=sessions` →
    /// `{ projects: [{…, sessions:[…]}], ungrouped: [...] }`.
    ///
    /// Each project carries its nested `sessions`; `ungrouped` holds sessions
    /// with no project (legacy rows + discovered sessions).
    func listProjectsExpanded() async throws -> CodingProjectsView {
        let body = try await api.get("/api/coding/projects", query: ["expand": "sessions"]).object()
        return CodingProjectsView(
            projects: CodingJSON.maps(body["projects"]).map(CodingProject.init(json:)),
            ungrouped: CodingJSON.maps(body["ungrouped"]).map(CodingSession.init(json:)))
    }

    /// `POST /api/coding/projects {name, repo_path}` → `{ ok, project_id }`.
    func createProject(name: String, repoPath: String, defaultBranch: String? = nil) async throws -> String? {
        var body: [String: Any] = ["name": name, "repo_path": repoPath]
        if let defaultBranch, !defaultBranch.isEmpty { body["default_branch"] = defaultBranch }
        return CodingJSON.str(try await api.post("/api/coding/projects", json: body).object()["project_id"])
    }

    /// `POST /api/coding/project/{id}` — rename / set branch / set sync.
    func updateProject(_ id: String, name: String? = nil, defaultBranch: String? = nil,
                       syncEnabled: Bool? = nil, syncDesktopPath: String? = nil,
                       ignoreRules: String? = nil, deviceId: String? = nil) async throws {
        var body: [String: Any] = [:]
        if let name { body["name"] = name }
        if let defaultBranch { body["default_branch"] = defaultBranch }
        if let syncEnabled { body["sync_enabled"] = syncEnabled }
        if let syncDesktopPath { body["sync_desktop_path"] = syncDesktopPath }
        if let ignoreRules { body["ignore_rules"] = ignoreRules }
        if let deviceId { body["device_id"] = deviceId }
        _ = try await api.post("/api/coding/project/\(id)", json: body)
    }

    /// `DELETE /api/coding/project/{id}?delete_sessions=0|1` — `cascade` stops +
    /// removes its sessions; otherwise its sessions become Ungrouped.
    func deleteProject(_ id: String, cascade: Bool = false) async throws {
        _ = try await api.delete("/api/coding/project/\(id)",
                                 query: ["delete_sessions": cascade ? "1" : "0"])
    }

    /// `POST /api/coding/project/{id}/session` → `{ session }`. `cwd` defaults
    /// server-side to the project's repo_path when omitted.
    func launchInProject(_ projectId: String, cwd: String? = nil, title: String? = nil,
                         prompt: String? = nil, model: String? = nil, host: String? = nil,
                         skipPermissions: Bool = false, sync: CodingSync? = nil) async throws -> CodingSession {
        var body: [String: Any] = [:]
        put(&body, "cwd", cwd)
        put(&body, "title", title)
        put(&body, "prompt", prompt)
        put(&body, "model", model)
        put(&body, "host", host)
        if skipPermissions { body["skip_permissions"] = true }
        if let sync, sync.enabled { body["sync"] = sync.json }
        let reply = try await api.post("/api/coding/project/\(projectId)/session", json: body).object()
        return CodingSession(json: CodingJSON.dict(reply["session"]) ?? reply)
    }

    /// Relaunch an ENDED discovered/desktop session on its DEVICE — a fresh tmux
    /// in the same folder, resuming its transcript. Mirrors the WebUI's
    /// `codingRelaunchDevice`; posts to the project's session endpoint, or the
    /// top-level launch endpoint when the session has no project.
    func relaunchOnDevice(projectId: String?, cwd: String, title: String? = nil,
                          resumeSessionId: String? = nil) async throws -> CodingSession? {
        let hasProject = !(projectId ?? "").isEmpty
        var body: [String: Any] = ["host": "desktop", "cwd": cwd]
        put(&body, "title", title)
        put(&body, "resume_session_id", resumeSessionId)
        // An explicit null clears any inherited project on the server side.
        if !hasProject { body["project_id"] = NSNull() }
        let path = hasProject ? "/api/coding/project/\(projectId!)/session" : "/api/coding/launch"
        let reply = try await api.post(path, json: body).object()
        if let ok = reply["ok"], CodingJSON.isBoolean(ok), !CodingJSON.bool(ok) {
            throw CodingServerError(message: CodingJSON.str(reply["error"])
                ?? CodingJSON.str(reply["message"])
                ?? "Could not relaunch on the device")
        }
        guard let session = CodingJSON.dict(reply["session"]) ?? (reply.isEmpty ? nil : reply) else { return nil }
        return CodingSession(json: session)
    }

    /// `POST /api/coding/discover/refresh` — ask the paired device to re-scan its
    /// live tmux + transcript sessions and re-report. Discovery is async over the
    /// bridge, so callers should refresh the list again shortly after.
    func discoverRefresh() async throws {
        _ = try await api.post("/api/coding/discover/refresh")
    }

    /// `GET /api/devices` → `{ devices: [...] }`, filtered to sync-capable
    /// desktops (offline ones are still returned but flagged). Tolerates the body
    /// being a bare list or missing the `devices` key.
    func listDevices() async throws -> [CodingDevice] {
        let data = try await api.get("/api/devices").data
        let any = data.isEmpty ? nil : try? JSONSerialization.jsonObject(with: data)
        let raw = (any as? [String: Any]).map { CodingJSON.maps($0["devices"]) } ?? CodingJSON.maps(any)
        return raw.map(CodingDevice.init(json:)).filter { !$0.id.isEmpty && $0.desktopCapable }
    }

    // MARK: - One session

    /// `POST /api/coding/launch` → `{ session: {...} }`.
    ///
    /// Sends `cwd` + `repo_path` (so either server-side naming works), plus the
    /// host/skip-permissions/sync parity fields from the WebUI launch form.
    func launch(cwd: String? = nil, repoPath: String? = nil, worktree: Bool = false,
                title: String? = nil, prompt: String? = nil, model: String? = nil,
                host: String = "server", skipPermissions: Bool = false,
                sync: CodingSync? = nil) async throws -> CodingSession {
        var body: [String: Any] = ["host": host]
        put(&body, "cwd", cwd)
        put(&body, "repo_path", repoPath)
        if worktree { body["worktree"] = true }
        put(&body, "title", title)
        put(&body, "prompt", prompt)
        put(&body, "model", model)
        if skipPermissions { body["skip_permissions"] = true }
        if let sync, sync.enabled { body["sync"] = sync.json }
        let reply = try await api.post("/api/coding/launch", json: body).object()
        return CodingSession(json: CodingJSON.dict(reply["session"]) ?? reply)
    }

    /// `GET /api/coding/session/{id}` → `{ session, … }`
    func get(_ id: String) async throws -> CodingSessionDetail {
        CodingSessionDetail(json: try await api.get("/api/coding/session/\(id)").object())
    }

    /// `POST /api/coding/session/{id}/resume` → `{ ok, session? }`. Relaunch a
    /// discovered-transcript (past) session on its device. The resumed session may
    /// keep the same id or be reported under a new one.
    func resume(_ id: String) async throws -> CodingSession? {
        let reply = try await api.post("/api/coding/session/\(id)/resume").object()
        guard let session = CodingJSON.dict(reply["session"]) else { return nil }
        return CodingSession(json: session)
    }

    /// `POST /api/coding/session/{id}/restart` → `{ session: {...} }`
    func restart(_ id: String) async throws -> CodingSession? {
        let reply = try await api.post("/api/coding/session/\(id)/restart").object()
        guard let session = CodingJSON.dict(reply["session"]) else { return nil }
        return CodingSession(json: session)
    }

    /// `POST /api/coding/session/{id}/stop`
    func stop(_ id: String) async throws {
        _ = try await api.post("/api/coding/session/\(id)/stop")
    }

    /// `POST /api/coding/session/{id}/delete` — stop + permanently remove.
    func delete(_ id: String) async throws {
        _ = try await api.post("/api/coding/session/\(id)/delete")
    }

    /// `POST /api/coding/session/{id}/message`
    func sendMessage(_ id: String, text: String) async throws {
        _ = try await api.post("/api/coding/session/\(id)/message", json: ["text": text])
    }

    /// `POST /api/coding/session/{id}/settings` — partial update of
    /// `{skip_permissions?, sync?, cwd?}`. Callers should tolerate a 404 (older
    /// servers don't have this endpoint yet).
    func updateSettings(_ id: String, skipPermissions: Bool? = nil,
                        sync: CodingSync? = nil, cwd: String? = nil) async throws {
        var body: [String: Any] = [:]
        if let skipPermissions { body["skip_permissions"] = skipPermissions }
        if let sync { body["sync"] = sync.json }
        put(&body, "cwd", cwd)
        _ = try await api.post("/api/coding/session/\(id)/settings", json: body)
    }

    /// `GET /api/coding/session/{id}/sync` — live cross-device sync status.
    func syncStatus(_ id: String) async throws -> CodingSyncStatus {
        CodingSyncStatus(json: try await api.get("/api/coding/session/\(id)/sync").object())
    }

    /// `POST /api/coding/session/{id}/sync/refresh` — kick a fresh sync pass.
    func refreshSync(_ id: String) async throws {
        _ = try await api.post("/api/coding/session/\(id)/sync/refresh")
    }

    /// `POST /api/coding/upload` — attach a photo/file to a session. The server is
    /// host-aware (server-host stores locally; desktop-host delivers to the Mac
    /// over the bridge) and returns the absolute path claude can read. Returns the
    /// path, or nil when the server didn't produce one.
    func uploadFile(_ id: String, data: Data, filename: String) async throws -> String? {
        var form = MultipartBody()
        form.add("session_id", id)
        form.add(file: .init(field: "file", filename: filename,
                             mime: "application/octet-stream", data: data))
        let reply = try await api.postMultipart("/api/coding/upload", form, timeout: 45).object()
        return CodingJSON.str(reply["path"])
    }

    // MARK: - Permission relay

    /// `GET /api/coding/permission/pending` — tool-permission requests awaiting a
    /// verdict. Empty when none / relay off.
    func pendingPermissions() async throws -> [PendingPermission] {
        let body = try await api.get("/api/coding/permission/pending").object()
        return ((body["pending"] as? [Any]) ?? []).compactMap(PendingPermission.from)
    }

    /// `POST /api/coding/permission/verdict` — answer a permission request.
    /// `decision` is 'allow' | 'deny'; an optional `message` on a deny is handed
    /// to Claude as the instruction (steer instead of just refusing).
    func submitPermissionVerdict(_ requestId: String, decision: String, message: String? = nil) async throws {
        var body: [String: Any] = ["request_id": requestId, "decision": decision]
        let trimmed = (message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { body["message"] = trimmed }
        _ = try await api.post("/api/coding/permission/verdict", json: body)
    }

    // MARK: - Chat transcript

    /// `GET /api/coding/session/{id}/messages?after=N` → the conversation tail.
    ///
    /// Messages are indexed 0..total-1; pass `after=<count you already have>` to
    /// get only the new tail (after=0 returns everything, capped server-side).
    /// Throws `APIError.http(status: 409, …)` while the session has no transcript
    /// yet — callers render a friendly empty state for that.
    func chatMessages(_ id: String, after: Int = 0) async throws -> CodingChatPage {
        let body = try await api.get("/api/coding/session/\(id)/messages",
                                     query: ["after": "\(after)"]).object()
        return CodingChatPage(json: body)
    }

    /// `GET /api/coding/session/{id}/prompt` → what Claude is asking right now
    /// (`{waiting, question, options, raw}`); poll when activity_state==waiting.
    func chatPrompt(_ id: String) async throws -> CodingPromptState {
        CodingPromptState(json: try await api.get("/api/coding/session/\(id)/prompt").object())
    }

    // MARK: - Live terminal (shared /api/terminal/* machinery, keyed by session id)

    /// `POST /api/coding/session/{id}/terminal/start` — attach a server-side PTY
    /// to the session's tmux so it can be streamed over SSE.
    ///
    /// Hand-rolled rather than going through `api.post` because the 409 body's
    /// `can_resume` flag is the difference between "transient failure" and "your
    /// Mac is offline, resume on the server" — and `APIError.http` only carries a
    /// message.
    func terminalStart(_ id: String, rows: Int = 24, cols: Int = 80) async throws {
        let req = try api.request("POST", "/api/coding/session/\(id)/terminal/start",
                                  headers: ["Content-Type": "application/json"],
                                  body: try JSONSerialization.data(withJSONObject: ["rows": rows, "cols": cols]))
        let (data, http) = try await api.transport.send(req)
        guard (200..<300).contains(http.statusCode) else {
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if http.statusCode == 409, CodingJSON.bool(obj["can_resume"]) {
                throw CodingTerminalError.deviceOffline
            }
            throw APIError.http(status: http.statusCode,
                                message: APIError.message(status: http.statusCode, body: data))
        }
    }

    /// SSE `GET /api/terminal/output?session_id={id}`. Named events: `output`
    /// (`{text}`), `terminal_closed`, `terminal_error`.
    func terminalOutput(_ id: String) -> AsyncThrowingStream<SSEEvent, Error> {
        api.streamSSE("/api/terminal/output", query: ["session_id": id])
    }

    /// `POST /api/terminal/input {session_id, data}` — send keystrokes.
    func terminalInput(_ id: String, data: String) async throws {
        _ = try await api.post("/api/terminal/input", json: ["session_id": id, "data": data])
    }

    /// `POST /api/terminal/resize {session_id, rows, cols}`.
    func terminalResize(_ id: String, rows: Int, cols: Int) async throws {
        _ = try await api.post("/api/terminal/resize",
                               json: ["session_id": id, "rows": rows, "cols": cols])
    }

    /// `POST /api/terminal/close {session_id}` — detach the PTY (does NOT kill
    /// the tmux session / claude).
    func terminalClose(_ id: String) async throws {
        _ = try await api.post("/api/terminal/close", json: ["session_id": id])
    }

    // MARK: -

    /// Dart's `if (v != null && v.isNotEmpty) 'k': v` — the server treats an empty
    /// string as "set it to empty", which is never what the form means.
    private func put(_ body: inout [String: Any], _ key: String, _ value: String?) {
        if let value, !value.isEmpty { body[key] = value }
    }
}

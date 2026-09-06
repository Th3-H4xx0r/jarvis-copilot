import XCTest
@testable import JarvisCopilot

private func query(_ request: URLRequest?) -> [String: String] {
    guard let url = request?.url,
          let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [:] }
    var out: [String: String] = [:]
    for item in comps.queryItems ?? [] { out[item.name] = item.value ?? "" }
    return out
}

/// Every endpoint's request shape, plus the reply shapes the Dart wrapper
/// deliberately tolerated.
final class CodingSessionsAPITests: XCTestCase {

    private func makeAPI() -> (CodingSessionsAPI, MockTransport) {
        let (client, transport) = JarvisAPI.mocked()
        return (CodingSessionsAPI(api: client), transport)
    }

    private func assertRequest(_ t: MockTransport, _ method: String, _ path: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(t.lastRequest?.httpMethod, method, file: file, line: line)
        XCTAssertEqual(t.lastRequest?.url?.path, path, file: file, line: line)
    }

    // MARK: - Sessions list / usage

    func testListSessions() async throws {
        let (api, t) = makeAPI()
        t.enqueue(json: ["sessions": [["id": "a", "status": "running"], ["id": "b"], "junk"]])
        let sessions = try await api.listSessions()
        assertRequest(t, "GET", "/api/coding/sessions")
        XCTAssertEqual(sessions.map(\.id), ["a", "b"])
    }

    func testListSessionsWithUsage() async throws {
        let (api, t) = makeAPI()
        t.enqueue(json: ["sessions": [["id": "a"]],
                         "usage": ["five_hour_pct": 42, "weekly_pct": 7,
                                   "five_hour_resets": "in 2h", "weekly_resets": "Mon"]])
        let r = try await api.listSessionsWithUsage()
        XCTAssertEqual(r.sessions.count, 1)
        XCTAssertEqual(r.usage, CodingUsage(fiveHourPct: 42, weeklyPct: 7,
                                            fiveHourResets: "in 2h", weeklyResets: "Mon"))
    }

    func testUsageEndpointHandlesNull() async throws {
        let (api, t) = makeAPI()
        t.enqueue(json: ["usage": ["five_hour_pct": 10]])
        let awaited1 = try await api.usage()?.fiveHourPct
        XCTAssertEqual(awaited1, 10)
        assertRequest(t, "GET", "/api/coding/usage")
        t.enqueue(json: ["usage": NSNull()])
        let awaited2 = try await api.usage()
        XCTAssertNil(awaited2)
    }

    func testRegisterLaToken() async throws {
        let (api, t) = makeAPI()
        t.enqueue(json: ["ok": true])
        try await api.registerLaToken("abc123")
        assertRequest(t, "POST", "/api/coding/la-token")
        XCTAssertEqual(t.lastBody() as? [String: String], ["token": "abc123"])

        t.enqueue(json: ["ok": true])
        try await api.registerLaToken("abc123", deviceId: "dev-1")
        XCTAssertEqual(t.lastBody() as? [String: String], ["token": "abc123", "device_id": "dev-1"])
    }

    // MARK: - dir-suggest

    func testDirSuggestSendsHostAndDevice() async {
        let (api, t) = makeAPI()
        t.enqueue(json: ["dirs": ["/Users/p/code", "/Users/p/code/jc"]])
        let dirs = await api.dirSuggest(path: "/Users/p/co", host: "desktop", deviceId: "dev-1")
        assertRequest(t, "GET", "/api/coding/dir-suggest")
        XCTAssertEqual(query(t.lastRequest),
                       ["path": "/Users/p/co", "host": "desktop", "device_id": "dev-1"])
        XCTAssertEqual(dirs, ["/Users/p/code", "/Users/p/code/jc"])
    }

    func testDirSuggestSwallowsErrors() async {
        let (api, t) = makeAPI()
        t.enqueue(json: ["error": "offline"], status: 503)
        let dirs = await api.dirSuggest(path: "/x")
        XCTAssertEqual(dirs, [], "the typeahead must degrade, not throw")
        XCTAssertEqual(query(t.lastRequest)["host"], "server")
    }

    // MARK: - Code Master settings

    func testCodeMasterSettingsRoundTrip() async throws {
        let (api, t) = makeAPI()
        t.enqueue(json: ["settings": ["usage_display": false,
                                      "events": ["finished": ["mobile": true]]]])
        let loaded = try await api.codeMasterSettings()
        assertRequest(t, "GET", "/api/coding/settings")
        XCTAssertEqual(loaded["usage_display"] as? Bool, false)

        // A malformed body must not throw — callers merge over defaults.
        t.enqueue(json: ["ok": true])
        let awaited3 = try await api.codeMasterSettings().isEmpty
        XCTAssertTrue(awaited3)

        t.enqueue(json: ["ok": true, "settings": ["remote_approvals": true]])
        let saved = try await api.saveCodeMasterSettings(["remote_approvals": false])
        assertRequest(t, "POST", "/api/coding/settings")
        XCTAssertEqual(saved["remote_approvals"] as? Bool, true, "the server's copy wins")

        // No `settings` in the reply ⇒ echo what we sent.
        t.enqueue(json: ["ok": true])
        let echoed = try await api.saveCodeMasterSettings(["usage_display": true])
        XCTAssertEqual(echoed["usage_display"] as? Bool, true)
    }

    // MARK: - Projects

    func testListProjects() async throws {
        let (api, t) = makeAPI()
        t.enqueue(json: ["projects": [["id": "p1", "name": "jc"]]])
        let awaited4 = try await api.listProjects().map(\.name)
        XCTAssertEqual(awaited4, ["jc"])
        assertRequest(t, "GET", "/api/coding/projects")
        XCTAssertTrue(query(t.lastRequest).isEmpty)
    }

    func testListProjectsExpanded() async throws {
        let (api, t) = makeAPI()
        t.enqueue(json: [
            "projects": [["id": "p1", "name": "jc", "sessions": [["id": "s1"], ["id": "s2"]]]],
            "ungrouped": [["id": "s3", "source": "discovered-tmux"]],
        ])
        let view = try await api.listProjectsExpanded()
        XCTAssertEqual(query(t.lastRequest), ["expand": "sessions"])
        XCTAssertEqual(view.projects.first?.sessions.map(\.id), ["s1", "s2"])
        XCTAssertEqual(view.ungrouped.map(\.id), ["s3"])
    }

    func testCreateProject() async throws {
        let (api, t) = makeAPI()
        t.enqueue(json: ["ok": true, "project_id": "p9"])
        let id = try await api.createProject(name: "jc", repoPath: "/home/p/jc", defaultBranch: "main")
        assertRequest(t, "POST", "/api/coding/projects")
        XCTAssertEqual(t.lastBody() as? [String: String],
                       ["name": "jc", "repo_path": "/home/p/jc", "default_branch": "main"])
        XCTAssertEqual(id, "p9")

        // An empty branch is dropped, not sent as "".
        t.enqueue(json: ["ok": true])
        _ = try await api.createProject(name: "jc", repoPath: "/x", defaultBranch: "")
        XCTAssertNil(t.lastBody()["default_branch"])
    }

    func testUpdateProjectOnlySendsWhatChanged() async throws {
        let (api, t) = makeAPI()
        t.enqueue(json: ["ok": true])
        try await api.updateProject("p1", name: "renamed", syncEnabled: true,
                                    syncDesktopPath: "/Users/p/jc")
        assertRequest(t, "POST", "/api/coding/project/p1")
        let body = t.lastBody()
        XCTAssertEqual(body["name"] as? String, "renamed")
        XCTAssertEqual(body["sync_enabled"] as? Bool, true)
        XCTAssertEqual(body["sync_desktop_path"] as? String, "/Users/p/jc")
        XCTAssertEqual(body.count, 3)

        // An explicitly empty string IS sent (that's how you clear ignore rules).
        t.enqueue(json: ["ok": true])
        try await api.updateProject("p1", ignoreRules: "")
        XCTAssertEqual(t.lastBody()["ignore_rules"] as? String, "")
    }

    func testDeleteProjectPassesTheCascadeFlag() async throws {
        let (api, t) = makeAPI()
        t.enqueue(json: ["ok": true])
        try await api.deleteProject("p1")
        assertRequest(t, "DELETE", "/api/coding/project/p1")
        XCTAssertEqual(query(t.lastRequest), ["delete_sessions": "0"])

        t.enqueue(json: ["ok": true])
        try await api.deleteProject("p1", cascade: true)
        XCTAssertEqual(query(t.lastRequest), ["delete_sessions": "1"])
    }

    func testLaunchInProject() async throws {
        let (api, t) = makeAPI()
        t.enqueue(json: ["session": ["id": "s9", "status": "starting"]])
        let s = try await api.launchInProject("p1", cwd: "", title: "fix tests",
                                              prompt: "run the suite", model: "opus",
                                              host: "desktop", skipPermissions: true,
                                              sync: CodingSync(enabled: true, device: "mac"))
        assertRequest(t, "POST", "/api/coding/project/p1/session")
        let body = t.lastBody()
        XCTAssertNil(body["cwd"], "an empty cwd falls back to the project's repo_path server-side")
        XCTAssertEqual(body["title"] as? String, "fix tests")
        XCTAssertEqual(body["prompt"] as? String, "run the suite")
        XCTAssertEqual(body["host"] as? String, "desktop")
        XCTAssertEqual(body["skip_permissions"] as? Bool, true)
        XCTAssertEqual((body["sync"] as? [String: Any])?["device"] as? String, "mac")
        XCTAssertEqual(s.id, "s9")

        // A disabled sync block is never sent.
        t.enqueue(json: ["session": ["id": "s9"]])
        _ = try await api.launchInProject("p1", sync: CodingSync(enabled: false, device: "mac"))
        XCTAssertNil(t.lastBody()["sync"])
        XCTAssertNil(t.lastBody()["skip_permissions"])
    }

    func testLaunchAlwaysSendsHostAndBothPathSpellings() async throws {
        let (api, t) = makeAPI()
        t.enqueue(json: ["session": ["id": "s1"]])
        _ = try await api.launch(cwd: "/home/p/jc", repoPath: "/home/p/jc", worktree: true,
                                 title: "t", prompt: "p", model: "sonnet")
        assertRequest(t, "POST", "/api/coding/launch")
        let body = t.lastBody()
        XCTAssertEqual(body["cwd"] as? String, "/home/p/jc")
        XCTAssertEqual(body["repo_path"] as? String, "/home/p/jc")
        XCTAssertEqual(body["worktree"] as? Bool, true)
        XCTAssertEqual(body["host"] as? String, "server")
    }

    func testLaunchAcceptsABareSessionBody() async throws {
        let (api, t) = makeAPI()
        t.enqueue(json: ["id": "s2", "status": "running"])
        let awaited5 = try await api.launch().id
        XCTAssertEqual(awaited5, "s2")
    }

    func testRelaunchOnDeviceWithAndWithoutAProject() async throws {
        let (api, t) = makeAPI()
        t.enqueue(json: ["session": ["id": "s5", "status": "running"]])
        let s = try await api.relaunchOnDevice(projectId: "p1", cwd: "/home/p/jc",
                                               title: "t", resumeSessionId: "claude-1")
        assertRequest(t, "POST", "/api/coding/project/p1/session")
        var body = t.lastBody()
        XCTAssertEqual(body["host"] as? String, "desktop")
        XCTAssertEqual(body["resume_session_id"] as? String, "claude-1")
        XCTAssertNil(body["project_id"])
        XCTAssertEqual(s?.id, "s5")

        t.enqueue(json: ["session": ["id": "s6"]])
        _ = try await api.relaunchOnDevice(projectId: nil, cwd: "/home/p/jc")
        assertRequest(t, "POST", "/api/coding/launch")
        body = t.lastBody()
        XCTAssertTrue(body["project_id"] is NSNull, "an explicit null clears the project")
        XCTAssertNil(body["title"])
    }

    func testRelaunchOnDeviceSurfacesAnOkFalseBody() async throws {
        let (api, t) = makeAPI()
        t.enqueue(json: ["ok": false, "error": "device offline"])
        do {
            _ = try await api.relaunchOnDevice(projectId: nil, cwd: "/x")
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual((error as? CodingServerError)?.message, "device offline")
        }
        // A 0 is NOT the bool false — only a real `ok: false` is a failure.
        t.enqueue(json: ["ok": 0, "session": ["id": "s1"]])
        let awaited6 = try await api.relaunchOnDevice(projectId: nil, cwd: "/x")?.id
        XCTAssertEqual(awaited6, "s1")
    }

    func testDiscoverRefresh() async throws {
        let (api, t) = makeAPI()
        t.enqueue(json: ["ok": true])
        try await api.discoverRefresh()
        assertRequest(t, "POST", "/api/coding/discover/refresh")
        // A rescan is a bare kick — no body, nothing to configure.
        XCTAssertTrue(t.lastBody().isEmpty)
        XCTAssertTrue(t.lastRequest?.url?.query?.isEmpty ?? true)
    }

    func testDiscoverRefreshThrowsSoTheStoreCanSayTheRescanFailed() async throws {
        let (api, t) = makeAPI()
        t.enqueue(json: ["error": "device offline"], status: 502)
        do {
            try await api.discoverRefresh()
            XCTFail("a failed rescan must not look like a successful one")
        } catch {
            XCTAssertEqual(apiErrorMessage(error), "device offline")
        }
    }

    // MARK: - Devices

    func testListDevicesFiltersToSyncCapableDesktops() async throws {
        let (api, t) = makeAPI()
        t.enqueue(json: ["devices": [
            ["id": "desk", "kind": "desktop", "name": "Mac Studio"],
            ["id": "phone", "kind": "mobile-ios", "bridge_connected": true],
            ["id": "web", "kind": "browser"],
            ["id": "", "kind": "desktop"],
        ]])
        let awaited7 = try await api.listDevices().map(\.id)
        XCTAssertEqual(awaited7, ["desk"])
        assertRequest(t, "GET", "/api/devices")
    }

    func testListDevicesToleratesABareArray() async throws {
        let (api, t) = makeAPI()
        t.enqueue(json: [["id": "desk", "kind": "desktop"]])
        let awaited8 = try await api.listDevices().map(\.id)
        XCTAssertEqual(awaited8, ["desk"])
    }

    // MARK: - One session

    func testGetSyncAndRefreshSync() async throws {
        let (api, t) = makeAPI()
        t.enqueue(json: ["session": ["id": "s1", "status": "running"]])
        let awaited9 = try await api.get("s1").session.status
        XCTAssertEqual(awaited9, "running")
        assertRequest(t, "GET", "/api/coding/session/s1")

        t.enqueue(json: ["enabled": true, "status": "syncing", "total": 4, "done": 1])
        let status = try await api.syncStatus("s1")
        assertRequest(t, "GET", "/api/coding/session/s1/sync")
        XCTAssertEqual(status.pct, 25)

        t.enqueue(json: ["ok": true])
        try await api.refreshSync("s1")
        assertRequest(t, "POST", "/api/coding/session/s1/sync/refresh")
    }

    func testStopRestartDeleteAndMessage() async throws {
        let (api, t) = makeAPI()
        t.enqueue(json: ["ok": true])
        try await api.stop("s1")
        assertRequest(t, "POST", "/api/coding/session/s1/stop")

        t.enqueue(json: ["session": ["id": "s1", "status": "starting"]])
        let awaited10 = try await api.restart("s1")?.status
        XCTAssertEqual(awaited10, "starting")
        assertRequest(t, "POST", "/api/coding/session/s1/restart")

        // No `session` in the reply ⇒ nil, not a crash.
        t.enqueue(json: ["ok": true])
        let awaited11 = try await api.restart("s1")
        XCTAssertNil(awaited11)

        t.enqueue(json: ["ok": true])
        try await api.delete("s1")
        assertRequest(t, "POST", "/api/coding/session/s1/delete")

        t.enqueue(json: ["ok": true])
        try await api.sendMessage("s1", text: "hello")
        assertRequest(t, "POST", "/api/coding/session/s1/message")
        XCTAssertEqual(t.lastBody() as? [String: String], ["text": "hello"])
    }

    func testResumeReturnsNilWithoutASession() async throws {
        let (api, t) = makeAPI()
        t.enqueue(json: ["ok": true])
        let awaited12 = try await api.resume("s1")
        XCTAssertNil(awaited12)
        assertRequest(t, "POST", "/api/coding/session/s1/resume")
        t.enqueue(json: ["ok": true, "session": ["id": "s2"]])
        let awaited13 = try await api.resume("s1")?.id
        XCTAssertEqual(awaited13, "s2")
    }

    func testUpdateSettingsSendsOnlyTheGivenFields() async throws {
        let (api, t) = makeAPI()
        t.enqueue(json: ["ok": true])
        try await api.updateSettings("s1", skipPermissions: false)
        assertRequest(t, "POST", "/api/coding/session/s1/settings")
        XCTAssertEqual(t.lastBody()["skip_permissions"] as? Bool, false)
        XCTAssertEqual(t.lastBody().count, 1)

        // Unlike launch, a DISABLED sync block is still sent here — that's how you
        // turn sync off.
        t.enqueue(json: ["ok": true])
        try await api.updateSettings("s1", sync: CodingSync(enabled: false), cwd: "/new")
        XCTAssertEqual((t.lastBody()["sync"] as? [String: Any])?["enabled"] as? Bool, false)
        XCTAssertEqual(t.lastBody()["cwd"] as? String, "/new")
    }

    // MARK: - Upload

    func testUploadFileBuildsTheMultipartBody() async throws {
        let (api, t) = makeAPI()
        t.enqueue(json: ["ok": true, "path": "/tmp/jc-uploads/shot.png"])
        let path = try await api.uploadFile("cs_1", data: Data("PNGDATA".utf8), filename: "shot.png")
        assertRequest(t, "POST", "/api/coding/upload")
        let body = String(data: t.lastRequest?.httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("name=\"session_id\""))
        XCTAssertTrue(body.contains("cs_1"))
        XCTAssertTrue(body.contains("name=\"file\"; filename=\"shot.png\""))
        XCTAssertTrue(body.contains("PNGDATA"))
        XCTAssertTrue((t.lastRequest?.value(forHTTPHeaderField: "Content-Type") ?? "")
            .hasPrefix("multipart/form-data; boundary="))
        XCTAssertEqual(path, "/tmp/jc-uploads/shot.png")

        // An empty/absent path is a failure, not a valid reference.
        t.enqueue(json: ["ok": true, "path": ""])
        let awaited14 = try await api.uploadFile("cs_1", data: Data(), filename: "x")
        XCTAssertNil(awaited14)
    }

    // MARK: - Permission relay

    func testPendingPermissions() async throws {
        let (api, t) = makeAPI()
        t.enqueue(json: ["pending": [
            ["request_id": "rq_1", "tool": "Bash", "summary": "Bash: rm -rf build/",
             "session_id": "cs_1", "cwd": "/home/p/jc"],
            ["tool": "Edit"],   // no request_id ⇒ dropped
            "junk",
        ]])
        let pending = try await api.pendingPermissions()
        assertRequest(t, "GET", "/api/coding/permission/pending")
        XCTAssertEqual(pending.map(\.requestId), ["rq_1"])
        XCTAssertEqual(pending.first?.projectLabel, "jc")
    }

    func testSubmitPermissionVerdictTrimsAndOmitsABlankMessage() async throws {
        let (api, t) = makeAPI()
        t.enqueue(json: ["ok": true])
        try await api.submitPermissionVerdict("rq_1", decision: "deny", message: "  use rm -i  ")
        assertRequest(t, "POST", "/api/coding/permission/verdict")
        XCTAssertEqual(t.lastBody() as? [String: String],
                       ["request_id": "rq_1", "decision": "deny", "message": "use rm -i"])

        t.enqueue(json: ["ok": true])
        try await api.submitPermissionVerdict("rq_1", decision: "allow", message: "   ")
        XCTAssertEqual(t.lastBody() as? [String: String],
                       ["request_id": "rq_1", "decision": "allow"])
    }

    // MARK: - Chat transcript

    func testChatMessagesPassesTheAfterCursor() async throws {
        let (api, t) = makeAPI()
        t.enqueue(json: ["messages": [["i": 3, "role": "assistant", "text": "done"]],
                         "total": 4, "status": "idle"])
        let page = try await api.chatMessages("s1", after: 3)
        assertRequest(t, "GET", "/api/coding/session/s1/messages")
        XCTAssertEqual(query(t.lastRequest), ["after": "3"])
        XCTAssertEqual(page.total, 4)
        XCTAssertEqual(page.messages.first?.i, 3)
    }

    func testChatMessagesThrowsA409BeforeATranscriptExists() async {
        let (api, t) = makeAPI()
        t.enqueue(json: ["error": "no transcript yet"], status: 409)
        do {
            _ = try await api.chatMessages("s1")
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? APIError, .http(status: 409, message: "no transcript yet"))
        }
    }

    func testChatPrompt() async throws {
        let (api, t) = makeAPI()
        t.enqueue(json: ["waiting": true, "question": "Run this?",
                         "options": [["key": "1", "label": "Yes"]], "raw": "pane tail"])
        let p = try await api.chatPrompt("s1")
        assertRequest(t, "GET", "/api/coding/session/s1/prompt")
        XCTAssertTrue(p.waiting)
        XCTAssertEqual(p.options.map(\.label), ["Yes"])
    }

    // MARK: - Live terminal

    func testTerminalStartSendsTheGeometry() async throws {
        let (api, t) = makeAPI()
        t.enqueue(json: ["ok": true])
        try await api.terminalStart("s1", rows: 30, cols: 100)
        assertRequest(t, "POST", "/api/coding/session/s1/terminal/start")
        XCTAssertEqual(t.lastBody() as? [String: Int], ["rows": 30, "cols": 100])
    }

    func testTerminalStartMapsTheOfflineDeviceConflict() async {
        let (api, t) = makeAPI()
        t.enqueue(json: ["error": "device offline", "can_resume": true], status: 409)
        do {
            try await api.terminalStart("s1")
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? CodingTerminalError, .deviceOffline)
        }
    }

    func testTerminalStartOtherFailuresStayHTTPErrors() async {
        let (api, t) = makeAPI()
        t.enqueue(json: ["error": "busy"], status: 409)
        do {
            try await api.terminalStart("s1")
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? APIError, .http(status: 409, message: "busy"))
        }
    }

    func testTerminalOutputStream() async throws {
        let (api, t) = makeAPI()
        t.enqueueSSE("""
        event: output
        data: {"text":"$ ls\\r\\n"}

        event: terminal_closed
        data: {"reason":"ended"}


        """)
        let events = try await collect(api.terminalOutput("s1"))
        XCTAssertEqual(query(t.lastRequest), ["session_id": "s1"])
        XCTAssertEqual(t.lastRequest?.url?.path, "/api/terminal/output")
        XCTAssertEqual(events.map(\.event), ["output", "terminal_closed"])
        XCTAssertEqual(CodingTerminalEvent(events[0]), .output("$ ls\r\n"))
        XCTAssertEqual(CodingTerminalEvent(events[1]), .closed(reason: "ended"))
    }

    func testTerminalInputResizeAndClose() async throws {
        let (api, t) = makeAPI()
        t.enqueue(json: ["ok": true])
        try await api.terminalInput("s1", data: "\r")
        assertRequest(t, "POST", "/api/terminal/input")
        XCTAssertEqual(t.lastBody() as? [String: String], ["session_id": "s1", "data": "\r"])

        t.enqueue(json: ["ok": true])
        try await api.terminalResize("s1", rows: 40, cols: 120)
        assertRequest(t, "POST", "/api/terminal/resize")
        let body = t.lastBody()
        XCTAssertEqual(body["session_id"] as? String, "s1")
        XCTAssertEqual(body["rows"] as? Int, 40)
        XCTAssertEqual(body["cols"] as? Int, 120)

        t.enqueue(json: ["ok": true])
        try await api.terminalClose("s1")
        assertRequest(t, "POST", "/api/terminal/close")
        XCTAssertEqual(t.lastBody() as? [String: String], ["session_id": "s1"])
    }
}

import XCTest
@testable import JarvisCopilot

/// The Agents tab: the merged list pushed on the `agents_list` topic, the
/// approvals / questions waiting on you, decisions, and messages from the phone.
@MainActor
final class AgentsTests: XCTestCase {

    private let item: [String: Any] = [
        "key": "d1|claude|s1", "host": "d1", "agent": "claude", "session_id": "s1",
        "cwd": "/Users/p/code/app", "project": "app", "state": "working",
        "step": "Bash: npm test", "steps": [["t": "run the tests", "at": 1781000000.0],
                                             ["t": "Bash: npm test", "at": 1781000005.0]],
        "subagents": 1, "compactions": 0, "model": "claude-opus-5-5",
        "terminal": ["bundle_id": "com.apple.Terminal", "term_program": "Apple_Terminal"],
        "started_at": 1781000000.0, "last_event_at": 1781000005.0,
        "coding_session_id": "cs_1", "device_id": "d1",
        "turn_summary": ["prompt": "run the tests", "actions": 3, "files": 1, "added": 4,
                         "removed": 2, "final": "", "started_at": 1781000000.0],
    ]

    private func approval(_ rid: String = "r1", key: String = "d1|claude|s1") -> [String: Any] {
        ["request_id": rid, "fingerprint": "fp-\(rid)", "kind": "permission", "tool": "Bash",
         "summary": "Bash: rm -rf build", "command": "rm -rf build", "project": "app",
         "key": key, "can_always": true, "agent": "claude", "created": 1781000006.0]
    }

    // MARK: models

    func testSessionItemParses() {
        let s = AgentSessionItem(json: item)
        XCTAssertEqual(s.key, "d1|claude|s1")
        XCTAssertEqual(s.state, .working)
        XCTAssertEqual(s.agentName, "Claude Code")
        XCTAssertEqual(s.hostApp, "Terminal")
        XCTAssertEqual(s.steps.map(\.text), ["run the tests", "Bash: npm test"])
        XCTAssertEqual(s.turnSummary?.added, 4)
        XCTAssertEqual(s.codingSessionId, "cs_1")
    }

    func testUnknownStateFallsBackToIdle() {
        var json = item
        json["state"] = "something-new"
        XCTAssertEqual(AgentSessionItem(json: json).state, .idle)
    }

    func testRequestParsesApprovalAndQuestion() {
        let a = AgentRequest.from(approval())
        XCTAssertEqual(a?.kind, .approval)
        XCTAssertEqual(a?.canAlways, true)
        XCTAssertEqual(a?.command, "rm -rf build")
        let q = AgentRequest.from([
            "request_id": "r2", "fingerprint": "fq", "kind": "ask", "tool": "AskUserQuestion",
            "summary": "", "key": "k", "questions": [[
                "question": "Which db?", "header": "DB", "multiSelect": true,
                "options": [["label": "Postgres", "description": "big"], ["label": "SQLite"]],
            ] as [String: Any]],
        ])
        XCTAssertEqual(q?.kind, .question)
        XCTAssertEqual(q?.questions.first?.options.map(\.label), ["Postgres", "SQLite"])
        XCTAssertEqual(q?.questions.first?.multiSelect, true)
        XCTAssertNil(AgentRequest.from(["kind": "permission"]))  // no request id → no dead card
    }

    func testTurnParsesActionsAndDiffs() {
        let turn = AgentTurn(json: [
            "prompt": "fix it", "final": "Done.", "started_at": 1781000000.0, "ended_at": 1781000060.0,
            "actions": [["tool": "Edit", "summary": "Edit: /a.py", "output": "", "failed": false,
                         "at": 1781000010.0, "file": 0] as [String: Any],
                        ["tool": "Bash", "summary": "Bash: make", "output": "boom", "failed": true,
                         "at": 1781000020.0] as [String: Any]],
            "files": [["path": "/w/a.py", "added": 1, "removed": 1, "new": false, "truncated": false,
                       "lines": [["k": " ", "t": "x = 1"], ["k": "-", "t": "y = 2"],
                                 ["k": "+", "t": "y = 3"], ["k": "@", "t": ""]]] as [String: Any]],
        ])
        XCTAssertEqual(turn.actions.count, 2)
        XCTAssertEqual(turn.actions[0].fileIndex, 0)
        XCTAssertTrue(turn.actions[1].failed)
        XCTAssertEqual(turn.files[0].name, "a.py")
        XCTAssertEqual(turn.files[0].lines.map(\.kind), [.context, .removed, .added, .gap])
        XCTAssertEqual(turn.duration, 60)
    }

    func testPlanUsage() {
        let u = AgentPlanUsage(json: ["five_hour": ["used_percentage": 42.0, "resets_at": 4102444800.0],
                                      "seven_day": ["used_percentage": 250, "resets_at": 4102444800.0]])
        XCTAssertEqual(u?.fiveHour?.percent, 42)
        XCTAssertEqual(u?.sevenDay?.percent, 100)  // clamped
        XCTAssertNil(AgentPlanUsage(json: [:]))
    }

    func testCodexLineShowsOnlyTheWindowsCodexReports() {
        let week = AgentPlanUsage(json: ["seven_day": ["used_percentage": 40, "resets_at": 4102444800.0]])!
        XCTAssertEqual(AgentPlanRings.codexLine(week), "Codex · week 40%")
    }

    // MARK: store

    /// A conversation as `/agents/list` sends it.
    private func conv(_ ckey: String = "claude|s1", state: String = "working", key: String? = "d1|claude|s1",
                      pending: [String: Any]? = nil, at: Double = 1781000005) -> [String: Any] {
        var c: [String: Any] = [
            "ckey": ckey, "agent": "claude", "session_id": ckey.components(separatedBy: "|").last ?? "",
            "title": "Fix the login test", "project_id": "p1", "project": "app", "cwd": "/Users/p/code/app",
            "owner": "d1", "owner_name": "MacBook", "status": "live", "state": state,
            "last_event_at": at, "can_send": true,
        ]
        if let key { c["key"] = key }
        if let pending { c["pending"] = pending }
        return c
    }

    private func listJSON(needs: [[String: Any]] = [], sessions: [[String: Any]] = []) -> [String: Any] {
        ["card": NSNull(), "needs_you": needs,
         "projects": sessions.isEmpty ? [] : [["id": "p1", "name": "app", "sessions": sessions]],
         "usage": ["five_hour": ["used_percentage": 10, "resets_at": 4102444800.0]],
         "usage_codex": ["seven_day": ["used_percentage": 64, "resets_at": 4102444800.0]], "ts": 1.0]
    }

    func testRefreshLoadsTheListTheCardsAndUsage() async {
        let (client, transport) = JarvisAPI.mocked()
        let waiting = conv(state: "approval", pending: ["kind": "approval", "fingerprint": "fp-r1"])
        transport.route("/api/coding/agents/list", json: listJSON(needs: [waiting]))
        transport.route("/api/coding/permission/pending", json: ["pending": [approval()]])
        let store = AgentsStore(api: AgentsAPI(api: client), topics: BridgeTopics())
        await store.refresh()
        XCTAssertEqual(store.codexUsage?.sevenDay?.percent, 64)
        XCTAssertNil(store.codexUsage?.fiveHour)
        XCTAssertEqual(store.usage?.fiveHour?.percent, 10)
        XCTAssertEqual(store.needsYou.map(\.ckey), ["claude|s1"])
        XCTAssertEqual(store.requests.map(\.requestId), ["r1"])
        XCTAssertEqual(store.request(for: store.needsYou[0])?.requestId, "r1")
        XCTAssertEqual(store.waitingCount, 1, "the card belongs to its row: counted once")
    }

    func testAPushUpdatesTheListWithoutFetching() async {
        let (client, transport) = JarvisAPI.mocked()
        let store = AgentsStore(api: AgentsAPI(api: client), topics: BridgeTopics())
        store.apply(listJSON(sessions: [conv(), conv("claude|s2", state: "finished", key: nil, at: 1781000000)]))
        XCTAssertEqual(store.projects.first?.sessions.map(\.ckey), ["claude|s1", "claude|s2"])
        XCTAssertTrue(store.loaded)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testANewPendingFingerprintFetchesTheCards() async {
        let (client, transport) = JarvisAPI.mocked()
        transport.route("/api/coding/permission/pending", json: ["pending": [approval()]])
        let store = AgentsStore(api: AgentsAPI(api: client), topics: BridgeTopics())
        store.apply(listJSON(needs: [conv(state: "approval",
                                          pending: ["kind": "approval", "fingerprint": "fp-r1"])]))
        let deadline = Date().addingTimeInterval(2)
        while store.requests.isEmpty && Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(store.requests.map(\.fingerprint), ["fp-r1"])
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testDecidePostsTheVerdictAndDropsTheCard() async {
        let (client, transport) = JarvisAPI.mocked()
        transport.route("/api/coding/agents/list", json: listJSON(needs: [conv(state: "approval")]))
        transport.route("/api/coding/permission/pending", json: ["pending": [approval()]])
        transport.route("/api/coding/permission/verdict", json: ["ok": true])
        let store = AgentsStore(api: AgentsAPI(api: client), topics: BridgeTopics())
        await store.refresh()
        let ok = await store.decide(store.requests[0], .always)
        XCTAssertTrue(ok)
        XCTAssertEqual(transport.lastBody()["decision"] as? String, "always")
        XCTAssertEqual(transport.lastBody()["request_id"] as? String, "r1")
        XCTAssertTrue(store.requests.isEmpty)
    }

    func testAnswersKeepTheirShape() async {
        let (client, transport) = JarvisAPI.mocked()
        transport.route("/api/coding/permission/verdict", json: ["ok": true])
        let store = AgentsStore(api: AgentsAPI(api: client), topics: BridgeTopics())
        let q = AgentRequest.from([
            "request_id": "r2", "fingerprint": "fq", "kind": "ask", "key": "k", "questions": [
                ["question": "Which db?", "multiSelect": false, "options": [["label": "A"]]],
                ["question": "Which tests?", "multiSelect": true, "options": [["label": "unit"]]],
            ]])!
        let ok = await store.answer(q, ["Which db?": ["A"], "Which tests?": ["unit", "e2e"]])
        XCTAssertTrue(ok)
        let answers = transport.lastBody()["answers"] as? [String: Any]
        XCTAssertEqual(answers?["Which db?"] as? String, "A")
        XCTAssertEqual(answers?["Which tests?"] as? [String], ["unit", "e2e"])
        XCTAssertEqual(transport.lastBody()["decision"] as? String, "answer")
    }

    func testVisibilityWantsAndDropsTheListTopic() {
        let (client, _) = JarvisAPI.mocked()
        let topics = BridgeTopics()
        var frames: [[String: Any]] = []
        topics.send = { frames.append($0) }
        let store = AgentsStore(api: AgentsAPI(api: client), topics: topics)
        store.setVisible(true)
        XCTAssertTrue(topics.isWanted("agents_list"))
        XCTAssertFalse(topics.isWanted("agents"), "the merged tab hears one topic")
        store.setVisible(false)
        XCTAssertFalse(topics.isWanted("agents_list"))
        XCTAssertEqual(frames.count, 2)
    }

    // MARK: sending from the phone (no Face ID: only approvals ask)

    func testASentMessageShowsWhatTheServerDidWithIt() async {
        let (client, transport) = JarvisAPI.mocked()
        transport.route("/api/coding/agents/send", json: ["delivery": ["id": "d1", "state": "queued"]])
        let store = AgentsStore(api: AgentsAPI(api: client), topics: BridgeTopics())
        await store.send("run the tests", to: "claude|s1", prompts: ["fix it"])
        XCTAssertEqual(store.outgoing(for: "claude|s1").map(\.text), ["run the tests"])
        XCTAssertEqual(store.outgoing(for: "claude|s1").first?.phase, .queued)
        XCTAssertEqual(transport.lastBody()["text"] as? String, "run the tests")
        XCTAssertEqual(transport.lastBody()["ckey"] as? String, "claude|s1")
        XCTAssertTrue(store.outgoing(for: "other").isEmpty)
    }

    func testSendNowAsksForItAndARetryKeepsIt() async throws {
        let (client, transport) = JarvisAPI.mocked()
        transport.route("/api/coding/agents/send",
                        json: ["delivery": ["state": "failed", "reason": "no_runtime"]], status: 409)
        let store = AgentsStore(api: AgentsAPI(api: client), topics: BridgeTopics())
        await store.send("stop and fix the tests", to: "claude|s1", prompts: [], now: true)
        XCTAssertEqual(transport.lastBody()["now"] as? Bool, true)
        let id = try XCTUnwrap(store.outgoing(for: "claude|s1").first?.id)
        await store.retry(id, ckey: "claude|s1")
        XCTAssertEqual(transport.lastBody()["now"] as? Bool, true, "a retry goes in the same way")
        await store.send("then lint", to: "claude|s1", prompts: [])
        XCTAssertNil(transport.lastBody()["now"], "a plain send joins the queue")
    }

    func testAFailedSendSaysWhy() async {
        let (client, transport) = JarvisAPI.mocked()
        transport.route("/api/coding/agents/send",
                        json: ["delivery": ["state": "failed", "reason": "owner_offline"]], status: 409)
        let store = AgentsStore(api: AgentsAPI(api: client), topics: BridgeTopics())
        await store.send("go on", to: "claude|s1", prompts: [])
        XCTAssertEqual(store.outgoing(for: "claude|s1").first?.phase, .failed(.macOffline))
    }

    func testRetryResendsTheSameBubble() async throws {
        let (client, transport) = JarvisAPI.mocked()
        transport.route("/api/coding/agents/send",
                        json: ["delivery": ["state": "failed", "reason": "no_runtime"]], status: 409)
        let store = AgentsStore(api: AgentsAPI(api: client), topics: BridgeTopics())
        await store.send("go on", to: "claude|s1", prompts: [])
        let id = try XCTUnwrap(store.outgoing(for: "claude|s1").first?.id)
        XCTAssertEqual(store.outgoing(for: "claude|s1").first?.phase, .failed(.noRuntime))
        await store.retry(id, ckey: "claude|s1")
        XCTAssertEqual(store.outgoing(for: "claude|s1").map(\.id), [id])
        XCTAssertEqual(transport.requests.filter { $0.url?.path.contains("agents/send") == true }.count, 2)
    }

    func testDeliveredMessagesLeaveWhenTheConversationShowsThem() async {
        let (client, transport) = JarvisAPI.mocked()
        transport.route("/api/coding/agents/send", json: ["delivery": ["state": "sent"]])
        let store = AgentsStore(api: AgentsAPI(api: client), topics: BridgeTopics())
        await store.send("continue", to: "claude|s1", prompts: ["continue"])
        store.reconcileOutgoing(ckey: "claude|s1", prompts: ["continue"])
        XCTAssertEqual(store.outgoing(for: "claude|s1").count, 1)
        store.reconcileOutgoing(ckey: "claude|s1", prompts: ["continue", "continue"])
        XCTAssertTrue(store.outgoing(for: "claude|s1").isEmpty)
    }

    func testAMessageTheChatShowsBeforeTheSendAnswersLeaves() async throws {
        let (client, transport) = JarvisAPI.mocked()
        let answer = DispatchSemaphore(value: 0)
        transport.route("/api/coding/agents/send") { _ in
            answer.wait()
            return MockTransport.Reply(body: try! JSONSerialization.data(
                withJSONObject: ["delivery": ["state": "sent"]]))
        }
        let store = AgentsStore(api: AgentsAPI(api: client), topics: BridgeTopics())
        let sending = Task { await store.send("What’s ur name", to: "claude|s1", prompts: ["Hi"]) }
        while store.outgoing(for: "claude|s1").isEmpty { await Task.yield() }
        // A server session's hooks put it in the chat before the send call answers.
        store.reconcileOutgoing(ckey: "claude|s1", prompts: ["Hi", "What’s ur name"])
        answer.signal()
        await sending.value
        XCTAssertTrue(store.outgoing(for: "claude|s1").isEmpty, "the chat already shows it")
    }

    func testTheWaitingCountMatchesTheList() async {
        let (client, transport) = JarvisAPI.mocked()
        transport.route("/api/coding/agents/list", json: listJSON(
            needs: [conv(state: "approval")], sessions: [conv("claude|s9", key: "d1|claude|s9")]))
        transport.route("/api/coding/permission/pending",
                        json: ["pending": [approval(), approval("r2", key: "gone|claude|zz")]])
        let store = AgentsStore(api: AgentsAPI(api: client), topics: BridgeTopics())
        await store.refresh()
        // One row waits (its card) and one card has no row.
        XCTAssertEqual(store.orphanRequests.map(\.requestId), ["r2"])
        XCTAssertEqual(store.waitingCount, 2)
    }

    // MARK: notifications + deep links

    func testDeepLinkParsesAgents() {
        let url = URL(string: "jarviscopilot://agents?key=d1%7Cclaude%7Cs1")!
        XCTAssertEqual(AppDeepLink.parse(url), .agents(key: "d1|claude|s1"))
        XCTAssertEqual(AppDeepLink.parse(URL(string: "jarviscopilot://agents")!), .agents(key: nil))
    }

    func testDeepLinkParsesTheRecap() {
        XCTAssertEqual(AppDeepLink.parse(URL(string: "jarviscopilot://agents/recap")!), .agentsRecap)
    }

    func testTheMondayRecapNotificationOpensTheRecap() {
        let a = NotificationAction.decode(actionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier",
                                          userInfo: ["jarviscopilot": ["type": "agents_recap"]])
        XCTAssertEqual(a.verdict, .open)
        XCTAssertEqual(a.kind, "agents_recap")
    }

    func testRecapDecodesAndFormats() {
        let r = AgentRecap(json: [
            "minutes": 135, "sessions": 4, "files": 12, "added": 340, "removed": 51, "commands": 30,
            "approved": 6, "denied": 1, "answered": 2,
            "top_agent": ["agent": "codex", "minutes": 90], "top_project": ["project": "storefront", "minutes": 80],
            "busiest_day": ["date": "2026-10-06", "weekday": "Tuesday", "minutes": 70],
            "longest_session": ["key": "k", "project": "api", "agent": "claude", "minutes": 50],
            "summary": "2h 15m of agent time · 4 sessions",
        ])
        XCTAssertEqual(r.time, "2h 15m")
        XCTAssertEqual(r.topAgent, "Codex")
        XCTAssertEqual(r.topProject, "storefront")
        XCTAssertEqual(r.busiestDay, "Tuesday")
        XCTAssertEqual(r.longest, "api · 50m")
        XCTAssertFalse(r.isEmpty)
        XCTAssertTrue(AgentRecap(json: [:]).isEmpty)
        XCTAssertEqual(AgentRecap.duration(45), "45m")
        XCTAssertEqual(AgentRecap.duration(120), "2h")
    }

    func testRecapFetchSendsTheTimezoneAndTheRequestIsLatched() async throws {
        let (client, transport) = JarvisAPI.mocked()
        transport.route("/api/coding/agents/recap", json: ["minutes": 60, "sessions": 1])
        let api = AgentsAPI(api: client)
        let r = try await api.recap(days: 7, timeZone: TimeZone(secondsFromGMT: -5 * 3600)!)
        XCTAssertEqual(r.minutes, 60)
        let url = transport.requests.last?.url?.absoluteString ?? ""
        XCTAssertTrue(url.contains("days=7") && url.contains("tz=-300"), url)
        let store = AgentsStore(api: api, topics: BridgeTopics())
        store.requestRecap()
        XCTAssertTrue(store.consumeRecap())
        XCTAssertFalse(store.consumeRecap())
    }

    func testNotificationDecodesAlwaysAndTheAgentKey() {
        let a = NotificationAction.decode(actionIdentifier: NotificationAction.Identifier.always,
                                          userInfo: ["jarviscopilot": ["request_id": "r1", "agent_key": "k1"]])
        XCTAssertEqual(a.verdict, .always)
        XCTAssertEqual(a.requestID, "r1")
        XCTAssertEqual(a.agentKey, "k1")
    }

    func testApprovingFromANotificationNeedsTheUnlockedPhone() {
        let cats = NotificationCategories.all()
        let approval = cats.first { $0.identifier == NotificationCategories.permissionApproval }!
        let byId = Dictionary(uniqueKeysWithValues: approval.actions.map { ($0.identifier, $0) })
        XCTAssertTrue(byId[NotificationAction.Identifier.approve]!.options.contains(.authenticationRequired))
        XCTAssertTrue(byId[NotificationAction.Identifier.always]!.options.contains(.authenticationRequired))
        XCTAssertTrue(cats.contains { $0.identifier == NotificationCategories.agentQuestion })
    }

    func testOpenRequestIsLatchedUntilTaken() {
        let (client, _) = JarvisAPI.mocked()
        let store = AgentsStore(api: AgentsAPI(api: client), topics: BridgeTopics())
        store.requestOpen("k1")
        XCTAssertEqual(store.consumeOpen(), "k1")
        XCTAssertNil(store.consumeOpen())
    }

    func testLiveActivityStateDecodesAnOldPayload() throws {
        let json = Data(#"{"state":"idle","mode":"coding","sessions":["app\u001fworking"],"sessionTotal":1}"#.utf8)
        let st = try JSONDecoder().decode(JarvisActivityAttributes.ContentState.self, from: json)
        XCTAssertEqual(st.mode, "coding")
        XCTAssertEqual(st.sessionTotal, 1)
        XCTAssertEqual(st.leadAgent, "")
        XCTAssertEqual(st.usage5, -1)
        XCTAssertEqual(st.designId, "")
    }

    func testSpotlightIdentifierRoundTripsTheKey() {
        let id = AgentsSpotlight.identifier(key: "d1|claude|s1", startedAt: Date(timeIntervalSince1970: 1781000000))
        XCTAssertEqual(AgentsSpotlight.key(from: id), "d1|claude|s1")
        XCTAssertNil(AgentsSpotlight.key(from: "chat|123"))
    }

    func testDecisionLogKeepsTheNewestFirst() {
        let defaults = UserDefaults(suiteName: "agents-log-\(UUID().uuidString)")!
        let req = AgentRequest.from(approval())!
        AgentsDecisionLog.record(req, decision: "allow", at: Date(timeIntervalSince1970: 1), defaults: defaults)
        AgentsDecisionLog.record(req, decision: "deny", at: Date(timeIntervalSince1970: 2), defaults: defaults)
        let all = AgentsDecisionLog.all(defaults: defaults)
        XCTAssertEqual(all.map(\.decision), ["deny", "allow"])
        XCTAssertEqual(all.first?.summary, "rm -rf build")
    }

    func testSiriSummaryPutsWhatWaitsFirst() {
        var waiting = item
        waiting["state"] = "approval"
        waiting["project"] = "api"
        let overview = AgentsAPI.Overview(sessions: [AgentSessionItem(json: waiting), AgentSessionItem(json: item)],
                                          requests: [], usage: nil)
        let text = AgentsStatusIntent.summary(overview)
        XCTAssertTrue(text.hasPrefix("Claude Code in api needs your approval."), text)
        XCTAssertTrue(text.contains("working in app: Bash: npm test"), text)
        XCTAssertEqual(AgentsStatusIntent.summary(AgentsAPI.Overview(sessions: [], requests: [], usage: nil)),
                       "No coding agents are running.")
    }
}

import XCTest
@testable import JarvisCopilot

/// The Agents tab: hook-tracked sessions pushed on the `agents` topic, the
/// approvals / questions waiting on you, and decisions sent back by fingerprint.
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

    // MARK: store

    func testRefreshLoadsSessionsRequestsAndUsage() async {
        let (client, transport) = JarvisAPI.mocked()
        transport.route("/api/coding/agents/sessions", json: [
            "sessions": [item], "pending": [approval()],
            "usage": ["five_hour": ["used_percentage": 10, "resets_at": 4102444800.0]],
        ])
        let store = AgentsStore(api: AgentsAPI(api: client), topics: BridgeTopics())
        await store.refresh()
        XCTAssertEqual(store.sessions.map(\.key), ["d1|claude|s1"])
        XCTAssertEqual(store.requests.map(\.requestId), ["r1"])
        XCTAssertEqual(store.request(for: store.sessions[0])?.requestId, "r1")
        XCTAssertEqual(store.usage?.fiveHour?.percent, 10)
        XCTAssertEqual(store.waitingCount, 1)
    }

    func testTopicPushUpdatesSessionsWithoutFetching() async {
        let (client, transport) = JarvisAPI.mocked()
        let store = AgentsStore(api: AgentsAPI(api: client), topics: BridgeTopics())
        var idle = item
        idle["state"] = "finished"
        idle["key"] = "d1|claude|s2"
        idle["last_event_at"] = 1781000000.0
        store.apply(["sessions": [idle, item]])
        // Sorted by urgency: what's working comes before what finished.
        XCTAssertEqual(store.sessions.map(\.state), [.working, .finished])
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testANewPendingFingerprintFetchesTheRequests() async {
        let (client, transport) = JarvisAPI.mocked()
        transport.route("/api/coding/agents/sessions", json: ["sessions": [], "pending": [approval()]])
        let store = AgentsStore(api: AgentsAPI(api: client), topics: BridgeTopics())
        var waiting = item
        waiting["state"] = "approval"
        waiting["pending"] = ["kind": "approval", "fingerprint": "fp-r1", "summary": "Bash: rm -rf build"]
        store.apply(["sessions": [waiting]])
        let deadline = Date().addingTimeInterval(2)
        while store.requests.isEmpty && Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(store.requests.map(\.fingerprint), ["fp-r1"])
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testDecidePostsTheVerdictAndDropsTheCard() async {
        let (client, transport) = JarvisAPI.mocked()
        transport.route("/api/coding/agents/sessions", json: ["sessions": [item], "pending": [approval()]])
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

    func testVisibilityWantsAndDropsTheTopic() {
        let (client, _) = JarvisAPI.mocked()
        let topics = BridgeTopics()
        var frames: [[String: Any]] = []
        topics.send = { frames.append($0) }
        let store = AgentsStore(api: AgentsAPI(api: client), topics: topics)
        store.setVisible(true)
        XCTAssertTrue(topics.isWanted("agents"))
        store.setVisible(false)
        XCTAssertFalse(topics.isWanted("agents"))
        XCTAssertEqual(frames.count, 2)
    }

    func testInstructionPostsKeyAndText() async throws {
        let (client, transport) = JarvisAPI.mocked()
        transport.route("/api/coding/agents/instruction", json: ["ok": true, "via": "resume"])
        let via = try await AgentsAPI(api: client).sendInstruction(key: "k1", text: "go on")
        XCTAssertEqual(via, "resume")
        XCTAssertEqual(transport.lastBody()["key"] as? String, "k1")
    }

    // MARK: notifications + deep links

    func testDeepLinkParsesAgents() {
        let url = URL(string: "jarviscopilot://agents?key=d1%7Cclaude%7Cs1")!
        XCTAssertEqual(AppDeepLink.parse(url), .agents(key: "d1|claude|s1"))
        XCTAssertEqual(AppDeepLink.parse(URL(string: "jarviscopilot://agents")!), .agents(key: nil))
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

import XCTest
import UserNotifications
@testable import JarvisCopilot

/// The merged Agents tab: one `/agents/list` payload (a Mac-asleep card, what
/// needs you, two projects) decoded and laid out, the delivery states a sent
/// message reads as, why a session can't take one, and the Mac-asleep push.
@MainActor
final class AgentsListTests: XCTestCase {

    /// `GET /api/coding/agents/list`, the way `agents_core.list_payload` builds it.
    static let fixture = #"""
    {
      "card": {
        "device_id": "mac-1", "device_name": "MacBook", "kind": "sleep", "since": 1781000000,
        "sessions": [
          {"ckey": "claude|s-car", "title": "Fix CarPlay mic hand-off", "project": "jarvis-copilot", "was": "working", "agent": "claude"},
          {"ckey": "claude|s-router", "title": "Refactor order router", "project": "IntelliStock", "was": "approval", "agent": "claude"}
        ]
      },
      "needs_you": [
        {"ckey": "claude|s-old", "key": "server|claude|s-old", "agent": "claude", "session_id": "s-old",
         "title": "Rotate the API keys", "project_id": "p-api", "project": "api", "cwd": "/srv/api",
         "owner": "server", "owner_name": "Server", "status": "live", "state": "question",
         "pending": {"kind": "question", "fingerprint": "fp-old",
                     "questions": [{"question": "Which keys?", "options": [{"label": "All"}]}]},
         "last_event_at": 1781000100, "can_send": true},
        {"ckey": "claude|s-push", "key": "server|claude|s-push", "agent": "claude", "session_id": "s-push",
         "title": "Migrate push tokens", "project_id": "p-jc", "project": "jarvis-copilot", "cwd": "/srv/jc",
         "owner": "server", "owner_name": "Server", "status": "live", "state": "approval",
         "pending": {"kind": "approval", "tool": "Bash", "summary": "Bash: git push origin main", "fingerprint": "fp-push"},
         "last_event_at": 1781000500, "can_send": true}
      ],
      "projects": [
        {"id": "p-jc", "name": "jarvis-copilot", "sessions": [
          {"ckey": "claude|s-spec", "key": "server|claude|s-spec", "agent": "claude", "session_id": "s-spec",
           "title": "Agents tab merge spec", "project_id": "p-jc", "project": "jarvis-copilot", "cwd": "/srv/jc",
           "owner": "server", "owner_name": "Server", "status": "live", "state": "working",
           "step": "Edit: /srv/jc/webui/api/coding_routes.py", "last_event_at": 1781000600,
           "can_send": true, "can_terminal": true},
          {"ckey": "claude|s-car", "key": "mac-1|claude|s-car", "agent": "claude", "session_id": "s-car",
           "title": "Fix CarPlay mic hand-off", "project_id": "p-jc", "project": "jarvis-copilot",
           "cwd": "/Users/p/code/jarvis-copilot", "owner": "mac-1", "owner_name": "MacBook",
           "status": "asleep", "state": "asleep", "last_event_at": 1781000000, "terminal_app": "vscode",
           "can_send": false, "can_continue_server": true}
        ]},
        {"id": "p-is", "name": "IntelliStock", "sessions": [
          {"ckey": "codex|s-router", "agent": "codex", "session_id": "s-router", "title": "Refactor order router",
           "project_id": "p-is", "project": "IntelliStock", "cwd": "/Users/p/code/IntelliStock",
           "owner": "mac-1", "owner_name": "MacBook", "status": "live", "state": "idle",
           "terminal_app": "vscode", "last_event_at": 1780990000, "can_send": false},
          {"ckey": "claude|s-done", "agent": "claude", "session_id": "s-done", "title": "Tidy the README",
           "project_id": "p-is", "project": "IntelliStock", "cwd": "/srv/is",
           "owner": "server", "owner_name": "Server", "status": "ended", "state": "ended",
           "last_event_at": 1780980000, "can_send": false, "can_resume": true}
        ]}
      ],
      "usage": {"five_hour": {"used_percentage": 38, "resets_at": 4102444800}},
      "usage_codex": null,
      "ts": 1781000700
    }
    """#

    static func fixtureJSON() -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(fixture.utf8))) as? [String: Any] ?? [:]
    }

    private var list: AgentsList { AgentsList(json: Self.fixtureJSON()) }

    // MARK: decoding

    func testTheCardIsVisibleWithItsSessions() throws {
        let card = try XCTUnwrap(list.card)
        XCTAssertEqual(card.kind, .sleep)
        XCTAssertEqual(card.deviceId, "mac-1")
        XCTAssertEqual(card.sessions.count, 2)
        XCTAssertEqual(card.sessions.map(\.ckey), ["claude|s-car", "claude|s-router"])
        XCTAssertEqual(AgentsListLayout.cardTitle(card), "MacBook went to sleep")
        XCTAssertEqual(card.since, Date(timeIntervalSince1970: 1781000000))
    }

    func testACardWithNothingLeftIsHidden() {
        var json = Self.fixtureJSON()
        json["card"] = ["device_id": "mac-1", "device_name": "MacBook", "kind": "offline", "sessions": [] as [Any]]
        XCTAssertNil(AgentsList(json: json).card)
        json["card"] = NSNull()
        XCTAssertNil(AgentsList(json: json).card)
    }

    func testNeedsYouIsFlatAndNewestFirst() {
        let needs = AgentsListLayout.needsYou(list)
        XCTAssertEqual(needs.map(\.ckey), ["claude|s-push", "claude|s-old"])
        XCTAssertTrue(needs.allSatisfy(\.waitsOnYou))
        XCTAssertEqual(needs[0].pending?.fingerprint, "fp-push")
        XCTAssertTrue(needs[1].pending?.isQuestion == true)
    }

    func testSessionsAreGroupedByProject() {
        XCTAssertEqual(list.projects.map(\.name), ["jarvis-copilot", "IntelliStock"])
        XCTAssertEqual(list.projects.map(\.id), ["p-jc", "p-is"])
        XCTAssertEqual(list.projects.map(\.sessions.count), [2, 2])
        XCTAssertEqual(list.all.count, 6)
        XCTAssertEqual(list.conv("claude|s-car")?.status, .asleep)
        XCTAssertEqual(list.conv("claude|s-car")?.state, .idle, "a paused session has no hook state")
        XCTAssertEqual(list.conv("claude|s-spec")?.state, .working)
        XCTAssertEqual(list.usage?.fiveHour?.percent, 38)
        XCTAssertNil(list.codexUsage)
    }

    func testAProjectWithAWaitingSessionOpensOnItsOwn() {
        let needs = AgentsListLayout.needsYou(list)
        let jc = list.projects[0], other = list.projects[1]
        let collapsed: Set<String> = ["p-jc", "p-is"]
        // "Migrate push tokens" (under Needs you) belongs to jarvis-copilot.
        XCTAssertTrue(AgentsListLayout.hasWaiting(jc, needsYou: needs))
        XCTAssertTrue(AgentsListLayout.isExpanded(jc, collapsed: collapsed, needsYou: needs))
        XCTAssertFalse(AgentsListLayout.hasWaiting(other, needsYou: needs))
        XCTAssertFalse(AgentsListLayout.isExpanded(other, collapsed: collapsed, needsYou: needs))
        XCTAssertTrue(AgentsListLayout.isExpanded(other, collapsed: [], needsYou: needs), "open unless collapsed")
    }

    func testTheCollapsedSetRoundTrips() {
        let set: Set<String> = ["p-jc", "name:scratch"]
        XCTAssertEqual(AgentsListLayout.collapsed(from: AgentsListLayout.encode(set)), set)
        XCTAssertTrue(AgentsListLayout.collapsed(from: "").isEmpty)
    }

    // MARK: rows

    func testRowsSayWhereTheyRun() throws {
        let spec = try XCTUnwrap(list.conv("claude|s-spec"))
        let car = try XCTUnwrap(list.conv("claude|s-car"))
        let push = try XCTUnwrap(list.conv("claude|s-push"))
        XCTAssertEqual(AgentsListLayout.subtitle(spec, showsProject: false), "Claude Code · Server")
        XCTAssertEqual(AgentsListLayout.subtitle(car, showsProject: false), "Claude Code · MacBook (asleep)")
        XCTAssertEqual(AgentsListLayout.subtitle(push, showsProject: true),
                       "jarvis-copilot · Claude Code · Server")
        XCTAssertEqual(AgentsListLayout.status(car, request: nil), .paused)
        XCTAssertEqual(AgentsListLayout.status(push, request: nil), .waiting)
        XCTAssertEqual(AgentsListLayout.status(try XCTUnwrap(list.conv("claude|s-done")), request: nil), .ended)
        XCTAssertNil(AgentsListLayout.detail(car, request: nil), "the moon says it")
        XCTAssertEqual(AgentsListLayout.detail(push, request: nil),
                       AgentRowDetail(text: "Wants to run git push origin main", tone: .waiting))
        XCTAssertEqual(AgentsListLayout.detail(spec, request: nil)?.tone, .working)
    }

    func testCardRowsSayWhatEachWasDoing() throws {
        let card = try XCTUnwrap(list.card)
        XCTAssertEqual(card.sessions.map(AgentsListLayout.cardLine),
                       ["jarvis-copilot · was working", "IntelliStock · was waiting on you"])
        XCTAssertEqual(AgentsListLayout.was("idle"), "idle")
        XCTAssertEqual(AgentsListLayout.continueAllTitle(card), "Continue both on server")
    }

    func testCardsFindTheirRowsByTrackerKey() throws {
        let card = AgentRequest.from(["request_id": "r1", "fingerprint": "fp-x", "kind": "permission",
                                      "tool": "Bash", "key": "server|claude|s-push"])!
        let orphan = AgentRequest.from(["request_id": "r2", "fingerprint": "fp-y", "kind": "permission",
                                        "tool": "Bash", "key": "mac-9|claude|elsewhere"])!
        let push = try XCTUnwrap(list.conv("claude|s-push"))
        XCTAssertEqual(AgentsListLayout.request(for: push, in: [orphan, card])?.requestId, "r1")
        XCTAssertEqual(AgentsListLayout.orphans([card, orphan], list: list).map(\.requestId), ["r2"])
        XCTAssertEqual(AgentsListLayout.waitingCount(list, requests: [card, orphan]), 3)
        XCTAssertEqual(AgentsListLayout.ckey(fromKey: "mac-1|claude|s-car"), "claude|s-car")
        XCTAssertEqual(AgentsListLayout.ckey(fromKey: "claude|s-car"), "claude|s-car")
    }

    // MARK: sending

    func testDeliveryStatesReadAsWords() {
        XCTAssertEqual(AgentOutgoing.caption(.sending), "Sending…")
        XCTAssertEqual(AgentOutgoing.caption(.sent), "Sent")
        XCTAssertEqual(AgentOutgoing.caption(.delivered), "Delivered")
        XCTAssertEqual(AgentOutgoing.caption(.queued), "Queued — will send when the turn ends")
        XCTAssertEqual(AgentOutgoing.caption(.failed(.from(reason: "owner_offline"))),
                       "Failed: The Mac running it is asleep or offline.")
        XCTAssertEqual(AgentOutgoing.caption(.failed(.from(reason: "Nobody's home."))), "Failed: Nobody's home.")
    }

    func testWhyASessionCantTakeAMessage() throws {
        XCTAssertEqual(AgentsListLayout.cantSendReason(try XCTUnwrap(list.conv("claude|s-car"))),
                       "MacBook is asleep.")
        XCTAssertEqual(AgentsListLayout.cantSendReason(try XCTUnwrap(list.conv("claude|s-done"))),
                       "This session has ended.")
        let idle = try XCTUnwrap(list.conv("codex|s-router"))
        XCTAssertTrue(AgentsListLayout.cantSendReason(idle)?.hasPrefix("Can’t send here: it’s idle in VS Code") == true)
        XCTAssertNil(AgentsListLayout.cantSendReason(try XCTUnwrap(list.conv("claude|s-spec"))))
    }

    // MARK: store

    func testThePushReplacesTheListAndOpensBySessionKey() {
        let (client, transport) = JarvisAPI.mocked()
        transport.route("/api/coding/permission/pending", json: ["pending": [] as [Any]])
        let store = AgentsStore(api: AgentsAPI(api: client), topics: BridgeTopics())
        store.apply(Self.fixtureJSON())
        XCTAssertEqual(store.card?.sessions.count, 2)
        XCTAssertEqual(store.needsYou.count, 2)
        XCTAssertEqual(store.waitingCount, 2)
        XCTAssertEqual(store.resolveCkey("mac-1|claude|s-car"), "claude|s-car")
        XCTAssertEqual(store.resolveCkey("server|claude|s-spec"), "claude|s-spec")
    }

    func testContinueAllSendsTheCardsSessions() async {
        let (client, transport) = JarvisAPI.mocked()
        transport.route("/api/coding/agents/continue", json: ["results": [
            "claude|s-car": ["ok": true], "claude|s-router": ["ok": true]]])
        transport.route("/api/coding/agents/list", json: Self.fixtureJSON())
        transport.route("/api/coding/permission/pending", json: ["pending": [] as [Any]])
        let store = AgentsStore(api: AgentsAPI(api: client), topics: BridgeTopics())
        let outcome = await store.continueOnServer(["claude|s-car", "claude|s-router"])
        XCTAssertEqual(outcome, .done)
        let sent = transport.requests.first { $0.url?.path.hasSuffix("/agents/continue") == true }
        let body = (sent?.httpBody).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        XCTAssertEqual(body?["ckeys"] as? [String], ["claude|s-car", "claude|s-router"])
        XCTAssertEqual(body?["to"] as? String, "server")
        XCTAssertNil(body?["confirm_offline"])
        XCTAssertTrue(store.busy.isEmpty)
    }

    func testAnOfflineMacAsksBeforeMoving() async {
        let (client, transport) = JarvisAPI.mocked()
        transport.route("/api/coding/agents/continue", json: ["results": [
            "claude|s-car": ["ok": false, "reason": "confirm_offline", "error": "It may still be running."]]])
        transport.route("/api/coding/agents/list", json: Self.fixtureJSON())
        transport.route("/api/coding/permission/pending", json: ["pending": [] as [Any]])
        let store = AgentsStore(api: AgentsAPI(api: client), topics: BridgeTopics())
        let outcome = await store.continueOnServer(["claude|s-car"])
        XCTAssertEqual(outcome, .needsConfirmation(["claude|s-car"]))
        XCTAssertTrue(AgentsListLayout.offlineWarning("MacBook", count: 1).contains("may still be running"))
    }

    func testTheTranscriptComesFromTheConversationsMessages() async {
        let (client, transport) = JarvisAPI.mocked()
        transport.route("/api/coding/agents/messages", json: [
            "total": 2, "start": 0, "messages": [
                ["i": 0, "role": "user", "text": "fix it"],
                ["i": 1, "role": "assistant", "text": "Done."],
            ]])
        let model = AgentSessionModel(ckey: "claude|s-spec", agents: AgentsAPI(api: client))
        await model.load(key: "server|claude|s-spec")
        XCTAssertEqual(model.choice(), .transcript)
        XCTAssertEqual(AgentConversation.prompts(model.items(working: false)), ["fix it"])
        let url = transport.requests.first?.url?.absoluteString ?? ""
        XCTAssertTrue(url.contains("ckey=claude%7Cs-spec") || url.contains("ckey=claude|s-spec"), url)
        XCTAssertTrue(url.contains("limit=40"), url)
    }

    // MARK: terminal + push

    func testTheTerminalPageCarriesItsId() {
        let url = AgentTerminalView.pageURL(terminalId: "agent-abc", base: URL(string: "https://jarvis.test"))
        XCTAssertEqual(url?.absoluteString, "https://jarvis.test/static/agents_terminal.html?terminal_id=agent-abc")
        XCTAssertNil(AgentTerminalView.pageURL(terminalId: "x", base: nil))
    }

    func testTheMacAsleepPushOffersContinueAllBehindUnlock() throws {
        let cats = NotificationCategories.all()
        let slept = try XCTUnwrap(cats.first { $0.identifier == "MAC_SLEPT" })
        XCTAssertEqual(slept.actions.map(\.identifier), ["CONTINUE_ALL"])
        XCTAssertEqual(slept.actions.first?.title, "Continue all on server")
        XCTAssertTrue(slept.actions[0].options.contains(.authenticationRequired))
        XCTAssertFalse(slept.actions[0].options.contains(.foreground))
        let offline = try XCTUnwrap(cats.first { $0.identifier == "MAC_OFFLINE" })
        XCTAssertTrue(offline.actions.isEmpty, "an offline Mac may still run them: ask in the app")
        XCTAssertTrue(cats.contains { $0.identifier == NotificationCategories.permissionApproval })
    }

    func testTheMacAsleepPushDecodesAndOpensTheAgentsTab() async {
        let info: [AnyHashable: Any] = ["jarviscopilot": ["kind": "mac_paused", "device_id": "mac-1"]]
        let action = NotificationAction.decode(actionIdentifier: "CONTINUE_ALL", userInfo: info)
        XCTAssertEqual(action.verdict, .continueAll)
        let tap = NotificationAction.decode(actionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier",
                                            userInfo: info)
        XCTAssertEqual(tap.verdict, .open)
        XCTAssertEqual(tap.kind, "mac_paused")

        let (client, _) = JarvisAPI.mocked()
        let router = AppRouter()
        let handler = NotificationActionHandler(coding: CodingSessionsAPI(api: client),
                                                router: AppDeepLinkRouter(router: router, targets: DeepLinkTargets()),
                                                pending: PendingActions(), notifier: MockNotifier())
        await handler.handle(tap)
        XCTAssertEqual(router.selectedTab, .agents)
    }

    func testContinueAllFromThePushMovesTheCardsSessions() async {
        let (client, transport) = JarvisAPI.mocked()
        transport.route("/api/coding/agents/list", json: Self.fixtureJSON())
        transport.route("/api/coding/agents/continue", json: ["results": [
            "claude|s-car": ["ok": true], "claude|s-router": ["ok": true]]])
        let ok = await AgentsPushActions.continueAllOnServer(api: AgentsAPI(api: client))
        XCTAssertTrue(ok)
        let sent = transport.requests.first { $0.url?.path.hasSuffix("/agents/continue") == true }
        let body = (sent?.httpBody).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        XCTAssertEqual(body?["ckeys"] as? [String], ["claude|s-car", "claude|s-router"])
        XCTAssertEqual(body?["to"] as? String, "server")
    }
}

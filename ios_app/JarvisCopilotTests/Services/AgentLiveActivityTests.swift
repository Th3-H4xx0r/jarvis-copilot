import AppIntents
import Foundation
import UIKit
import XCTest
@testable import JarvisCopilot

/// Per-agent Live Activities: the logo mapping, the content-state wire format, the
/// settings, the start/update/end plan, the manager's token + dismissal rules, and
/// the Jarvis activity giving up the coding fleet while they're on.
@MainActor
final class AgentLiveActivityTests: XCTestCase {

    typealias CS = AgentActivityAttributes.ContentState

    // MARK: - Brand

    func testClaudeCodeAndClaudeDesktopShareTheClaudeActivity() {
        XCTAssertEqual(AgentBrand.group(of: "claude-desktop"), "claude")
        XCTAssertEqual(AgentBrand.group(of: "Codex"), "codex")
        XCTAssertNil(AgentBrand.group(of: "something-new"))
    }

    func testEachAgentWearsItsOwnLogoAndJarvisKeepsItsOrb() {
        XCTAssertEqual(AgentBrand.mark(for: "claude"), .asset("agent_claude"))
        XCTAssertEqual(AgentBrand.mark(for: "claude-desktop"), .asset("agent_claude"))
        XCTAssertEqual(AgentBrand.mark(for: "codex"), .asset("agent_openai"))
        XCTAssertEqual(AgentBrand.mark(for: "jarvis"), .orb)
        let marks = AgentBrand.all.map(AgentBrand.mark(for:))
        XCTAssertEqual(Set(marks.map { "\($0)" }).count, marks.count, "no two agents look alike")
    }

    func testEveryLogoAssetShipsInTheBundle() {
        for agent in AgentBrand.all {
            guard case .asset(let name) = AgentBrand.mark(for: agent) else { continue }
            XCTAssertNotNil(UIImage(named: name), "\(name) is missing from AgentLogos.xcassets")
        }
    }

    func testEveryAgentHasATitle() {
        for agent in AgentBrand.all { XCTAssertFalse(AgentBrand.title(for: agent).isEmpty) }
    }

    func testATapOpensTheLeadSessionInTheAgentsTab() {
        var st = CS()
        XCTAssertEqual(jcAgentWidgetURL(st).absoluteString, "jarviscopilot://agents")
        st.key = "d1|claude|abc"
        XCTAssertEqual(jcAgentWidgetURL(st).absoluteString, "jarviscopilot://agents?key=d1%7Cclaude%7Cabc")
        st.key = "row:42"
        XCTAssertEqual(jcAgentWidgetURL(st).absoluteString, "jarviscopilot://agents")
    }

    // MARK: - Content state

    func testAPayloadMissingKeysStillDecodes() throws {
        let data = Data(#"{"count": 2, "state": "approval"}"#.utf8)
        let st = try JSONDecoder().decode(CS.self, from: data)
        XCTAssertEqual(st.count, 2)
        XCTAssertEqual(st.state, "approval")
        XCTAssertTrue(st.actions, "an absent setting keeps the buttons on")
        XCTAssertTrue(st.waitsOnYou)
    }

    func testThePushToStartAttributesDecode() throws {
        let attrs = try JSONDecoder().decode(AgentActivityAttributes.self,
                                             from: Data(#"{"agent": "codex"}"#.utf8))
        XCTAssertEqual(attrs.agent, "codex")
    }

    func testAFullStateStaysFarUnderTheActivityKitBudget() throws {
        let st = CS(count: 50, waiting: 50, working: 0, name: "Claude Desktop",
                    project: String(repeating: "p", count: 22),
                    state: "approval", step: String(repeating: "s", count: 60),
                    fingerprint: String(repeating: "f", count: 64), kind: "approval",
                    since: 1_700_000_000, key: String(repeating: "k", count: 120),
                    bar: Array(repeating: "p", count: 8).joined(separator: ","),
                    actions: true, last: 1_700_000_000)
        XCTAssertLessThan(try JSONEncoder().encode(st).count, 1024)
    }

    func testButtonsOnlyForAnApprovalSomethingHolds() {
        var st = CS(state: "approval", fingerprint: "fp", kind: "approval")
        XCTAssertTrue(st.showsButtons)
        st.actions = false
        XCTAssertFalse(st.showsButtons, "the Lock Screen setting turns them off")
        st = CS(state: "approval", fingerprint: "", kind: "approval")
        XCTAssertFalse(st.showsButtons, "nothing holds the request: a tap couldn't reach it")
        st = CS(state: "question", fingerprint: "fp", kind: "question")
        XCTAssertFalse(st.showsButtons)
    }

    func testWaitingOnYouIsTheMostRelevantForTheIsland() {
        XCTAssertGreaterThan(CS(state: "approval").relevance, CS(state: "working").relevance)
        XCTAssertGreaterThan(CS(state: "working").relevance, CS(state: "idle").relevance)
    }

    // MARK: - Settings

    func testSettingsDefaultToOnForEveryAgent() {
        let s = AgentLiveSettings(json: nil)
        XCTAssertTrue(s.enabled)
        XCTAssertTrue(s.actions)
        XCTAssertEqual(s.idleMinutes, 30)
        XCTAssertTrue(AgentBrand.all.allSatisfy(s.isOn))
    }

    func testSettingsTakeOnlyRealBoolsAndKnownIdleChoices() {
        let s = AgentLiveSettings(json: ["enabled": 0, "actions": false, "idle_minutes": 45,
                                         "agents": ["codex": false, "gemini": "no"]])
        XCTAssertTrue(s.enabled, "a number is not a switch")
        XCTAssertFalse(s.actions)
        XCTAssertEqual(s.idleMinutes, 30)
        XCTAssertFalse(s.isOn("codex"))
        XCTAssertTrue(s.isOn("gemini"))
        XCTAssertEqual(AgentLiveSettings(json: ["idle_minutes": 10]).idleMinutes, 10)
    }

    func testThePayloadRoundTrips() {
        var s = AgentLiveSettings()
        s.enabled = false
        s.set("cursor", false)
        s.idleMinutes = 60
        XCTAssertEqual(AgentLiveSettings(json: s.payload), s)
    }

    // MARK: - Plan

    private func target(_ agent: String, episode: String = "e1", state: String = "working",
                        count: Int = 1) -> AgentLiveTarget {
        AgentLiveTarget(agent: agent, episode: episode, state: CS(count: count, state: state))
    }

    func testANewAgentStartsItsActivity() {
        let plan = AgentActivityPlan.reconcile(running: [:], desired: [target("claude")], dismissed: [:])
        XCTAssertEqual(plan, [.start(agent: "claude", state: CS(count: 1, state: "working"))])
    }

    func testAChangedStateUpdatesAndAnUnchangedOneIsLeftAlone() {
        let running = ["claude": CS(count: 1, state: "working")]
        XCTAssertEqual(AgentActivityPlan.reconcile(running: running, desired: [target("claude")],
                                                   dismissed: [:]), [])
        XCTAssertEqual(AgentActivityPlan.reconcile(running: running,
                                                   desired: [target("claude", state: "approval")],
                                                   dismissed: [:]),
                       [.update(agent: "claude", state: CS(count: 1, state: "approval"), alert: true)])
    }

    func testAnAgentNoLongerWantedEnds() {
        let plan = AgentActivityPlan.reconcile(running: ["codex": CS()], desired: [], dismissed: [:])
        XCTAssertEqual(plan, [.end(agent: "codex")])
    }

    func testADismissedActivityStaysAwayUntilTheNextEpisode() {
        XCTAssertEqual(AgentActivityPlan.reconcile(running: [:], desired: [target("claude", episode: "e1")],
                                                   dismissed: ["claude": "e1"]), [])
        XCTAssertEqual(AgentActivityPlan.reconcile(running: [:], desired: [target("claude", episode: "e2")],
                                                   dismissed: ["claude": "e1"]).count, 1)
    }

    // MARK: - Snapshot

    func testTheServerSnapshotParses() {
        let snap = AgentLiveSnapshot(json: [
            "settings": ["enabled": true, "idle_minutes": 10],
            "activities": [["agent": "codex", "episode": "codex-1",
                            "state": ["count": 3, "state": "question", "kind": "question"]],
                           ["agent": "nope", "episode": "x", "state": [:]],
                           "junk"],
        ])
        XCTAssertEqual(snap.settings.idleMinutes, 10)
        XCTAssertEqual(snap.targets.map(\.agent), ["codex"], "an unknown agent can't be drawn")
        XCTAssertEqual(snap.target("codex")?.state.count, 3)
        XCTAssertEqual(snap.target("codex")?.episode, "codex-1")
    }

    // MARK: - Manager

    private func makeManager(paired: Bool = true)
    -> (AgentActivityManager, FakeAgentActivityController, MockTransport) {
        let (api, transport) = JarvisAPI.mocked()
        let controller = FakeAgentActivityController()
        let manager = AgentActivityManager(api: AgentLiveAPI(api: api), controller: controller,
                                           isPaired: { paired }, deviceID: { "phone-1" })
        return (manager, controller, transport)
    }

    private func state(_ activities: [[String: Any]], enabled: Bool = true) -> [String: Any] {
        ["settings": ["enabled": enabled], "activities": activities]
    }

    func testRefreshStartsUpdatesAndEndsToMatchTheServer() async {
        let (manager, controller, transport) = makeManager()
        transport.route("/api/coding/agent-la/state", json: state([
            ["agent": "claude", "episode": "c1", "state": ["count": 2, "state": "working"]],
        ]))
        await manager.refresh()
        XCTAssertEqual(controller.started.map(\.0), ["claude"])
        XCTAssertEqual(controller.running["claude"]?.count, 2)
        XCTAssertTrue(manager.ownsCoding)
        XCTAssertEqual(manager.liveCount, 2)

        manager.apply(AgentLiveSnapshot(json: state([])))
        XCTAssertEqual(controller.ended, ["claude"])
    }

    func testTheFeatureTurnedOffOnTheServerEndsEverythingAndHandsCodingBack() {
        let (manager, controller, _) = makeManager()
        manager.apply(AgentLiveSnapshot(json: state([
            ["agent": "codex", "episode": "x1", "state": ["count": 1]]])))
        manager.apply(AgentLiveSnapshot(json: state([], enabled: false)))
        XCTAssertEqual(controller.ended, ["codex"])
        XCTAssertFalse(manager.ownsCoding, "the Jarvis activity carries coding again")
    }

    func testUntilTheServerAnswersTheJarvisActivityKeepsCoding() async {
        let (manager, _, _) = makeManager()
        await manager.refresh()      // nothing routed: an older server
        XCTAssertFalse(manager.ownsCoding)
    }

    func testASwipedAwayActivityIsNotRestartedThisEpisode() async {
        let (manager, controller, transport) = makeManager()
        transport.route("/api/coding/agent-la/token", json: ["ok": true])
        let snap = AgentLiveSnapshot(json: state([
            ["agent": "claude", "episode": "c1", "state": ["count": 1, "state": "working"]]]))
        manager.apply(snap)
        controller.simulateDismissal("claude", token: "tokC")
        manager.apply(snap)
        XCTAssertEqual(controller.started.count, 1)
        await servicesWaitUntil { transport.requests.contains { $0.url?.path == "/api/coding/agent-la/token" } }
        let body = transport.lastBody()
        XCTAssertEqual(body["kind"] as? String, "activity")
        XCTAssertEqual(body["agent"] as? String, "claude")
        XCTAssertEqual(body["ended"] as? Bool, true)
        XCTAssertEqual(body["dismissed"] as? Bool, true)

        manager.apply(AgentLiveSnapshot(json: state([
            ["agent": "claude", "episode": "c2", "state": ["count": 1, "state": "working"]]])))
        XCTAssertEqual(controller.started.count, 2, "a new episode brings it back")
    }

    func testActivityAndStartTokensAreRegisteredOnceEach() async {
        let (manager, controller, transport) = makeManager()
        transport.route("/api/coding/agent-la/token", json: ["ok": true])
        manager.start()
        controller.emitActivityToken("gemini", "t1")
        controller.emitActivityToken("gemini", "t1")
        controller.emitStartToken("s1")
        controller.emitStartToken("s1")
        await servicesWaitUntil { transport.requests.count >= 2 }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(transport.requests.count, 2, "tokens rotate; only changes are sent")
        let bodies = transport.requests.compactMap { r -> [String: Any]? in
            r.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
        XCTAssertTrue(bodies.contains { $0["kind"] as? String == "activity" && $0["agent"] as? String == "gemini"
                                        && $0["token"] as? String == "t1" && $0["device_id"] as? String == "phone-1" })
        XCTAssertTrue(bodies.contains { $0["kind"] as? String == "start" && $0["token"] as? String == "s1" })
    }

    func testTurningLiveActivitiesOffOnThePhoneEndsThemAndForgetsTheDevice() async {
        let (manager, controller, transport) = makeManager()
        transport.route("/api/coding/agent-la/token", json: ["ok": true])
        manager.apply(AgentLiveSnapshot(json: state([
            ["agent": "claude", "episode": "c1", "state": ["count": 1]]])))
        manager.setEnabled(false)
        XCTAssertEqual(controller.endAlls, 1)
        XCTAssertFalse(manager.ownsCoding)
        await servicesWaitUntil { !transport.requests.isEmpty }
        XCTAssertEqual(transport.lastBody()["kind"] as? String, "device")
        XCTAssertEqual(transport.lastBody()["ended"] as? Bool, true)

        manager.apply(AgentLiveSnapshot(json: state([
            ["agent": "codex", "episode": "x1", "state": ["count": 1]]])))
        XCTAssertEqual(controller.started.map(\.0), ["claude"], "off means nothing starts")
    }

    func testAnUnpairedPhoneNeverAsks() async {
        let (manager, _, transport) = makeManager(paired: false)
        await manager.refresh()
        XCTAssertTrue(transport.requests.isEmpty)
    }

    // MARK: - The Jarvis activity

    private func makeCoordinator(agentsEnabled: Bool?) async -> (FakeActivityController, LiveActivityCoordinator) {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/coding/projects", json: [
            "projects": [["id": "p1", "name": "hermes",
                          "sessions": [["id": "a", "status": "running", "activity_state": "working"]]]],
            "ungrouped": [],
        ])
        transport.route("/api/coding/usage", json: ["usage": [:]])
        transport.route("/api/island/designs", json: [
            "designs": [],
            "catalog": [["id": "coding", "name": "Coding", "builtin": true, "enabled": true, "priority": 10]],
        ])
        if let agentsEnabled {
            transport.route("/api/coding/agent-la/state", json: [
                "settings": ["enabled": agentsEnabled], "activities": [],
            ])
        }
        let controller = FakeActivityController()
        let agents = AgentActivityManager(api: AgentLiveAPI(api: api),
                                          controller: FakeAgentActivityController(),
                                          isPaired: { true }, deviceID: { "phone-1" })
        let coordinator = LiveActivityCoordinator(
            coding: CodingSessionsAPI(api: api), islandAPI: IslandDesignsAPI(api: api),
            islandCache: RecordingIslandCache(), controller: controller,
            plan: IslandPlanNotifier(notifier: MockNotifier()),
            lifecycle: AppLifecycle(), preferences: MemoryKeyValueStore(),
            isPaired: { true }, now: { Date(timeIntervalSince1970: 1_700_000_000) },
            sleeper: instantSleeper, agents: agents)
        await coordinator.refreshCoding()
        return (controller, coordinator)
    }

    func testWithAgentActivitiesOnTheJarvisActivityStaysTheVoiceIsland() async {
        let (controller, coordinator) = await makeCoordinator(agentsEnabled: true)
        XCTAssertEqual(coordinator.compose().mode, "voice")
        XCTAssertTrue(controller.updates.allSatisfy { $0.mode != "coding" },
                      "each agent has its own activity; the fleet isn't duplicated on Jarvis's")
    }

    func testWithAgentActivitiesOffTheJarvisActivityCarriesCodingAsBefore() async {
        let (_, coordinator) = await makeCoordinator(agentsEnabled: false)
        XCTAssertEqual(coordinator.compose().mode, "coding")
    }

    // MARK: - Needs you

    func testStartingToWaitOnYouAlertsOnce() {
        let working = CS(count: 1, state: "working")
        let asks = CS(count: 1, state: "approval", fingerprint: "f1", kind: "approval")
        XCTAssertTrue(AgentActivityPlan.needsAlert(from: working, to: asks))
        var stillAsks = asks
        stillAsks.count = 2
        XCTAssertFalse(AgentActivityPlan.needsAlert(from: asks, to: stillAsks), "same request: no second buzz")
        let asksAgain = CS(count: 1, state: "approval", fingerprint: "f2", kind: "approval")
        XCTAssertTrue(AgentActivityPlan.needsAlert(from: asks, to: asksAgain), "a new request alerts")
        XCTAssertFalse(AgentActivityPlan.needsAlert(from: asks, to: working))
    }

    func testTheAlertSaysWhoWantsWhat() {
        let approval = AgentActivityPlan.alertText(agent: "claude", state: CS(
            name: "Claude Code", project: "api", state: "approval", step: "Needs approval: Bash: rm -rf build"))
        XCTAssertEqual(approval.title, "Claude Code is waiting for your OK")
        XCTAssertEqual(approval.body, "api: Bash: rm -rf build")
        let question = AgentActivityPlan.alertText(agent: "codex", state: CS(
            project: "infra", state: "question", kind: "question", question: "Which region?"))
        XCTAssertEqual(question.title, "Codex has a question")
        XCTAssertEqual(question.body, "infra: Which region?")
    }

    func testTheManagerAlertsWhenASessionStartsWaiting() {
        let (manager, controller, _) = makeManager()
        manager.apply(AgentLiveSnapshot(json: state([
            ["agent": "claude", "episode": "c1", "state": ["count": 1, "state": "working"]]])))
        manager.apply(AgentLiveSnapshot(json: state([
            ["agent": "claude", "episode": "c1",
             "state": ["count": 1, "state": "approval", "kind": "approval", "fingerprint": "fp"]]])))
        XCTAssertEqual(controller.alerts, ["claude"])
    }

    func testAQuestionsOptionsBecomeButtonsOnlyWhenSomethingHoldsIt() {
        var st = CS(state: "question", fingerprint: "fq", kind: "question", question: "Region?",
                    options: ["us-east", "eu-west"])
        XCTAssertTrue(st.showsOptions)
        st.fingerprint = ""
        XCTAssertFalse(st.showsOptions)
        XCTAssertFalse(CS(state: "question", fingerprint: "fq", kind: "question").showsOptions,
                       "no options that fit: one Answer button instead")
    }

    func testTheLockScreenButtonsAskForNoFaceID() {
        XCTAssertEqual("\(AgentAllowIntent.authenticationPolicy)", "\(IntentAuthenticationPolicy.alwaysAllowed)")
        XCTAssertEqual("\(AgentDenyIntent.authenticationPolicy)", "\(IntentAuthenticationPolicy.alwaysAllowed)")
        XCTAssertEqual("\(AgentAnswerIntent.authenticationPolicy)", "\(IntentAuthenticationPolicy.alwaysAllowed)")
    }

    func testAnOlderServerWithoutWaitingSinceTimesFromTheLastActivity() throws {
        let st = try JSONDecoder().decode(CS.self, from: Data(#"{"state": "approval", "last": 99}"#.utf8))
        XCTAssertEqual(st.waitingStart, 99)
        XCTAssertEqual(st.options, [])
    }

    // MARK: - Answering from the Lock Screen is instant

    private var asking: CS {
        CS(count: 2, waiting: 1, working: 0, name: "Claude Code", project: "api", state: "approval",
           step: "Needs approval: Bash: rm -rf build", fingerprint: "fp", kind: "approval",
           bar: "p,i", actions: true, last: 100, waitingSince: 90)
    }

    func testAllowingClearsTheRequestAtOnce() {
        let st = AgentLiveDecision.decided(asking, decision: "allow")
        XCTAssertEqual(st.step, "Allowed ✓ · Bash: rm -rf build")
        XCTAssertEqual(st.state, "working")
        XCTAssertFalse(st.waitsOnYou, "no longer amber")
        XCTAssertFalse(st.showsButtons, "the buttons go")
        XCTAssertEqual(st.fingerprint, "")
        XCTAssertEqual(st.waiting, 0)
        XCTAssertEqual(st.waitingSince, 0)
        XCTAssertEqual(st.bar, "w,i")
    }

    func testDenyingSaysSo() {
        XCTAssertEqual(AgentLiveDecision.decided(asking, decision: "deny").step, "Denied · Bash: rm -rf build")
    }

    func testAnsweringNamesThePick() {
        var question = asking
        question.state = "question"
        question.kind = "question"
        question.question = "Region?"
        question.options = ["us-east-1", "eu-west-1"]
        let st = AgentLiveDecision.decided(question, decision: "answer", option: "eu-west-1")
        XCTAssertEqual(st.step, "Answered: eu-west-1")
        XCTAssertEqual(st.question, "")
        XCTAssertEqual(st.options, [])
        XCTAssertFalse(st.showsOptions)
    }

    func testTheJarvisActivitysOwnButtonsClearToo() {
        var jarvis = JarvisActivityAttributes.ContentState()
        jarvis.mode = "coding"
        jarvis.waitingCount = 2
        jarvis.leadState = "approval"
        jarvis.leadKind = "approval"
        jarvis.leadFingerprint = "fp"
        jarvis.leadStep = "Needs approval: Bash: ls"
        let st = AgentLiveDecision.decided(jarvis, decision: "allow")
        XCTAssertEqual(st.leadStep, "Allowed ✓ · Bash: ls")
        XCTAssertEqual(st.leadState, "working")
        XCTAssertEqual(st.leadKind, "")
        XCTAssertEqual(st.leadFingerprint, "")
        XCTAssertEqual(st.waitingCount, 1)
    }

    /// The app's next poll (or a push already on its way) still says "waiting"
    /// for a moment: a decision made here wins until the server catches up.
    func testARecentDecisionHoldsOverAStaleWaitingState() {
        let start = Date(timeIntervalSince1970: 1_000)
        AgentLiveDecision.record("fp", decision: "allow", at: start)
        defer { AgentLiveDecision.forget("fp") }
        XCTAssertEqual(AgentLiveDecision.overlay(asking, now: start.addingTimeInterval(5)).step,
                       "Allowed ✓ · Bash: rm -rf build")
        XCTAssertEqual(AgentLiveDecision.overlay(asking, now: start.addingTimeInterval(120)), asking,
                       "after a minute the server's word is final")
        var other = asking
        other.fingerprint = "other"
        XCTAssertEqual(AgentLiveDecision.overlay(other, now: start.addingTimeInterval(5)), other)
    }

    func testTheManagerShowsTheDecisionNotTheStalePoll() {
        let (manager, controller, _) = makeManager()
        AgentLiveDecision.record("fp", decision: "deny")
        defer { AgentLiveDecision.forget("fp") }
        manager.apply(AgentLiveSnapshot(json: state([
            ["agent": "claude", "episode": "c1",
             "state": ["count": 1, "state": "approval", "kind": "approval", "fingerprint": "fp",
                       "step": "Bash: ls"]]])))
        XCTAssertEqual(controller.running["claude"]?.step, "Denied · Bash: ls")
        XCTAssertEqual(controller.alerts, [], "no alert for a request you just answered")
    }
}

/// Records what the manager asked ActivityKit to do, and plays iOS's side.
@MainActor
final class FakeAgentActivityController: AgentActivityControlling {
    var onActivityToken: ((String, String) -> Void)?
    var onStartToken: ((String) -> Void)?
    var onEnded: ((String, String) -> Void)?

    private(set) var running: [String: AgentActivityAttributes.ContentState] = [:]
    private(set) var started: [(String, AgentActivityAttributes.ContentState)] = []
    private(set) var updated: [(String, AgentActivityAttributes.ContentState)] = []
    private(set) var ended: [String] = []
    private(set) var endAlls = 0
    private(set) var observed = 0

    func start(_ agent: String, _ state: AgentActivityAttributes.ContentState) {
        started.append((agent, state)); running[agent] = state
    }
    private(set) var alerts: [String] = []
    func update(_ agent: String, _ state: AgentActivityAttributes.ContentState, alert: Bool) {
        updated.append((agent, state)); running[agent] = state
        if alert { alerts.append(agent) }
    }
    func end(_ agent: String) { ended.append(agent); running[agent] = nil }
    func endAll() { endAlls += 1; running.removeAll() }
    func observe() { observed += 1 }

    func emitActivityToken(_ agent: String, _ token: String) { onActivityToken?(agent, token) }
    func emitStartToken(_ token: String) { onStartToken?(token) }
    /// You swiped the activity away on the Lock Screen.
    func simulateDismissal(_ agent: String, token: String) {
        running[agent] = nil
        onEnded?(agent, token)
    }
}

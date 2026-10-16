import Foundation

// Per-agent Live Activities, the app's half. The SERVER decides what each agent's
// activity shows (`agent/agent_la_push.py`): this file reads that while the app
// is in the foreground (`GET /api/coding/agent-la/state`), starts / updates /
// ends the activities to match, and hands the server every push token so it can
// keep them right — and start them (push-to-start) — while the app is closed.

typealias AgentContentState = AgentActivityAttributes.ContentState

// MARK: - Settings

/// The "Live Activities for agents" settings — one document on the server (the
/// Code Master settings' `agent_live`), edited from Code Master settings and the
/// Dynamic Island tab alike.
struct AgentLiveSettings: Equatable, Sendable {
    static let idleChoices = [10, 30, 60]
    static let defaultIdleMinutes = 30

    var enabled = true
    /// Per agent; an agent missing here is on.
    var agents: [String: Bool] = Dictionary(uniqueKeysWithValues: AgentBrand.all.map { ($0, true) })
    var idleMinutes = defaultIdleMinutes
    /// "Show Allow / Deny on the Lock Screen".
    var actions = true

    init() {}

    /// Only a REAL bool flips a switch and only a known idle choice counts — the
    /// server applies the same rule (`merge_settings`).
    init(json: [String: Any]?) {
        guard let json else { return }
        if let v = Self.bool(json["enabled"]) { enabled = v }
        if let v = Self.bool(json["actions"]) { actions = v }
        if let n = json["idle_minutes"] as? NSNumber, !CodingJSON.isBoolean(n),
           Self.idleChoices.contains(n.intValue), Double(n.intValue) == n.doubleValue {
            idleMinutes = n.intValue
        }
        if let map = json["agents"] as? [String: Any] {
            for agent in AgentBrand.all {
                if let v = Self.bool(map[agent]) { agents[agent] = v }
            }
        }
    }

    func isOn(_ agent: String) -> Bool { agents[agent] ?? true }
    mutating func set(_ agent: String, _ on: Bool) { agents[agent] = on }

    var payload: [String: Any] {
        ["enabled": enabled, "actions": actions, "idle_minutes": idleMinutes,
         "agents": Dictionary(uniqueKeysWithValues: AgentBrand.all.map { ($0, isOn($0)) })]
    }

    private static func bool(_ v: Any?) -> Bool? {
        guard let v, CodingJSON.isBoolean(v) else { return nil }
        return CodingJSON.bool(v)
    }
}

// MARK: - What the server wants shown

/// One agent's activity as the server wants it now. `episode` names the stretch
/// of time it has been wanted: swiping it away holds only for that episode.
struct AgentLiveTarget: Equatable, Sendable {
    let agent: String
    let episode: String
    let state: AgentContentState
}

struct AgentLiveSnapshot: Equatable, Sendable {
    var settings = AgentLiveSettings()
    var targets: [AgentLiveTarget] = []

    init(settings: AgentLiveSettings = AgentLiveSettings(), targets: [AgentLiveTarget] = []) {
        self.settings = settings
        self.targets = targets
    }

    /// `{settings, activities: [{agent, episode, state}]}`. An agent this build
    /// can't draw is skipped rather than shown wrong.
    init(json: [String: Any]) {
        settings = AgentLiveSettings(json: json["settings"] as? [String: Any])
        targets = ((json["activities"] as? [Any]) ?? []).compactMap { raw in
            guard let item = raw as? [String: Any],
                  let agent = AgentBrand.group(of: CodingJSON.text(item["agent"])),
                  let stateJSON = item["state"] as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: stateJSON),
                  let state = try? JSONDecoder().decode(AgentContentState.self, from: data)
            else { return nil }
            return AgentLiveTarget(agent: agent, episode: CodingJSON.text(item["episode"]), state: state)
        }
    }

    func target(_ agent: String) -> AgentLiveTarget? { targets.first { $0.agent == agent } }
}

// MARK: - The plan

/// What to do to the running activities so they match the server. Pure.
enum AgentActivityPlan {
    enum Action: Equatable {
        case start(agent: String, state: AgentContentState)
        /// `alert`: this update starts a wait on you — it pops the island open
        /// with a sound (`needsAlert`).
        case update(agent: String, state: AgentContentState, alert: Bool)
        case end(agent: String)
    }

    /// An update alerts when the lead starts a new wait on you: it wasn't
    /// waiting, or it's another session / another request (a new wait start).
    /// Still waiting on the same one doesn't — not even when the request's
    /// fingerprint shows up a moment after its hook (the server's rule too).
    static func needsAlert(from old: AgentContentState, to new: AgentContentState) -> Bool {
        guard new.waitsOnYou else { return false }
        return !old.waitsOnYou || old.key != new.key || old.waitingStart != new.waitingStart
    }

    /// The banner's words (the server sends the same for its pushes).
    static func alertText(agent: String, state st: AgentContentState) -> (title: String, body: String) {
        let who = st.name.isEmpty ? AgentBrand.title(for: agent) : st.name
        let project = st.project.isEmpty ? "session" : st.project
        if st.state == "question" || st.kind == "question" {
            let ask = st.question.isEmpty ? (st.step.isEmpty ? "tap to answer" : st.step) : st.question
            return ("\(who) has a question", "\(project): \(ask)")
        }
        var step = st.step
        if step.lowercased().hasPrefix("needs approval:") {
            step = String(step.dropFirst("needs approval:".count)).trimmingCharacters(in: .whitespaces)
        }
        return ("\(who) is waiting for your OK", step.isEmpty ? project : "\(project): \(step)")
    }

    /// `running` is what's on screen per agent; `dismissed` maps an agent to the
    /// episode you swiped it away in.
    static func reconcile(running: [String: AgentContentState], desired: [AgentLiveTarget],
                          dismissed: [String: String]) -> [Action] {
        let wanted = Set(desired.map(\.agent))
        var out: [Action] = running.keys.sorted().filter { !wanted.contains($0) }.map { .end(agent: $0) }
        for target in desired {
            if let current = running[target.agent] {
                if current != target.state {
                    out.append(.update(agent: target.agent, state: target.state,
                                       alert: needsAlert(from: current, to: target.state)))
                }
            } else if dismissed[target.agent] != target.episode {
                out.append(.start(agent: target.agent, state: target.state))
            }
        }
        return out
    }
}

// MARK: - REST

/// `/api/coding/agent-la/*`.
struct AgentLiveAPI {
    let api: JarvisAPI

    init(api: JarvisAPI = .shared) { self.api = api }

    func state() async throws -> AgentLiveSnapshot {
        AgentLiveSnapshot(json: try await api.get("/api/coding/agent-la/state").object())
    }

    /// The app's push-to-start token (iOS 17.2+): the server starts an agent's
    /// activity with it while the app is closed.
    func registerStartToken(_ token: String, deviceId: String?) async throws {
        try await post(["kind": "start", "token": token], deviceId)
    }

    /// One running activity's push token, so the server can update and end it.
    func registerActivityToken(agent: String, token: String, deviceId: String?) async throws {
        try await post(["kind": "activity", "agent": agent, "token": token], deviceId)
    }

    func activityEnded(agent: String, token: String, deviceId: String?, dismissed: Bool) async throws {
        try await post(["kind": "activity", "agent": agent, "token": token, "ended": true,
                        "dismissed": dismissed], deviceId)
    }

    /// Live Activities were turned off on this phone: stop pushing to it.
    func forgetDevice(_ deviceId: String?) async throws {
        try await post(["kind": "device", "ended": true], deviceId)
    }

    private func post(_ body: [String: Any], _ deviceId: String?) async throws {
        var body = body
        if let deviceId, !deviceId.isEmpty { body["device_id"] = deviceId }
        _ = try await api.post("/api/coding/agent-la/token", json: body)
    }
}

// MARK: - ActivityKit, behind a protocol

/// Starting, updating and ending the per-agent activities. Behind a protocol so
/// every rule above it is tested against a fake (ActivityKit needs a device).
@MainActor
protocol AgentActivityControlling: AnyObject {
    /// What each running activity shows, by agent (one per agent).
    var running: [String: AgentContentState] { get }
    func start(_ agent: String, _ state: AgentContentState)
    /// `alert`: show it as an alert (screen lights, island pops open, sound).
    func update(_ agent: String, _ state: AgentContentState, alert: Bool)
    func end(_ agent: String)
    func endAll()
    /// Begin watching activities (including ones the server push-started) and
    /// the push-to-start token. Idempotent.
    func observe()
    /// A running activity's push token (agent, hex token). Tokens rotate.
    var onActivityToken: ((String, String) -> Void)? { get set }
    /// The app's push-to-start token (hex). Rotates.
    var onStartToken: ((String) -> Void)? { get set }
    /// An activity ended that this app didn't end (agent, its last token or "",
    /// byYou). `byYou` is true only for a swipe-away on the Lock Screen — not for
    /// an end push or iOS's 8-hour limit.
    var onEnded: ((String, String, Bool) -> Void)? { get set }
}

// MARK: - The manager

/// Keeps the per-agent activities matching the server while the app runs, and
/// the server supplied with their tokens. Owned by `LiveActivityCoordinator`,
/// which polls it on its own cadence and follows the phone's Live Activities
/// switch.
@MainActor
final class AgentActivityManager {
    private let api: AgentLiveAPI
    private var controller: any AgentActivityControlling
    private let isPaired: @MainActor () -> Bool
    private let deviceID: @MainActor () -> String?
    /// The Agents REST (a question answered from the Lock Screen goes through it).
    private let agentsAPI: AgentsAPI
    /// Where swipe-aways are kept across launches (the App Group's defaults).
    private let dismissals: KeyValueStore
    /// The defaults key: a JSON object, agent → episode.
    static let dismissalsKey = "jc.agentLiveActivities.dismissed"

    /// The phone's own Live Activities switch.
    private(set) var enabled = true
    /// The server's "Live Activities for agents" switch; nil until it answered
    /// (an older server never does).
    private(set) var serverEnabled: Bool?
    private(set) var snapshot: AgentLiveSnapshot?

    /// agent → the episode you swiped its activity away in. Kept in the App
    /// Group's defaults, so a relaunch doesn't bring it back the same episode.
    private var dismissed: [String: String] = [:]
    /// agent → the newest activity token iOS handed over, and → the one the
    /// server confirmed. A token counts as sent only once the POST succeeded;
    /// anything else (unpaired, offline, a 5xx) is sent again on the next refresh.
    private var latestTokens: [String: String] = [:]
    private var sentTokens: [String: String] = [:]
    private var tokensInFlight: Set<String> = []
    private var startToken = ""
    private var sentStartToken = ""
    private var startInFlight = false
    private var observing = false

    /// While on, each agent has its own activity, so the Jarvis activity stops
    /// carrying the coding fleet. Until the server has said so, it keeps it.
    var ownsCoding: Bool { enabled && serverEnabled == true }

    /// Live sessions across the agents' activities (drives the poll cadence).
    var liveCount: Int { ownsCoding ? (snapshot?.targets.reduce(0) { $0 + $1.state.count } ?? 0) : 0 }

    init(api: AgentLiveAPI = AgentLiveAPI(),
         controller: (any AgentActivityControlling)? = nil,
         isPaired: (@MainActor () -> Bool)? = nil,
         deviceID: (@MainActor () -> String?)? = nil,
         agents: AgentsAPI = AgentsAPI(),
         dismissals: KeyValueStore? = nil) {
        self.api = api
        self.agentsAPI = agents
        self.dismissals = dismissals ?? (UserDefaults(suiteName: JarvisShared.appGroupID) ?? .standard)
        self.dismissed = Self.loadDismissals(self.dismissals)
        self.controller = controller ?? DefaultAgentActivityController()
        self.isPaired = isPaired ?? { BridgeClient.shared.isPaired }
        self.deviceID = deviceID ?? { PushHandler.shared.deviceID }
        self.controller.onActivityToken = { [weak self] agent, token in
            self?.activityToken(agent, token)
        }
        self.controller.onStartToken = { [weak self] token in self?.startTokenChanged(token) }
        self.controller.onEnded = { [weak self] agent, token, byYou in
            self?.ended(agent, token, byYou: byYou)
        }
    }

    /// Begin watching activities and tokens (at launch, background launches
    /// included: a push-started activity wakes the app to hand over its token).
    func start() {
        guard enabled, !observing else { return }
        observing = true
        controller.observe()
        // A question's option tapped on the Lock Screen: find the waiting request
        // by its fingerprint and answer it the way the Agents tab does.
        if AgentDecisionBridge.answer == nil {
            AgentDecisionBridge.answer = { [weak self] fingerprint, question, option in
                await self?.answer(fingerprint: fingerprint, question: question, option: option) ?? false
            }
        }
    }

    /// Answer a held question from the Lock Screen: find the request by its
    /// fingerprint and answer it the way the Agents tab does.
    func answer(fingerprint: String, question: String, option: String) async -> Bool {
        guard let overview = try? await agentsAPI.overview(),
              let request = overview.requests.first(where: { $0.fingerprint == fingerprint })
        else { return false }
        // The arbiter matches answers by the EXACT question; the activity only
        // carries the server's cut (≤ 90 chars, "…", whitespace collapsed).
        let asked = Self.fullQuestion(matching: question, in: request.questions.map(\.question))
        return (try? await agentsAPI.verdict(requestId: request.requestId, decision: "answer",
                                             answers: [asked: option])) ?? false
    }

    /// The held request's own question that the activity's cut text came from.
    static func fullQuestion(matching cut: String, in questions: [String]) -> String {
        func collapsed(_ text: String) -> String {
            text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        var stem = collapsed(cut)
        if stem.hasSuffix("…") { stem = String(stem.dropLast()) }
        if !stem.isEmpty, let full = questions.first(where: { collapsed($0).hasPrefix(stem) }) {
            return full
        }
        return questions.first ?? cut
    }

    /// Fetch what the server wants shown and apply it. Errors keep the last state.
    func refresh() async {
        guard enabled, isPaired() else { return }
        flushTokens()   // anything iOS handed over while unpaired or offline
        do {
            apply(try await api.state())
        } catch {
            JcLog.dropped(JcLog.services, "agent live activities state", error)
        }
    }

    func apply(_ snap: AgentLiveSnapshot) {
        snapshot = snap
        serverEnabled = snap.settings.enabled
        guard enabled else { return }
        // A swipe-away holds only for its episode.
        let current = dismissed.filter { snap.target($0.key)?.episode == $0.value }
        if current != dismissed {
            dismissed = current
            saveDismissals()
        }
        // A request answered on the Lock Screen a moment ago stays answered even
        // if this poll still says "waiting" (`AgentLiveDecision`).
        let desired = snap.settings.enabled
            ? snap.targets.map { AgentLiveTarget(agent: $0.agent, episode: $0.episode,
                                                 state: AgentLiveDecision.overlay($0.state)) }
            : []
        for action in AgentActivityPlan.reconcile(running: controller.running, desired: desired,
                                                  dismissed: dismissed) {
            switch action {
            case .start(let agent, let state): controller.start(agent, state)
            case .update(let agent, let state, let alert): controller.update(agent, state, alert: alert)
            case .end(let agent): controller.end(agent)
            }
        }
    }

    /// The phone's Live Activities switch. Off ends every agent activity and tells
    /// the server to stop pushing to this phone; on re-registers and refreshes.
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on {
            start()
            flushTokens()
            Task { await refresh() }
        } else {
            controller.endAll()
            latestTokens.removeAll()
            sentTokens.removeAll()
            sentStartToken = ""
            guard isPaired() else { return }
            let api = self.api, device = deviceID()
            Task { try? await api.forgetDevice(device) }
        }
    }

    // MARK: Callbacks from ActivityKit

    private func activityToken(_ agent: String, _ token: String) {
        latestTokens[agent] = token
        flushTokens()
    }

    private func startTokenChanged(_ token: String) {
        startToken = token
        sendStartTokenIfNeeded()
    }

    /// POST every token the server hasn't confirmed yet. Called as tokens arrive,
    /// on each refresh and when Live Activities come back on.
    private func flushTokens() {
        guard enabled, isPaired() else { return }
        for (agent, token) in latestTokens where sentTokens[agent] != token && !tokensInFlight.contains(agent) {
            tokensInFlight.insert(agent)
            let api = self.api, device = deviceID()
            Task { [weak self] in
                let ok = (try? await api.registerActivityToken(agent: agent, token: token,
                                                               deviceId: device)) != nil
                self?.tokensInFlight.remove(agent)
                if ok, self?.latestTokens[agent] == token { self?.sentTokens[agent] = token }
            }
        }
        sendStartTokenIfNeeded()
    }

    private func sendStartTokenIfNeeded() {
        guard enabled, isPaired(), !startToken.isEmpty, startToken != sentStartToken,
              !startInFlight else { return }
        startInFlight = true
        let api = self.api, token = startToken, device = deviceID()
        Task { [weak self] in
            let ok = (try? await api.registerStartToken(token, deviceId: device)) != nil
            self?.startInFlight = false
            if ok { self?.sentStartToken = token }
        }
    }

    private func ended(_ agent: String, _ token: String, byYou: Bool) {
        latestTokens[agent] = nil
        sentTokens[agent] = nil
        // Swiped away while still wanted → keep it away until the agent's next
        // episode (the server does the same for push-to-start). An end push or
        // iOS's 8-hour limit isn't you: the next poll may bring it back.
        let episode = byYou ? snapshot?.target(agent)?.episode : nil
        if let episode {
            dismissed[agent] = episode
            saveDismissals()
        }
        guard isPaired() else { return }
        let api = self.api, device = deviceID()
        Task {
            try? await api.activityEnded(agent: agent, token: token, deviceId: device,
                                         dismissed: episode != nil)
        }
    }

    // MARK: Swipe-aways across launches

    private static func loadDismissals(_ store: KeyValueStore) -> [String: String] {
        guard let raw = store.string(dismissalsKey), let data = raw.data(using: .utf8),
              let map = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return map
    }

    private func saveDismissals() {
        guard !dismissed.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: dismissed),
              let raw = String(data: data, encoding: .utf8) else {
            dismissals.set(nil, forKey: Self.dismissalsKey)
            return
        }
        dismissals.set(raw, forKey: Self.dismissalsKey)
    }
}

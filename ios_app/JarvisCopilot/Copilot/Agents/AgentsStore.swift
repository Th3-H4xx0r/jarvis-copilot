import Foundation
import Observation

/// The Agents tab's state: every hook-tracked coding-agent session, the
/// approvals and questions waiting on you, and the Claude plan usage.
///
/// Push-driven: while the tab is on screen the store wants the `agents` bridge
/// topic (the server sends the compact session list, coalesced), fetches once
/// on becoming visible and after a reconnect, and only asks for the waiting
/// requests when a new one shows up in a push. Nothing runs off screen — the
/// app is never suspended, so a timer here would run all night.
@MainActor
@Observable
final class AgentsStore {
    static let shared = AgentsStore()

    private(set) var sessions: [AgentSessionItem] = []
    private(set) var requests: [AgentRequest] = []
    private(set) var usage: AgentPlanUsage?
    /// Codex's plan limits, read from `codex app-server` on the Mac.
    private(set) var codexUsage: AgentPlanUsage?
    private(set) var loadError: String?
    private(set) var loaded = false
    /// A session a push tap or deep link asked to show, latched until the tab takes it.
    private(set) var openRequest: String?

    @ObservationIgnored let api: AgentsAPI
    @ObservationIgnored private let topics: BridgeTopics
    @ObservationIgnored private var visible = false
    @ObservationIgnored private var listening = false
    @ObservationIgnored private var fetchingRequests = false

    init(api: AgentsAPI = AgentsAPI(), topics: BridgeTopics = .shared) {
        self.api = api
        self.topics = topics
    }

    var waitingCount: Int { max(requests.count, sessions.filter { $0.state.waitsOnYou }.count) }
    var workingCount: Int { sessions.filter { $0.state == .working || $0.state == .thinking }.count }

    func request(for session: AgentSessionItem) -> AgentRequest? {
        requests.first { $0.key == session.key }
    }

    func session(key: String) -> AgentSessionItem? { sessions.first { $0.key == key } }

    func requestOpen(_ key: String) { openRequest = key }

    /// The weekly recap was asked for (Monday's notification, a deep link).
    private(set) var recapRequested = false

    func requestRecap() { recapRequested = true }

    func consumeRecap() -> Bool {
        defer { recapRequested = false }
        return recapRequested
    }

    func consumeOpen() -> String? {
        defer { openRequest = nil }
        return openRequest
    }

    // MARK: visibility

    func setVisible(_ on: Bool) {
        guard on != visible else { return }
        visible = on
        listen()
        if on {
            topics.want("agents", owner: "agents-tab", every: 2)
            Task { await refresh() }
        } else {
            topics.drop("agents", owner: "agents-tab")
        }
    }

    private func listen() {
        guard !listening else { return }
        listening = true
        topics.on("agents") { [weak self] data in self?.apply(data) }
        topics.onResync { [weak self] in
            guard let self, self.visible else { return }
            Task { await self.refresh() }
        }
    }

    // MARK: data

    func refresh() async {
        do {
            let overview = try await api.overview()
            sessions = Self.sorted(overview.sessions)
            requests = overview.requests
            AgentsSpotlight.index(sessions)
            usage = overview.usage ?? usage
            codexUsage = overview.codexUsage ?? codexUsage
            loadError = nil
        } catch {
            loadError = apiErrorMessage(error)
        }
        loaded = true
    }

    /// One `agents` push.
    func apply(_ data: [String: Any]) {
        guard let raw = data["sessions"] as? [Any] else { return }
        let next = Self.sorted(raw.compactMap { ($0 as? [String: Any]).map(AgentSessionItem.init(json:)) })
        sessions = next
        loaded = true
        AgentsSpotlight.index(next)
        let pushed = Set(next.compactMap(\.pendingFingerprint))
        let known = Set(requests.map(\.fingerprint))
        if !pushed.isSubset(of: known) {
            Task { await refreshRequests() }
        } else if !known.isSubset(of: pushed) {
            // A card was settled elsewhere (answered in the terminal, timed out).
            requests.removeAll { !pushed.contains($0.fingerprint) && !$0.fingerprint.isEmpty }
        }
    }

    private func refreshRequests() async {
        guard !fetchingRequests else { return }
        fetchingRequests = true
        defer { fetchingRequests = false }
        if let overview = try? await api.overview() {
            requests = overview.requests
            usage = overview.usage ?? usage
        }
    }

    static func sorted(_ items: [AgentSessionItem]) -> [AgentSessionItem] {
        items.sorted { a, b in
            a.state.urgency != b.state.urgency ? a.state.urgency < b.state.urgency
                : a.lastEventAt > b.lastEventAt
        }
    }

    // MARK: decisions

    enum Decision: String { case allow, deny, always, ask }

    /// Allow / Deny / Always / "ask in the terminal". The card leaves at once and
    /// comes back if the server didn't take it.
    @discardableResult
    func decide(_ request: AgentRequest, _ decision: Decision, message: String? = nil) async -> Bool {
        let before = requests
        requests.removeAll { $0.requestId == request.requestId }
        do {
            if try await api.verdict(requestId: request.requestId, decision: decision.rawValue,
                                     message: message) {
                AgentsDecisionLog.record(request, decision: decision.rawValue)
                return true
            }
        } catch {
            loadError = apiErrorMessage(error)
        }
        requests = before
        return false
    }

    /// Answers to a question, keyed by question text. Single-select questions
    /// send one label, multi-select a list — Claude Code's own shape.
    @discardableResult
    func answer(_ request: AgentRequest, _ picks: [String: [String]]) async -> Bool {
        var answers: [String: Any] = [:]
        for q in request.questions {
            guard let chosen = picks[q.question], !chosen.isEmpty else { continue }
            answers[q.question] = q.multiSelect ? chosen : chosen[0]
        }
        let before = requests
        requests.removeAll { $0.requestId == request.requestId }
        do {
            if try await api.verdict(requestId: request.requestId, decision: "answer",
                                     answers: answers) {
                AgentsDecisionLog.record(request, decision: "answered")
                return true
            }
        } catch {
            loadError = apiErrorMessage(error)
        }
        requests = before
        return false
    }

    func sendInstruction(_ text: String, to key: String) async throws -> String {
        try await api.sendInstruction(key: key, text: text)
    }

    func detail(key: String) async throws -> AgentSessionDetail {
        try await api.session(key: key)
    }
}

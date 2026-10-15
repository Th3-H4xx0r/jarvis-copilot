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

    /// The "Needs you" rows plus any card without a row — the number the list shows.
    var waitingCount: Int { AgentsGrouping.waitingCount(sessions, requests: requests) }
    var workingCount: Int { AgentsGrouping.workingCount(sessions, requests: requests) }

    var sections: [AgentListSection] { AgentsGrouping.sections(sessions, requests: requests) }
    var orphanRequests: [AgentRequest] { AgentsGrouping.orphans(requests, sessions: sessions) }

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
            show(try await api.overview())
        } catch {
            if !wasCancelled(error) { loadError = apiErrorMessage(error) }
            loaded = true
        }
    }

    /// One overview, from a fetch (or a preview).
    func show(_ overview: AgentsAPI.Overview) {
        sessions = Self.sorted(overview.sessions)
        requests = overview.requests
        AgentsSpotlight.index(sessions)
        usage = overview.usage ?? usage
        codexUsage = overview.codexUsage ?? codexUsage
        loadError = nil
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

    // MARK: instructions from the phone

    /// What this phone sent each session, from the tap until the conversation
    /// shows it — kept here rather than on the screen, so leaving and coming
    /// back doesn't lose a message that's still on its way.
    private(set) var outgoingByKey: [String: [AgentOutgoing]] = [:]

    func outgoing(for key: String) -> [AgentOutgoing] { outgoingByKey[key] ?? [] }

    /// Sends the next instruction. No Face ID: typing to your own agent isn't
    /// a decision about what runs on the computer — approving a command is,
    /// and that still asks. The bubble shows at once as "Sending…", then as
    /// sent or with why it didn't go.
    func send(_ text: String, to key: String, prompts: [String]) async {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let item = AgentOutgoing(text: body, baseline: AgentOutgoing.count(body, in: prompts))
        var list = outgoing(for: key)
        list.append(item)
        outgoingByKey[key] = Array(list.suffix(Self.outgoingLimit))
        await deliver(item.id, key: key)
    }

    /// Sends a failed bubble again, in place.
    func retry(_ id: UUID, key: String) async {
        guard let item = outgoing(for: key).first(where: { $0.id == id }),
              case .failed = item.phase else { return }
        update(id, key: key) { $0.phase = .sending }
        await deliver(id, key: key)
    }

    func dismissOutgoing(_ id: UUID, key: String) {
        outgoingByKey[key]?.removeAll { $0.id == id }
    }

    /// Lets a delivered bubble go once the conversation shows it.
    func reconcileOutgoing(key: String, prompts: [String]) {
        guard let list = outgoingByKey[key] else { return }
        let next = AgentOutgoing.reconcile(list, prompts: prompts)
        if next != list { outgoingByKey[key] = next }
    }

    private static let outgoingLimit = 6

    private func deliver(_ id: UUID, key: String) async {
        guard let item = outgoing(for: key).first(where: { $0.id == id }) else { return }
        do {
            let via = try await api.sendInstruction(key: key, text: item.text)
            update(id, key: key) { $0.phase = .sent(via: via) }
        } catch {
            update(id, key: key) { $0.phase = .failed(AgentSendFailure.from(error)) }
        }
    }

    private func update(_ id: UUID, key: String, _ change: (inout AgentOutgoing) -> Void) {
        guard var list = outgoingByKey[key], let i = list.firstIndex(where: { $0.id == id }) else { return }
        change(&list[i])
        outgoingByKey[key] = list
    }

    func detail(key: String) async throws -> AgentSessionDetail {
        try await api.session(key: key)
    }
}

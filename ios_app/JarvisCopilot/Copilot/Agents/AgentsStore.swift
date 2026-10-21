import Foundation
import Observation

/// The Agents tab's state: every conversation on the Mac and the server (one
/// record each), the Mac-asleep card, the approvals and questions waiting on
/// you, and the plan usage.
///
/// Push-driven: while the tab is on screen the store wants the `agents_list`
/// bridge topic (the server pushes the whole list on every change), fetches
/// once on becoming visible, after a reconnect and on pull-to-refresh, and only
/// asks for the waiting cards when a new one shows up in a push. Nothing runs
/// on a timer — the app is never suspended, so a timer here would run all night.
@MainActor
@Observable
final class AgentsStore {
    static let shared = AgentsStore()

    /// Nil until the first fetch or push lands.
    private(set) var list: AgentsList?
    private(set) var requests: [AgentRequest] = []
    private(set) var usage: AgentPlanUsage?
    /// Codex's plan limits, read from `codex app-server` on the Mac.
    private(set) var codexUsage: AgentPlanUsage?
    private(set) var loadError: String?
    private(set) var loaded = false
    /// A session a push tap or deep link asked to show (a tracker key or a
    /// conversation key), latched until the tab takes it.
    private(set) var openRequest: String?
    /// Conversations a Continue / Stop / Resume is running for.
    private(set) var busy: Set<String> = []
    /// The last action that failed, in words — shown until the next one.
    private(set) var actionError: String?

    @ObservationIgnored let api: AgentsAPI
    @ObservationIgnored private let topics: BridgeTopics
    @ObservationIgnored private var visible = false
    @ObservationIgnored private var listening = false
    @ObservationIgnored private var fetchingRequests = false

    static let topic = "agents_list"

    init(api: AgentsAPI = AgentsAPI(), topics: BridgeTopics = .shared) {
        self.api = api
        self.topics = topics
    }

    // MARK: what the list shows

    var card: AgentSleepCard? { list?.card }
    var needsYou: [AgentConv] { list.map(AgentsListLayout.needsYou) ?? [] }
    var projects: [AgentProjectGroup] { list?.projects ?? [] }
    /// Integration runs, by integration — their own section, collapsed by default.
    var integrations: [AgentIntegrationGroup] { list?.integrations ?? [] }
    var orphanRequests: [AgentRequest] { list.map { AgentsListLayout.orphans(requests, list: $0) } ?? requests }
    /// The number beside "Needs you" — never a different count from the rows.
    var waitingCount: Int { needsYou.count + orphanRequests.count }
    var isEmpty: Bool { (list?.isEmpty ?? true) && requests.isEmpty }

    func conv(_ ckey: String) -> AgentConv? { list?.conv(ckey) }

    func request(for conv: AgentConv) -> AgentRequest? {
        AgentsListLayout.request(for: conv, in: requests)
    }

    /// A tracker key or a conversation key → the conversation's key.
    func resolveCkey(_ key: String) -> String {
        if let c = list?.all.first(where: { $0.ckey == key || $0.key == key }) { return c.ckey }
        return AgentsListLayout.ckey(fromKey: key)
    }

    func requestOpen(_ key: String) { openRequest = key }

    func consumeOpen() -> String? {
        defer { openRequest = nil }
        return openRequest
    }

    /// The weekly recap was asked for (Monday's notification, a deep link).
    private(set) var recapRequested = false

    func requestRecap() { recapRequested = true }

    func consumeRecap() -> Bool {
        defer { recapRequested = false }
        return recapRequested
    }

    // MARK: visibility

    func setVisible(_ on: Bool) {
        guard on != visible else { return }
        visible = on
        listen()
        if on {
            topics.want(Self.topic, owner: "agents-tab", every: 1)
            Task { await refresh() }
        } else {
            topics.drop(Self.topic, owner: "agents-tab")
        }
    }

    private func listen() {
        guard !listening else { return }
        listening = true
        topics.on(Self.topic) { [weak self] data in self?.apply(data) }
        topics.onResync { [weak self] in
            guard let self, self.visible else { return }
            Task { await self.refresh() }
        }
    }

    // MARK: data

    /// The list and the waiting cards, together.
    func refresh() async {
        async let fetched = api.list()
        async let cards = api.pending()
        do {
            show(try await fetched)
        } catch {
            if !wasCancelled(error) { loadError = apiErrorMessage(error) }
            loaded = true
        }
        if let cards = try? await cards { requests = cards }
    }

    /// One list, from a fetch, a push or a preview. A fetch answered after a
    /// newer push is older than what's on screen: it's dropped (unless the
    /// server's clock went back further than any request takes).
    func show(_ next: AgentsList) {
        if let current = list, next.ts > 0, next.ts < current.ts,
           current.ts - next.ts < Self.staleListWindow {
            loaded = true
            return
        }
        list = next
        // Integration runs are Jarvis's own background work: hundreds of them
        // would bury his coding turns in Spotlight.
        AgentsSpotlight.index(next.all.filter { $0.integration == nil })
        usage = next.usage ?? usage
        codexUsage = next.codexUsage ?? codexUsage
        loadError = nil
        loaded = true
        followDeliveries(next)
    }

    /// How much older (server seconds) a list can be and still be a stale
    /// in-flight answer rather than a server whose clock was reset.
    static let staleListWindow: Double = 120

    /// Each conversation's recent sends, as the server last recorded them, onto
    /// this phone's bubbles: a "Sent" the Mac couldn't type turns Failed, a
    /// queued one Delivered.
    private func followDeliveries(_ next: AgentsList) {
        for (ckey, items) in outgoingByKey {
            guard let deliveries = next.conv(ckey)?.deliveries, !deliveries.isEmpty else { continue }
            let followed = items.map { $0.following(deliveries) }
            if followed != items { outgoingByKey[ckey] = followed }
        }
    }

    /// One `agents_list` push.
    func apply(_ data: [String: Any]) {
        guard data["projects"] != nil || data["needs_you"] != nil else { return }
        show(AgentsList(json: data))
        let pushed = Set((list?.all ?? []).compactMap { $0.pending?.fingerprint }.filter { !$0.isEmpty })
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
        if let cards = try? await api.pending() { requests = cards }
    }

    // MARK: moving sessions

    enum ContinueOutcome: Equatable {
        case done
        /// These sessions' Mac went offline without sleeping: ask, then resend
        /// with `confirmOffline`.
        case needsConfirmation([String])
        case failed(String)
    }

    /// Continue sessions on the server: one, or every one on the asleep card.
    @discardableResult
    func continueOnServer(_ ckeys: [String], confirmOffline: Bool = false) async -> ContinueOutcome {
        guard !ckeys.isEmpty else { return .done }
        busy.formUnion(ckeys)
        defer { busy.subtract(ckeys) }
        do {
            let results = try await api.continueSessions(ckeys, to: "server", confirmOffline: confirmOffline)
            let confirm = ckeys.filter { results[$0]?.needsConfirmation == true }
            let failed = ckeys.compactMap { k -> String? in
                guard let r = results[k], !r.ok, !r.needsConfirmation else { return nil }
                return r.error ?? "It couldn’t move to the server."
            }
            await refresh()
            if !confirm.isEmpty { return .needsConfirmation(confirm) }
            if let first = failed.first {
                actionError = first
                return .failed(first)
            }
            actionError = nil
            return .done
        } catch {
            let message = apiErrorMessage(error)
            actionError = message
            return .failed(message)
        }
    }

    /// Bring a session that moved to the server back to its Mac.
    @discardableResult
    func continueOnMac(_ ckey: String) async -> String? {
        await act(ckey) {
            let r = try await self.api.continueSessions([ckey], to: "mac")[ckey]
            if let r, !r.ok { throw CodingServerError(message: r.error ?? "It couldn’t move to the Mac.") }
        }
    }

    @discardableResult
    func stop(_ ckey: String) async -> String? {
        await act(ckey) { try await self.api.stop(ckey: ckey) }
    }

    /// Resume an ended session on the server or its Mac.
    @discardableResult
    func resume(_ ckey: String, onServer: Bool) async -> String? {
        await act(ckey) { try await self.api.resume(ckey: ckey, where: onServer ? "server" : "mac") }
    }

    /// Hide the Mac-asleep card (or some of its rows) without moving anything.
    func dismissCard(_ card: AgentSleepCard, ckeys: [String]? = nil) async {
        let before = list
        if ckeys == nil { list?.card = nil }
        do {
            try await api.dismissCard(deviceId: card.deviceId, ckeys: ckeys)
            await refresh()
        } catch {
            list = before
            actionError = apiErrorMessage(error)
        }
    }

    /// Start a new session. Nil on success, else why not.
    func launch(cwd: String, where place: String, agent: String, model: String?,
                permissionMode: String?, prompt: String?) async -> String? {
        do {
            try await api.launch(cwd: cwd, where: place, agent: agent, model: model,
                                 permissionMode: permissionMode, prompt: prompt)
            await refresh()
            return nil
        } catch {
            return apiErrorMessage(error)
        }
    }

    func clearActionError() { actionError = nil }

    /// Runs one action for a conversation; nil on success, else the reason
    /// (also kept in `actionError`).
    private func act(_ ckey: String, _ body: @escaping () async throws -> Void) async -> String? {
        busy.insert(ckey)
        defer { busy.remove(ckey) }
        do {
            try await body()
            actionError = nil
            await refresh()
            return nil
        } catch {
            let message = apiErrorMessage(error)
            actionError = message
            return message
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

    // MARK: messages from the phone

    /// What this phone sent each conversation, from the tap until the transcript
    /// shows it — kept here rather than on the screen, so leaving and coming
    /// back doesn't lose a message that's still on its way.
    private(set) var outgoingByKey: [String: [AgentOutgoing]] = [:]

    func outgoing(for ckey: String) -> [AgentOutgoing] { outgoingByKey[ckey] ?? [] }

    /// Sends a message. No Face ID: typing to your own agent isn't a decision
    /// about what runs on the computer — approving a command is, and that still
    /// asks. The bubble shows at once as "Sending…", then what the server did
    /// with it, or why it didn't go.
    func send(_ text: String, to ckey: String, prompts: [String], now: Bool = false) async {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        var item = AgentOutgoing(text: body, baseline: AgentOutgoing.count(body, in: prompts))
        item.now = now
        var list = outgoing(for: ckey)
        list.append(item)
        outgoingByKey[ckey] = Array(list.suffix(Self.outgoingLimit))
        await deliver(item.id, ckey: ckey)
    }

    /// Sends a failed bubble again, in place — unless the session waits on an
    /// approval or a question: typed now, the words land in its menu and the
    /// Return picks "Yes". The bubble keeps its words and says why.
    func retry(_ id: UUID, ckey: String) async {
        guard let item = outgoing(for: ckey).first(where: { $0.id == id }),
              case .failed = item.phase else { return }
        if let c = conv(ckey), c.waitsOnYou, let why = AgentsListLayout.cantSendReason(c) {
            update(id, ckey: ckey) { $0.phase = .failed(.other(why)) }
            return
        }
        update(id, ckey: ckey) { $0.phase = .sending }
        await deliver(id, ckey: ckey)
    }

    func dismissOutgoing(_ id: UUID, ckey: String) {
        outgoingByKey[ckey]?.removeAll { $0.id == id }
    }

    /// Lets a bubble go once the conversation shows it arrived.
    func reconcileOutgoing(ckey: String, prompts: [String]) {
        guard let list = outgoingByKey[ckey] else { return }
        let next = AgentOutgoing.reconcile(list, prompts: prompts)
        if next != list { outgoingByKey[ckey] = next }
    }

    private static let outgoingLimit = 6

    private func deliver(_ id: UUID, ckey: String) async {
        guard let item = outgoing(for: ckey).first(where: { $0.id == id }) else { return }
        do {
            let delivery = try await api.send(ckey: ckey, text: item.text, now: item.now)
            update(id, ckey: ckey) {
                $0.phase = AgentOutgoing.Phase(delivery)
                $0.deliveryId = delivery.id.isEmpty ? nil : delivery.id
            }
        } catch {
            update(id, ckey: ckey) { $0.phase = .failed(AgentSendFailure.from(error)) }
        }
    }

    private func update(_ id: UUID, ckey: String, _ change: (inout AgentOutgoing) -> Void) {
        guard var list = outgoingByKey[ckey], let i = list.firstIndex(where: { $0.id == id }) else { return }
        change(&list[i])
        outgoingByKey[ckey] = list
    }
}

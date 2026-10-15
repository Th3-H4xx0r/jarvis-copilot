import ActivityKit
import Foundation

/// The ActivityKit half of the per-agent Live Activities: one
/// `Activity<AgentActivityAttributes>` per agent, their push tokens, the app's
/// push-to-start token, and noticing when one goes away.
///
/// The server may start an activity with a push while the app is closed; iOS
/// then wakes the app, `activityUpdates` hands it over and its token goes to the
/// server. If the app and the server both started one for the same agent (a race
/// around a foreground start), the second is ended here so there is always one
/// per agent.
@MainActor
final class DefaultAgentActivityController: AgentActivityControlling {

    var onActivityToken: ((String, String) -> Void)?
    var onStartToken: ((String) -> Void)?
    var onEnded: ((String, String) -> Void)?

    /// agent → its activity.
    private var byAgent: [String: Activity<AgentActivityAttributes>] = [:]
    /// activity id → the token / state observers, cancelled when it goes away.
    private var watchers: [String: [Task<Void, Never>]] = [:]
    /// activity id → its last push token (handed back with `onEnded`).
    private var tokens: [String: String] = [:]
    /// Activities this app is ending, so their end isn't reported as a swipe.
    private var ending: Set<String> = []
    private var observing = false
    private let queue = ActivityUpdateQueue()

    func drain() async { await queue.drain() }

    var running: [String: AgentContentState] {
        byAgent.mapValues { $0.content.state }
    }

    func start(_ agent: String, _ state: AgentContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, byAgent[agent] == nil else { return }
        let content = Self.content(state)
        let attributes = AgentActivityAttributes(agent: agent)
        do {
            adopt(try Activity.request(attributes: attributes, content: content, pushType: .token))
        } catch {
            // A build without the Push Notifications capability can't ask for a
            // token; a token-less activity still beats none.
            JcLog.dropped(JcLog.services, "agent live activity request (push token)", error)
            do {
                adopt(try Activity.request(attributes: attributes, content: content))
            } catch {
                // Off for this app, the system's limit on running activities, or
                // no entitlement: nothing appears and nothing throws, so say why.
                JcLog.dropped(JcLog.services, "agent live activity request", error)
            }
        }
    }

    func update(_ agent: String, _ state: AgentContentState) {
        guard let activity = byAgent[agent] else { return }
        let content = Self.content(state)
        queue.enqueue { await activity.update(content) }
    }

    func end(_ agent: String) {
        guard let activity = byAgent.removeValue(forKey: agent) else { return }
        finish(activity)
    }

    func endAll() {
        let all = Array(byAgent.values)
        byAgent.removeAll()
        all.forEach { finish($0) }
        // Ones the server started that this process never adopted, too.
        queue.enqueue {
            for activity in Activity<AgentActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    func observe() {
        guard !observing else { return }
        observing = true
        for activity in Activity<AgentActivityAttributes>.activities { adopt(activity) }
        Task { [weak self] in
            for await activity in Activity<AgentActivityAttributes>.activityUpdates {
                self?.adopt(activity)
            }
        }
        if #available(iOS 17.2, *) {
            Task { [weak self] in
                for await data in Activity<AgentActivityAttributes>.pushToStartTokenUpdates {
                    self?.onStartToken?(Self.hex(data))
                }
            }
        }
    }

    // MARK: - Internals

    static func content(_ state: AgentContentState) -> ActivityContent<AgentContentState> {
        ActivityContent(state: state, staleDate: nil, relevanceScore: state.relevance)
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    /// End one this app owns. `watched` is false for a duplicate that was never
    /// adopted (nothing will report its end, so it mustn't wait in `ending`).
    private func finish(_ activity: Activity<AgentActivityAttributes>, watched: Bool = true) {
        if watched { ending.insert(activity.id) }
        let final = ActivityContent(state: activity.content.state, staleDate: nil)
        queue.enqueue { await activity.end(final, dismissalPolicy: .immediate) }
    }

    /// Take charge of an activity — one this app started, one left from an
    /// earlier launch, or one the server push-started.
    private func adopt(_ activity: Activity<AgentActivityAttributes>) {
        let id = activity.id
        guard watchers[id] == nil else { return }
        guard activity.activityState == .active || activity.activityState == .stale else { return }
        let agent = activity.attributes.agent
        if let existing = byAgent[agent], existing.id != id {
            finish(activity, watched: false)   // a second one for this agent: keep the first
            return
        }
        byAgent[agent] = activity
        let tokenTask = Task { [weak self] in
            for await data in activity.pushTokenUpdates {
                let hex = Self.hex(data)
                self?.tokens[id] = hex
                self?.onActivityToken?(agent, hex)
            }
        }
        let stateTask = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                if state == .ended || state == .dismissed {
                    self?.gone(activity)
                    return
                }
            }
        }
        watchers[id] = [tokenTask, stateTask]
    }

    private func gone(_ activity: Activity<AgentActivityAttributes>) {
        let id = activity.id, agent = activity.attributes.agent
        watchers.removeValue(forKey: id)?.forEach { $0.cancel() }
        let token = tokens.removeValue(forKey: id) ?? ""
        if byAgent[agent]?.id == id { byAgent[agent] = nil }
        if ending.remove(id) == nil {
            onEnded?(agent, token)
        }
    }
}

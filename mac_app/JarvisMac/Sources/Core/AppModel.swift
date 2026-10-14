import Foundation
import Observation

/// Everything the island, the menu bar and Settings show, fed by jc-client's
/// pushes over ui.sock. Also notices the moments that matter — a session that
/// starts waiting on you, finishes or fails — and tells the island and the
/// sound engine.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    enum Moment: Equatable { case needsYou, finished, failed, started }

    private(set) var connected = false
    private(set) var apiOrigin: String?
    private(set) var voiceDylib: String?
    private(set) var approvalsOn = false
    private(set) var instructionsOn = false
    private(set) var sessions: [MacSession] = []
    private(set) var pending: [MacPending] = []
    private(set) var usage: MacPlanUsage?
    private(set) var services: [[String: Any]] = []
    private(set) var portfolio: [String: Any] = [:]
    /// The session that just finished or failed, shown for a few seconds.
    private(set) var flash: MacSession?
    var selectedKey: String?
    /// While a demo runs, pushes from jc-client are ignored and restored after.
    var demoActive = false

    @ObservationIgnored var onMoment: ((Moment, MacSession?) -> Void)?
    @ObservationIgnored private var lastStates: [String: MacState] = [:]
    @ObservationIgnored private var flashTask: Task<Void, Never>?

    var lead: MacSession? { sessions.first { $0.state != .idle } }
    var waitingCount: Int { max(pending.count, sessions.filter { $0.state.urgency == 0 }.count) }
    var workingCount: Int { sessions.filter { $0.state == .working || $0.state == .thinking }.count }
    var mood: OrbMood { pending.isEmpty ? (lead?.state.mood ?? .idle) : .waiting }
    var selected: MacSession? { sessions.first { $0.key == selectedKey } ?? lead ?? sessions.first }

    func pendingFor(_ s: MacSession) -> MacPending? {
        pending.first { $0.fingerprint == s.pendingFingerprint } ?? pending.first { $0.key == s.key }
    }

    // MARK: link

    func attach(_ link: JcLink = .shared) {
        link.onMessage = { [weak self] msg in self?.handle(msg) }
        link.onConnection = { [weak self] up in
            self?.connected = up
            if up {
                link.request(["type": "subscribe", "topics": ["services": 0, "portfolio": 5]])
            }
        }
        link.start()
    }

    func handle(_ msg: [String: Any]) {
        guard !demoActive else { return }
        switch J.s(msg["type"]) {
        case "hello":
            apiOrigin = (msg["api"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            voiceDylib = msg["voice_dylib"] as? String
            approvalsOn = J.b(msg["approvals"])
            instructionsOn = J.b(msg["instructions"])
            apply(sessions: J.arr(msg["sessions"]), announce: false)
            pending = J.arr(msg["pending"]).compactMap(MacPending.init(json:))
        case "sessions":
            apply(sessions: J.arr(msg["sessions"]), announce: true)
        case "pending":
            let next = J.arr(msg["pending"]).compactMap(MacPending.init(json:))
            let fresh = next.contains { p in !pending.contains { $0.fingerprint == p.fingerprint } }
            pending = next
            if fresh { onMoment?(.needsYou, sessions.first { s in next.contains { $0.key == s.key } }) }
        case "usage":
            if let u = MacPlanUsage(json: msg) { usage = u }
        case "config":
            approvalsOn = J.b(msg["approvals"])
            instructionsOn = J.b(msg["instructions"])
        case "topic":
            let data = J.obj(msg["data"])
            switch J.s(msg["topic"]) {
            case "services": services = J.arr(data["services"])
            case "portfolio": portfolio = data
            default: break
            }
        default:
            break
        }
    }

    /// Replace the sessions (also used by the demo).
    func apply(sessions raw: [[String: Any]], announce: Bool) {
        let next = MacSession.sorted(raw.map(MacSession.init(json:)))
        if announce {
            for s in next {
                let before = lastStates[s.key]
                guard before != s.state else { continue }
                switch s.state {
                case .approval, .question:
                    // The arbiter's own "pending" push announces relayed requests.
                    if pending.isEmpty { onMoment?(.needsYou, s) }
                case .finished: showFlash(s); onMoment?(.finished, s)
                case .error: showFlash(s); onMoment?(.failed, s)
                case .thinking where before == nil || before == .idle: onMoment?(.started, s)
                default: break
                }
            }
        }
        lastStates = Dictionary(uniqueKeysWithValues: next.map { ($0.key, $0.state) })
        sessions = next
    }

    private func showFlash(_ s: MacSession) {
        flash = s
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { self?.flash = nil }
        }
    }

    // MARK: actions

    func decide(_ p: MacPending, _ decision: String, message: String? = nil,
                answers: [String: Any]? = nil, done: ((Bool) -> Void)? = nil) {
        var body: [String: Any] = ["type": "decide", "fingerprint": p.fingerprint, "decision": decision]
        if let message { body["message"] = message }
        if let answers { body["answers"] = answers }
        pending.removeAll { $0.fingerprint == p.fingerprint }
        JcLink.shared.request(body) { reply in done?(J.b(reply["ok"])) }
    }

    func hooks(_ action: String, agent: String = "claude", done: @escaping ([String: Any]) -> Void) {
        JcLink.shared.request(["type": "hooks", "action": action, "agent": agent], reply: done)
    }

    // MARK: demo support

    func setDemo(sessions raw: [[String: Any]], pending p: [[String: Any]]) {
        apply(sessions: raw, announce: true)
        pending = p.compactMap(MacPending.init(json:))
    }

    func endDemo() {
        demoActive = false
        sessions = []
        pending = []
        lastStates = [:]
        JcLink.shared.request(["type": "sessions"]) { [weak self] reply in
            self?.apply(sessions: J.arr(reply["sessions"]), announce: false)
        }
        JcLink.shared.request(["type": "pending"]) { [weak self] reply in
            self?.pending = J.arr(reply["pending"]).compactMap(MacPending.init(json:))
        }
    }
}

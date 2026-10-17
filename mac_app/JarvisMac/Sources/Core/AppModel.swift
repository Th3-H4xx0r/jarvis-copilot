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
    /// Codex's limits (jc-client reads them from `codex app-server` every 5 min).
    private(set) var codexUsage: MacPlanUsage?
    /// Devices and wearables for the menu (refreshed when it opens and every 45 s).
    private(set) var roster: MacRoster?
    /// What the harnesses handed to a bigger model, newest first (the server's
    /// `harness_jobs` feed): listed in the Agents tab with the sessions.
    private(set) var jobs: [MacJob] = []
    /// Sessions this Mac handed to the server while it slept ("On server").
    private(set) var onServer: [MacMovedSession] = []
    /// The session that just finished or failed, shown for a few seconds.
    private(set) var flash: MacSession?
    var selectedKey: String?
    /// While a demo runs, pushes from jc-client are ignored and restored after.
    var demoActive = false

    @ObservationIgnored var onMoment: ((Moment, MacSession?) -> Void)?
    /// Jarvis asked for a tab (the `jarvis_island` skill): tab, chat draft.
    @ObservationIgnored var onIsland: ((String, String?) -> Void)?
    /// Read a job's answer out: a voice hand-off finished after the push-to-talk
    /// turn that asked had ended (the server sends it to this Mac alone), or
    /// Read aloud in the Agents tab.
    @ObservationIgnored var onSpeak: ((MacJob) -> Void)?
    /// Jobs already read out: a feed sent again (a reconnect) doesn't repeat one.
    @ObservationIgnored private var spokenJobs: Set<String> = []
    @ObservationIgnored private var jobsPrune: Task<Void, Never>?
    @ObservationIgnored private var lastStates: [String: MacState] = [:]
    @ObservationIgnored private var flashTask: Task<Void, Never>?

    var lead: MacSession? { sessions.first { $0.state != .idle } }
    var waitingCount: Int { max(pending.count, sessions.filter { $0.state.urgency == 0 }.count) }
    var workingCount: Int {
        sessions.filter { $0.state == .working || $0.state == .thinking }.count + jobs.filter(\.running).count
    }
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
                link.request(["type": "subscribe", "topics": ["harness_jobs": 0]])
                self?.refreshRoster()
            }
        }
        link.start()
        PowerRelay.shared.start(link: link)
    }

    /// Bring a session that moved to the server back to this Mac: the server
    /// stops it there, merges the conversation back and reopens it here.
    func bringBack(_ ckey: String, link: JcLink? = .shared) {
        onServer.removeAll { $0.ckey == ckey }
        link?.request(["type": "agent_continue_mac", "ckey": ckey])
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
            if let u = MacPlanUsage(json: ["rate_limits": msg["usage"] ?? [:]]) { usage = u }
            onServer = J.arr(msg["moved"]).map(MacMovedSession.init(json:))
        case "moved":
            onServer = J.arr(msg["sessions"]).map(MacMovedSession.init(json:))
        case "sessions":
            apply(sessions: J.arr(msg["sessions"]), announce: true)
        case "pending":
            let next = J.arr(msg["pending"]).compactMap(MacPending.init(json:))
            let fresh = next.contains { p in !pending.contains { $0.fingerprint == p.fingerprint } }
            pending = next
            if fresh { onMoment?(.needsYou, sessions.first { s in next.contains { $0.key == s.key } }) }
        case "usage":
            if let u = MacPlanUsage(json: msg) {
                if J.s(msg["agent"]) == "codex" { codexUsage = u } else { usage = u }
            }
        case "island":
            onIsland?(J.s(msg["tab"], "agents"), msg["text"] as? String)
        case "config":
            approvalsOn = J.b(msg["approvals"])
            instructionsOn = J.b(msg["instructions"])
        case "topic":
            let data = J.obj(msg["data"])
            switch J.s(msg["topic"]) {
            case "harness_jobs":
                apply(jobs: J.arr(data["jobs"]))
                if let speak = data["speak"] as? [String: Any] { speakOnce(MacJob(json: speak)) }
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

    /// Replace the jobs: the feed is the whole list each time. An ended job
    /// leaves the list after `MacJob.shownFor`, even if nothing else changes.
    func apply(jobs raw: [[String: Any]], now: Date = Date()) {
        jobs = raw.map(MacJob.init(json:)).filter { !$0.id.isEmpty && !$0.expired(at: now) }
        jobsPrune?.cancel()
        guard let next = jobs.compactMap({ $0.completedAt?.addingTimeInterval(MacJob.shownFor) }).min() else { return }
        jobsPrune = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, next.timeIntervalSinceNow + 1)))
            guard !Task.isCancelled, let self else { return }
            let left = self.jobs.filter { !$0.expired(at: Date()) }
            if left.count != self.jobs.count { self.jobs = left }
        }
    }

    /// The server sends a voice job's answer once, but a resent feed must not
    /// read it out twice.
    private func speakOnce(_ job: MacJob) {
        guard !job.id.isEmpty, !job.result.isEmpty, spokenJobs.insert(job.id).inserted else { return }
        onSpeak?(job)
    }

    /// The Agents tab's Read aloud.
    func readAloud(_ job: MacJob) {
        guard !job.result.isEmpty else { return }
        onSpeak?(job)
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

    func refreshRoster() {
        JcLink.shared.request(["type": "roster"]) { [weak self] reply in
            if J.b(reply["ok"]) { self?.roster = MacRoster(json: reply) }
        }
    }

    /// What the old tray menu's items did: dashboard, voice_window, repair, logs, restart.
    func trayAction(_ action: String) {
        JcLink.shared.request(["type": "tray", "action": action])
    }

    func hooks(_ action: String, agent: String = "claude", token: String? = nil,
               done: @escaping ([String: Any]) -> Void) {
        var req: [String: Any] = ["type": "hooks", "action": action, "agent": agent]
        if let token { req["token"] = token }
        JcLink.shared.request(req, reply: done)
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

import Foundation

/// JSON helpers for the loosely-typed dicts that come over ui.sock.
enum J {
    static func s(_ v: Any?, _ fallback: String = "") -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return fallback
    }

    static func d(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    static func i(_ v: Any?) -> Int { Int(d(v) ?? 0) }
    static func b(_ v: Any?) -> Bool { (v as? Bool) ?? ((v as? NSNumber)?.boolValue ?? false) }
    static func obj(_ v: Any?) -> [String: Any] { v as? [String: Any] ?? [:] }
    static func arr(_ v: Any?) -> [[String: Any]] { (v as? [Any] ?? []).compactMap { $0 as? [String: Any] } }
}

/// What a session is doing, from its hooks (desktop_client/jc_client/agent_engine.py).
enum MacState: String {
    case idle, thinking, working, approval, question, ratelimit, finished, error

    var urgency: Int {
        switch self {
        case .approval, .question: return 0
        case .error: return 1
        case .ratelimit: return 2
        case .working, .thinking: return 3
        case .finished: return 4
        case .idle: return 5
        }
    }

    var mood: OrbMood {
        switch self {
        case .idle: return .idle
        case .thinking, .working: return .working
        case .approval, .question: return .waiting
        case .finished: return .finished
        case .error: return .error
        case .ratelimit: return .ratelimit
        }
    }

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .thinking: return "Thinking"
        case .working: return "Working"
        case .approval: return "Needs approval"
        case .question: return "Has a question"
        case .ratelimit: return "Rate-limited"
        case .finished: return "Finished"
        case .error: return "Failed"
        }
    }
}

struct MacFile: Identifiable, Equatable {
    let path: String
    let added: Int
    let removed: Int
    let lines: [(kind: Character, text: String)]
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }

    static func == (a: MacFile, b: MacFile) -> Bool {
        a.path == b.path && a.added == b.added && a.removed == b.removed && a.lines.count == b.lines.count
    }
}

/// One coding-agent session, as the local engine sees it.
struct MacSession: Identifiable, Equatable {
    let key: String
    let agent: String
    let sessionId: String
    let cwd: String
    let project: String
    let state: MacState
    let step: String
    let steps: [String]
    let startedAt: Date
    let lastEventAt: Date
    let terminalBundleId: String
    let termProgram: String
    let itermSession: String
    let tmux: String
    let pendingFingerprint: String
    let prompt: String
    let final: String
    let files: [MacFile]
    var id: String { key }

    var agentName: String { Self.displayName(agent) }

    static func displayName(_ agent: String) -> String {
        switch agent {
        case "claude": return "Claude Code"
        case "claude-desktop": return "Claude Desktop"
        case "codex": return "Codex"
        case "gemini": return "Gemini CLI"
        case "cursor": return "Cursor"
        case "copilot": return "Copilot CLI"
        case "opencode": return "OpenCode"
        case "amp": return "Amp"
        case "antigravity": return "Antigravity"
        case "muse": return "Muse Code"
        default: return agent.isEmpty ? "Agent" : agent.capitalized
        }
    }

    init(json: [String: Any]) {
        key = J.s(json["key"])
        agent = J.s(json["agent"], "claude")
        sessionId = J.s(json["session_id"])
        cwd = J.s(json["cwd"])
        let p = J.s(json["project"])
        project = p.isEmpty ? ((cwd as NSString).lastPathComponent.isEmpty ? "session" : (cwd as NSString).lastPathComponent) : p
        state = MacState(rawValue: J.s(json["state"])) ?? .idle
        step = J.s(json["step"])
        steps = J.arr(json["steps"]).map { J.s($0["t"]) }
        startedAt = Date(timeIntervalSince1970: J.d(json["started_at"]) ?? 0)
        lastEventAt = Date(timeIntervalSince1970: J.d(json["last_event_at"]) ?? 0)
        let term = J.obj(json["terminal"])
        terminalBundleId = J.s(term["bundle_id"])
        termProgram = J.s(term["term_program"])
        itermSession = J.s(term["iterm"])
        tmux = J.s(term["tmux"])
        pendingFingerprint = J.s(J.obj(json["pending"])["fingerprint"])
        let turn = J.obj(json["turn"])
        prompt = J.s(turn["prompt"])
        final = J.s(turn["final"])
        files = J.arr(turn["files"]).map { f in
            MacFile(path: J.s(f["path"]), added: J.i(f["added"]), removed: J.i(f["removed"]),
                    lines: J.arr(f["lines"]).map { (J.s($0["k"]).first ?? " ", J.s($0["t"])) })
        }
    }

    static func sorted(_ items: [MacSession]) -> [MacSession] {
        items.sorted { a, b in
            a.state.urgency != b.state.urgency ? a.state.urgency < b.state.urgency : a.lastEventAt > b.lastEventAt
        }
    }

    static func == (a: MacSession, b: MacSession) -> Bool {
        a.key == b.key && a.state == b.state && a.step == b.step && a.lastEventAt == b.lastEventAt
            && a.pendingFingerprint == b.pendingFingerprint && a.files == b.files
    }
}

/// A job a harness handed to a bigger model (the server's `harness_jobs` feed,
/// webui/api/harness_runner.py): the quick model said "I'll have a larger model
/// look into it", and this is that model at work — shown in the Agents tab
/// beside the coding sessions, with what was asked, its steps and its answer.
struct MacJob: Identifiable, Equatable {
    struct Step: Equatable {
        let text: String
        let detail: String
    }

    let id: String
    let sessionId: String
    let label: String
    let model: String
    let status: String
    let activity: String
    let steps: Int
    let startedAt: Date
    let completedAt: Date?
    /// What he asked (the turn's words), else the hand-off note.
    let task: String
    /// "voice" or "chat": how he asked.
    let surface: String
    /// The device he asked from, by its registered name.
    let device: String
    let trail: [Step]
    let result: String
    let error: String

    /// Its row's key in the Agents tab's selection (sessions use theirs).
    var key: String { "job:\(id)" }
    var running: Bool { status == "running" }

    var state: MacState {
        switch status {
        case "running": return .working
        case "done": return .finished
        case "failed", "lost": return .error
        default: return .idle
        }
    }

    /// "Claude" for the built-in node (its label is its id), else its label.
    var agentName: String {
        if label.isEmpty { return "Hand-off" }
        return label == label.lowercased() ? label.capitalized : label
    }

    /// The model without its provider: "claude-sonnet-5-5".
    var modelName: String {
        guard model.hasPrefix("@"), let colon = model.firstIndex(of: ":") else { return model }
        return String(model[model.index(after: colon)...])
    }

    var stateLabel: String {
        switch status {
        case "running": return "Working"
        case "done": return "Done"
        case "failed": return "Failed"
        case "lost": return "Cut short"
        case "stopped": return "Stopped"
        default: return status.capitalized
        }
    }

    /// The row's second line: what it's doing, or how it ended.
    var line: String {
        if running { return activity.isEmpty ? "Working on it" : activity }
        if !error.isEmpty && status == "failed" { return error }
        let first = result.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return first.isEmpty ? stateLabel : first
    }

    /// "By voice on Pranav's MacBook".
    var origin: String {
        let how = surface == "voice" ? "By voice" : surface == "chat" ? "In chat" : ""
        if device.isEmpty { return how }
        return how.isEmpty ? "From \(device)" : "\(how) on \(device)"
    }

    /// How long it ran (or has been running, by `now`).
    func elapsed(now: Date = Date()) -> String {
        let s = max(0, Int((completedAt ?? now).timeIntervalSince(startedAt)))
        return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
    }

    /// An ended job stays listed this long, like the server keeps it.
    static let shownFor: TimeInterval = 15 * 60

    func expired(at now: Date) -> Bool {
        guard let done = completedAt else { return false }
        return now.timeIntervalSince(done) > Self.shownFor
    }

    init(json: [String: Any]) {
        id = J.s(json["id"])
        sessionId = J.s(json["session_id"])
        label = J.s(json["label"])
        model = J.s(json["model"])
        status = J.s(json["status"], "running")
        activity = J.s(json["activity"])
        steps = J.i(json["steps"])
        startedAt = Date(timeIntervalSince1970: J.d(json["started_at"]) ?? 0)
        completedAt = J.d(json["completed_at"]).map { Date(timeIntervalSince1970: $0) }
        let asked = J.s(json["task"])
        task = asked.isEmpty ? J.s(json["note"]) : asked
        surface = J.s(json["surface"])
        device = J.s(json["device"])
        trail = J.arr(json["trail"]).map { Step(text: J.s($0["t"]), detail: J.s($0["detail"])) }
        result = J.s(json["result"])
        error = J.s(json["error"])
    }
}

struct MacQuestion: Equatable, Identifiable {
    let question: String
    let header: String
    let multiSelect: Bool
    let options: [String]
    let details: [String]
    var id: String { question }
}

/// An approval or question waiting in jc-client's arbiter.
struct MacPending: Identifiable, Equatable {
    let fingerprint: String
    let isQuestion: Bool
    let agent: String
    let key: String
    let project: String
    let tool: String
    let summary: String
    let command: String
    let canAlways: Bool
    let questions: [MacQuestion]
    var id: String { fingerprint }

    init?(json: [String: Any]) {
        fingerprint = J.s(json["fingerprint"])
        guard !fingerprint.isEmpty else { return nil }
        isQuestion = J.s(json["kind"]) == "ask"
        agent = J.s(json["agent"], "claude")
        key = J.s(json["key"])
        let cwd = J.s(json["cwd"])
        let p = J.s(json["project"])
        project = p.isEmpty ? (cwd as NSString).lastPathComponent : p
        tool = J.s(json["tool"])
        summary = J.s(json["summary"])
        command = J.s(json["command"])
        canAlways = J.b(json["can_always"])
        questions = J.arr(json["questions"]).map { q in
            let opts = J.arr(q["options"])
            return MacQuestion(question: J.s(q["question"]), header: J.s(q["header"]),
                               multiSelect: J.b(q["multiSelect"]),
                               options: opts.map { J.s($0["label"]) },
                               details: opts.map { J.s($0["description"]) })
        }
    }
}

/// The Claude plan's limits, from the status line (`rate_limits`).
struct MacPlanUsage: Equatable {
    /// One limit window: how much of it is used, and when it resets.
    struct Window: Equatable {
        let used: Int
        let resetsAt: Date
        /// What's used now — nothing once the window has reset.
        var usedNow: Int { resetsAt <= Date() ? 0 : used }
    }

    var five: Window?
    var week: Window?
    var fiveHour: Int? { five?.usedNow }
    var sevenDay: Int? { week?.usedNow }

    init?(json: [String: Any]) {
        let limits = J.obj(json["rate_limits"])
        func window(_ w: Any?) -> Window? {
            let o = J.obj(w)
            guard let used = J.d(o["used_percentage"]), let reset = J.d(o["resets_at"]) else { return nil }
            return Window(used: Int(min(100, max(0, used)).rounded()), resetsAt: Date(timeIntervalSince1970: reset))
        }
        five = window(limits["five_hour"])
        week = window(limits["seven_day"])
        if five == nil && week == nil { return nil }
    }
}

/// The week's recap from the server (`/api/coding/agents/recap`, agent/agent_recap.py).
struct MacRecap: Equatable {
    struct Highlight: Equatable { let icon: String; let label: String; let value: String }

    let minutes: Int
    let sessions: Int
    let files: Int
    let added: Int
    let removed: Int
    let commands: Int
    let approved: Int
    let denied: Int
    let answered: Int
    let highlights: [Highlight]

    var isEmpty: Bool { minutes == 0 }
    var time: String { Self.duration(minutes) }

    init(json: [String: Any]) {
        minutes = J.i(json["minutes"]); sessions = J.i(json["sessions"]); files = J.i(json["files"])
        added = J.i(json["added"]); removed = J.i(json["removed"]); commands = J.i(json["commands"])
        approved = J.i(json["approved"]); denied = J.i(json["denied"]); answered = J.i(json["answered"])
        var h: [Highlight] = []
        let agent = J.obj(json["top_agent"]), project = J.obj(json["top_project"])
        let day = J.obj(json["busiest_day"]), longest = J.obj(json["longest_session"])
        if let a = agent["agent"] as? String { h.append(.init(icon: "sparkles", label: "Top agent", value: MacSession.displayName(a))) }
        if let p = project["project"] as? String { h.append(.init(icon: "folder", label: "Top project", value: p)) }
        if let d = day["weekday"] as? String {
            h.append(.init(icon: "calendar", label: "Busiest day", value: "\(d) · \(Self.duration(J.i(day["minutes"])))"))
        }
        if let p = longest["project"] as? String {
            h.append(.init(icon: "timer", label: "Longest session", value: "\(p) · \(Self.duration(J.i(longest["minutes"])))"))
        }
        highlights = h
    }

    static func duration(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h > 0 && m > 0 { return "\(h)h \(m)m" }
        return h > 0 ? "\(h)h" : "\(m)m"
    }

    static func recapURL(origin: String, tzMinutes: Int = TimeZone.current.secondsFromGMT() / 60) -> URL? {
        URL(string: "\(origin)/api/coding/agents/recap?days=7&tz=\(tzMinutes)")
    }
}

/// The old tray menu's top half (jc-client's `roster` request): where Jarvis is
/// connected, the paired devices and the phone's wearables.
struct MacRoster: Equatable {
    struct Row: Equatable {
        let name: String
        let detail: String
        let online: Bool
        let header: Bool
        let symbol: String
        let image: String?
    }

    let server: String
    let connected: Bool
    let rows: [Row]

    var statusLine: String {
        server.isEmpty ? "Not paired" : (connected ? "Connected to \(server)" : "Reconnecting to \(server)…")
    }

    init(json: [String: Any]) {
        server = J.s(json["server"])
        connected = J.b(json["connected"])
        rows = J.arr(json["rows"]).map { r in
            Row(name: J.s(r["name"]), detail: J.s(r["detail"]), online: J.b(r["online"]), header: J.b(r["header"]),
                symbol: J.s(r["symbol"]), image: r["image"] as? String)
        }
    }
}

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

    var agentName: String {
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
    var fiveHour: Int?
    var sevenDay: Int?

    init?(json: [String: Any]) {
        let limits = J.obj(json["rate_limits"])
        func pct(_ w: Any?) -> Int? {
            let o = J.obj(w)
            guard let used = J.d(o["used_percentage"]), let reset = J.d(o["resets_at"]) else { return nil }
            return reset <= Date().timeIntervalSince1970 ? 0 : Int(min(100, max(0, used)).rounded())
        }
        fiveHour = pct(limits["five_hour"])
        sevenDay = pct(limits["seven_day"])
        if fiveHour == nil && sevenDay == nil { return nil }
    }
}

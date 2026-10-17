import Foundation

/// What a coding-agent session is doing, from its own hook events (server
/// `agent/agent_tracking.py`, engine `desktop_client/jc_client/agent_engine.py`).
enum AgentState: String, CaseIterable {
    case idle, thinking, working, approval, question, ratelimit, finished, error

    /// Lower is more urgent: what waits on you first.
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

    var waitsOnYou: Bool { self == .approval || self == .question }

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

enum AgentNames {
    static func display(_ agent: String) -> String {
        switch agent {
        case "claude": return "Claude Code"
        case "claude-desktop": return "Claude Desktop"
        case "codex": return "Codex"
        case "gemini": return "Gemini CLI"
        case "cursor": return "Cursor"
        case "copilot": return "Copilot CLI"
        case "antigravity": return "Antigravity"
        case "muse": return "Muse Code"
        case "opencode": return "OpenCode"
        case "amp": return "Amp"
        case "jarvis": return "Jarvis"
        default: return agent.isEmpty ? "Agent" : agent.capitalized
        }
    }

    /// The app a session runs in, from its terminal bundle id / TERM_PROGRAM.
    static func hostApp(bundleId: String, termProgram: String) -> String {
        let byBundle: [String: String] = [
            "com.apple.Terminal": "Terminal", "com.googlecode.iterm2": "iTerm",
            "dev.warp.Warp-Stable": "Warp", "com.mitchellh.ghostty": "Ghostty",
            "net.kovidgoyal.kitty": "kitty", "org.alacritty": "Alacritty",
            "com.github.wez.wezterm": "WezTerm", "dev.zed.Zed": "Zed",
            "com.microsoft.VSCode": "VS Code", "com.todesktop.230313mzl4w4u92": "Cursor",
        ]
        if let name = byBundle[bundleId] { return name }
        let program = termProgram.lowercased()
        if program.contains("vscode") { return "VS Code" }
        let byProgram: [String: String] = ["apple_terminal": "Terminal", "iterm.app": "iTerm",
                                           "warpterminal": "Warp", "ghostty": "Ghostty",
                                           "wezterm": "WezTerm", "kitty": "kitty"]
        return byProgram[program] ?? ""
    }
}

struct AgentStep: Equatable {
    let text: String
    let at: Date
}

struct AgentOption: Equatable, Identifiable {
    let label: String
    let detail: String
    var id: String { label }
}

struct AgentQuestion: Equatable, Identifiable {
    let question: String
    let header: String
    let multiSelect: Bool
    let options: [AgentOption]
    var id: String { question }

    init(json: [String: Any]) {
        question = CodingJSON.text(json["question"])
        header = CodingJSON.text(json["header"])
        multiSelect = CodingJSON.bool(json["multiSelect"])
        options = CodingJSON.maps(json["options"]).map {
            AgentOption(label: CodingJSON.text($0["label"]), detail: CodingJSON.text($0["description"]))
        }
    }
}

struct AgentTurnSummary: Equatable {
    let prompt: String
    let actions: Int
    let files: Int
    let added: Int
    let removed: Int
    let final: String
    let startedAt: Date?
    let endedAt: Date?

    init(json: [String: Any]) {
        prompt = CodingJSON.text(json["prompt"])
        actions = CodingJSON.int(json["actions"])
        files = CodingJSON.int(json["files"])
        added = CodingJSON.int(json["added"])
        removed = CodingJSON.int(json["removed"])
        final = CodingJSON.text(json["final"])
        startedAt = CodingJSON.double(json["started_at"]).map(Date.init(timeIntervalSince1970:))
        endedAt = CodingJSON.double(json["ended_at"]).map(Date.init(timeIntervalSince1970:))
    }
}

/// One row of the Agents list (the compact shape the `agents` topic carries).
struct AgentSessionItem: Identifiable, Equatable {
    let key: String
    let host: String
    let agent: String
    let sessionId: String
    let cwd: String
    let project: String
    let state: AgentState
    let step: String
    let steps: [AgentStep]
    let subagents: Int
    let model: String
    let hostApp: String
    let startedAt: Date
    let lastEventAt: Date
    let codingSessionId: String?
    let deviceId: String?
    let pendingFingerprint: String?
    let turnSummary: AgentTurnSummary?

    var id: String { key }
    var agentName: String { AgentNames.display(agent) }

    init(json: [String: Any]) {
        key = CodingJSON.text(json["key"])
        host = CodingJSON.text(json["host"])
        agent = CodingJSON.text(json["agent"], "claude")
        sessionId = CodingJSON.text(json["session_id"])
        cwd = CodingJSON.text(json["cwd"])
        let p = CodingJSON.text(json["project"])
        project = p.isEmpty ? (CodingJSON.basename(cwd).isEmpty ? "session" : CodingJSON.basename(cwd)) : p
        state = AgentState(rawValue: CodingJSON.text(json["state"])) ?? .idle
        step = CodingJSON.text(json["step"])
        steps = CodingJSON.maps(json["steps"]).map {
            AgentStep(text: CodingJSON.text($0["t"]),
                      at: Date(timeIntervalSince1970: CodingJSON.double($0["at"]) ?? 0))
        }
        subagents = CodingJSON.int(json["subagents"])
        model = CodingJSON.text(json["model"])
        let term = CodingJSON.dict(json["terminal"]) ?? [:]
        hostApp = AgentNames.hostApp(bundleId: CodingJSON.text(term["bundle_id"]),
                                     termProgram: CodingJSON.text(term["term_program"]))
        startedAt = Date(timeIntervalSince1970: CodingJSON.double(json["started_at"]) ?? 0)
        lastEventAt = Date(timeIntervalSince1970: CodingJSON.double(json["last_event_at"]) ?? 0)
        codingSessionId = CodingJSON.str(json["coding_session_id"])
        deviceId = CodingJSON.str(json["device_id"])
        let pending = CodingJSON.dict(json["pending"])
        pendingFingerprint = pending.flatMap { CodingJSON.str($0["fingerprint"]) }
        turnSummary = CodingJSON.dict(json["turn_summary"]).map(AgentTurnSummary.init(json:))
    }
}

/// An approval or a question waiting on you (`GET /api/coding/permission/pending`).
struct AgentRequest: Identifiable, Equatable {
    enum Kind: Equatable { case approval, question }

    let requestId: String
    let fingerprint: String
    let kind: Kind
    let tool: String
    let summary: String
    let command: String
    let project: String
    let key: String
    let agent: String
    let canAlways: Bool
    let questions: [AgentQuestion]
    let created: Date

    var id: String { requestId }
    var agentName: String { AgentNames.display(agent) }

    static func from(_ raw: Any?) -> AgentRequest? {
        guard let j = raw as? [String: Any] else { return nil }
        let rid = CodingJSON.text(j["request_id"])
        guard !rid.isEmpty else { return nil }
        return AgentRequest(
            requestId: rid, fingerprint: CodingJSON.text(j["fingerprint"]),
            kind: CodingJSON.text(j["kind"]) == "ask" ? .question : .approval,
            tool: CodingJSON.text(j["tool"], "tool"), summary: CodingJSON.text(j["summary"]),
            command: CodingJSON.text(j["command"]), project: CodingJSON.text(j["project"]),
            key: CodingJSON.text(j["key"]), agent: CodingJSON.text(j["agent"], "claude"),
            canAlways: CodingJSON.bool(j["can_always"]),
            questions: CodingJSON.maps(j["questions"]).map(AgentQuestion.init(json:)),
            created: Date(timeIntervalSince1970: CodingJSON.double(j["created"]) ?? 0))
    }
}

struct AgentDiffLine: Equatable {
    enum Kind: Equatable { case context, added, removed, gap }
    let kind: Kind
    let text: String
}

struct AgentFileDiff: Identifiable, Equatable {
    let path: String
    let added: Int
    let removed: Int
    let isNew: Bool
    let truncated: Bool
    let lines: [AgentDiffLine]
    var id: String { path }
    var name: String { CodingJSON.basename(path).isEmpty ? path : CodingJSON.basename(path) }

    init(json: [String: Any]) {
        path = CodingJSON.text(json["path"])
        added = CodingJSON.int(json["added"])
        removed = CodingJSON.int(json["removed"])
        isNew = CodingJSON.bool(json["new"])
        truncated = CodingJSON.bool(json["truncated"])
        lines = CodingJSON.maps(json["lines"]).map {
            let kind: AgentDiffLine.Kind
            switch CodingJSON.text($0["k"]) {
            case "+": kind = .added
            case "-": kind = .removed
            case "@": kind = .gap
            default: kind = .context
            }
            return AgentDiffLine(kind: kind, text: CodingJSON.text($0["t"]))
        }
    }
}

struct AgentAction: Identifiable, Equatable {
    let index: Int
    let tool: String
    let summary: String
    let output: String
    let failed: Bool
    let at: Date
    let fileIndex: Int?
    var id: Int { index }
}

/// The last turn: what you asked, what the agent did, the files it changed, its answer.
struct AgentTurn: Equatable {
    let prompt: String
    let actions: [AgentAction]
    let files: [AgentFileDiff]
    let final: String
    let startedAt: Date?
    let endedAt: Date?

    var duration: TimeInterval? {
        guard let s = startedAt, let e = endedAt else { return nil }
        return e.timeIntervalSince(s)
    }

    init(json: [String: Any]) {
        prompt = CodingJSON.text(json["prompt"])
        actions = CodingJSON.maps(json["actions"]).enumerated().map { i, a in
            AgentAction(index: i, tool: CodingJSON.text(a["tool"], "Tool"),
                        summary: CodingJSON.text(a["summary"]), output: CodingJSON.text(a["output"]),
                        failed: CodingJSON.bool(a["failed"]),
                        at: Date(timeIntervalSince1970: CodingJSON.double(a["at"]) ?? 0),
                        fileIndex: a["file"].flatMap { $0 is NSNull ? nil : CodingJSON.int($0) })
        }
        files = CodingJSON.maps(json["files"]).map(AgentFileDiff.init(json:))
        final = CodingJSON.text(json["final"])
        startedAt = CodingJSON.double(json["started_at"]).map(Date.init(timeIntervalSince1970:))
        endedAt = CodingJSON.double(json["ended_at"]).map(Date.init(timeIntervalSince1970:))
    }
}

/// One session in full (`GET /api/coding/agents/session?key=`).
struct AgentSessionDetail: Equatable {
    let item: AgentSessionItem
    let turn: AgentTurn?

    init(json: [String: Any]) {
        item = AgentSessionItem(json: json)
        turn = CodingJSON.dict(json["turn"]).map(AgentTurn.init(json:))
    }
}

struct AgentPlanWindow: Equatable {
    let usedPercent: Double
    let resetsAt: Date
    /// 0 once the window has reset, else the reported use (clamped to 100).
    var percent: Int { resetsAt <= Date() ? 0 : Int(min(100, max(0, usedPercent)).rounded()) }

    init?(json: Any?) {
        guard let j = json as? [String: Any], let used = CodingJSON.double(j["used_percentage"]),
              let reset = CodingJSON.double(j["resets_at"]), reset > 0 else { return nil }
        usedPercent = used
        resetsAt = Date(timeIntervalSince1970: reset)
    }
}

/// The Claude plan's 5-hour and weekly limits, as Claude Code reports them.
struct AgentPlanUsage: Equatable {
    let fiveHour: AgentPlanWindow?
    let sevenDay: AgentPlanWindow?

    init?(json: [String: Any]?) {
        guard let json else { return nil }
        fiveHour = AgentPlanWindow(json: json["five_hour"])
        sevenDay = AgentPlanWindow(json: json["seven_day"])
        if fiveHour == nil && sevenDay == nil { return nil }
    }
}

/// The week's recap (`GET /api/coding/agents/recap`, built by agent/agent_recap.py):
/// time with overlapping turns counted once, and what the agents got done.
struct AgentRecap: Equatable {
    let minutes: Int
    let sessions: Int
    let files: Int
    let added: Int
    let removed: Int
    let commands: Int
    let approved: Int
    let denied: Int
    let answered: Int
    let topAgent: String?
    let topProject: String?
    let busiestDay: String?
    let busiestMinutes: Int
    let longest: String?
    let summary: String?

    var isEmpty: Bool { minutes == 0 }
    var time: String { Self.duration(minutes) }

    init(json: [String: Any]) {
        func int(_ k: String) -> Int { Int(CodingJSON.double(json[k]) ?? 0) }
        minutes = int("minutes"); sessions = int("sessions"); files = int("files")
        added = int("added"); removed = int("removed"); commands = int("commands")
        approved = int("approved"); denied = int("denied"); answered = int("answered")
        topAgent = (CodingJSON.dict(json["top_agent"])?["agent"] as? String).map(AgentNames.display)
        topProject = CodingJSON.dict(json["top_project"])?["project"] as? String
        let day = CodingJSON.dict(json["busiest_day"])
        busiestDay = day?["weekday"] as? String
        busiestMinutes = Int(CodingJSON.double(day?["minutes"]) ?? 0)
        if let l = CodingJSON.dict(json["longest_session"]), let project = l["project"] as? String {
            longest = "\(project) · \(Self.duration(Int(CodingJSON.double(l["minutes"]) ?? 0)))"
        } else {
            longest = nil
        }
        summary = json["summary"] as? String
    }

    static func duration(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h > 0 && m > 0 { return "\(h)h \(m)m" }
        return h > 0 ? "\(h)h" : "\(m)m"
    }
}

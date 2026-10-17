import Foundation

// The merged Agents tab's data (`GET /api/coding/agents/list`, pushed on the
// `agents_list` bridge topic, built by `webui/api/agents_core.py`): one record
// per conversation whichever machine runs it, the Mac-asleep card, what waits
// on you, and every other session grouped by project.

/// Where a conversation is, from the server's session record.
enum AgentConvStatus: String, Equatable {
    /// Running on its owner right now.
    case live
    /// Its Mac said it was going to sleep.
    case asleep
    /// Its Mac dropped without saying so.
    case offline
    /// A Continue is moving it between the Mac and the server.
    case moving
    /// The process is gone (kept for 12 h with Resume).
    case ended

    static func from(_ raw: String) -> AgentConvStatus { AgentConvStatus(rawValue: raw) ?? .live }
}

/// What a session waits on, as its hooks reported it (the tracker's compact
/// `pending`). The card itself comes from `/permission/pending`, which carries
/// the request id a verdict needs.
struct AgentPending: Equatable {
    let kind: String
    let tool: String
    let summary: String
    let fingerprint: String
    let questions: [AgentQuestion]

    var isQuestion: Bool { kind == "question" || kind == "ask" }

    init?(json: [String: Any]?) {
        guard let json else { return nil }
        kind = CodingJSON.str(json["kind"]) ?? "approval"
        tool = CodingJSON.text(json["tool"])
        summary = CodingJSON.text(json["summary"])
        fingerprint = CodingJSON.text(json["fingerprint"])
        questions = CodingJSON.maps(json["questions"]).map(AgentQuestion.init(json:))
    }
}

/// One conversation (a row of the list).
struct AgentConv: Identifiable, Equatable {
    /// `agent|session_id` — the record's identity for every `/agents/*` call.
    let ckey: String
    /// The hook tracker's key (`host|agent|sid`) — approvals and pushes use it.
    let key: String?
    let agent: String
    let sessionId: String
    let title: String
    let projectId: String?
    let project: String
    let cwd: String
    /// "server" or the Mac's device id.
    let owner: String
    /// "Server", or the Mac's name ("MacBook").
    let ownerName: String
    let status: AgentConvStatus
    /// What its hooks say while it is live; `.idle` otherwise.
    let state: AgentState
    let step: String
    let pending: AgentPending?
    let turnSummary: AgentTurnSummary?
    let model: String
    let lastEventAt: Date
    /// The terminal it runs in, as TERM_PROGRAM said ("vscode", "iTerm.app"…).
    let terminalApp: String
    let canContinueServer: Bool
    let canContinueMac: Bool
    let canResume: Bool
    let canSend: Bool
    let canTerminal: Bool
    let movedFrom: String?
    let movedFromName: String
    /// The last few messages sent to it (past hour) and what became of each —
    /// how a "Sent" bubble learns it was typed, queued, delivered or refused.
    let deliveries: [AgentDelivery]

    var id: String { ckey }
    var agentName: String { AgentNames.display(agent) }
    var onServer: Bool { owner == "server" }
    var isLive: Bool { status == .live }
    /// Waiting on an approval or a question right now.
    var waitsOnYou: Bool { status == .live && (pending != nil || state.waitsOnYou) }

    init(json: [String: Any]) {
        ckey = CodingJSON.text(json["ckey"])
        key = CodingJSON.str(json["key"])
        agent = CodingJSON.str(json["agent"]) ?? "claude"
        sessionId = CodingJSON.text(json["session_id"])
        cwd = CodingJSON.text(json["cwd"])
        let p = CodingJSON.text(json["project"])
        project = p.isEmpty ? CodingJSON.basename(cwd) : p
        let t = CodingJSON.text(json["title"])
        title = t.isEmpty ? (project.isEmpty ? "Session" : project) : t
        projectId = CodingJSON.str(json["project_id"])
        owner = CodingJSON.str(json["owner"]) ?? "server"
        ownerName = CodingJSON.str(json["owner_name"]) ?? (owner == "server" ? "Server" : "Mac")
        status = AgentConvStatus.from(CodingJSON.text(json["status"], "live"))
        state = status == .live ? (AgentState(rawValue: CodingJSON.text(json["state"])) ?? .idle) : .idle
        step = CodingJSON.text(json["step"])
        pending = AgentPending(json: CodingJSON.dict(json["pending"]))
        turnSummary = CodingJSON.dict(json["turn_summary"]).map(AgentTurnSummary.init(json:))
        model = CodingJSON.text(json["model"])
        lastEventAt = Date(timeIntervalSince1970: CodingJSON.double(json["last_event_at"]) ?? 0)
        terminalApp = CodingJSON.text(json["terminal_app"])
        canContinueServer = CodingJSON.bool(json["can_continue_server"])
        canContinueMac = CodingJSON.bool(json["can_continue_mac"])
        canResume = CodingJSON.bool(json["can_resume"])
        canSend = CodingJSON.bool(json["can_send"])
        canTerminal = CodingJSON.bool(json["can_terminal"])
        movedFrom = CodingJSON.str(json["moved_from"])
        movedFromName = CodingJSON.text(json["moved_from_name"])
        deliveries = CodingJSON.maps(json["deliveries"]).map(AgentDelivery.init(json:)).filter { !$0.id.isEmpty }
    }
}

/// One session the Mac-asleep card lists.
struct AgentCardSession: Identifiable, Equatable {
    let ckey: String
    let title: String
    let project: String
    /// The state it was in when the Mac went: working, approval, question, idle…
    let was: String
    let agent: String
    var id: String { ckey }

    init(json: [String: Any]) {
        ckey = CodingJSON.text(json["ckey"])
        let p = CodingJSON.text(json["project"])
        project = p
        let t = CodingJSON.text(json["title"])
        title = t.isEmpty ? (p.isEmpty ? "Session" : p) : t
        was = CodingJSON.str(json["was"]) ?? "idle"
        agent = CodingJSON.str(json["agent"]) ?? "claude"
    }
}

/// "☾ MacBook went to sleep": the sessions a Mac left behind, until each is
/// continued or dismissed, or the Mac wakes.
struct AgentSleepCard: Equatable {
    enum Kind: String, Equatable { case sleep, offline }

    let deviceId: String
    let deviceName: String
    let kind: Kind
    let since: Date?
    let sessions: [AgentCardSession]

    init?(json: [String: Any]?) {
        guard let json else { return nil }
        deviceId = CodingJSON.text(json["device_id"])
        deviceName = CodingJSON.str(json["device_name"]) ?? "Your Mac"
        kind = Kind(rawValue: CodingJSON.text(json["kind"])) ?? .sleep
        since = CodingJSON.double(json["since"]).map(Date.init(timeIntervalSince1970:))
        sessions = CodingJSON.maps(json["sessions"]).map(AgentCardSession.init(json:))
            .filter { !$0.ckey.isEmpty }
    }
}

/// One project's group of sessions.
struct AgentProjectGroup: Identifiable, Equatable {
    let projectId: String?
    let name: String
    let sessions: [AgentConv]

    /// Stable across pushes: the project id, else (a folder with no project
    /// record) its name — what the collapsed state is kept under.
    var id: String { projectId ?? "name:\(name)" }

    init(projectId: String?, name: String, sessions: [AgentConv]) {
        self.projectId = projectId
        self.name = name
        self.sessions = sessions
    }

    init(json: [String: Any]) {
        let sessions = CodingJSON.maps(json["sessions"]).map(AgentConv.init(json:)).filter { !$0.ckey.isEmpty }
        let name = CodingJSON.text(json["name"])
        self.init(projectId: CodingJSON.str(json["id"]),
                  name: name.isEmpty ? (sessions.first?.project ?? "Other") : name,
                  sessions: sessions)
    }
}

/// The whole list, as one fetch or one push.
struct AgentsList: Equatable {
    var card: AgentSleepCard?
    var needsYou: [AgentConv]
    var projects: [AgentProjectGroup]
    var usage: AgentPlanUsage?
    var codexUsage: AgentPlanUsage?
    var ts: Double

    init(card: AgentSleepCard? = nil, needsYou: [AgentConv] = [], projects: [AgentProjectGroup] = [],
         usage: AgentPlanUsage? = nil, codexUsage: AgentPlanUsage? = nil, ts: Double = 0) {
        self.card = card
        self.needsYou = needsYou
        self.projects = projects
        self.usage = usage
        self.codexUsage = codexUsage
        self.ts = ts
    }

    init(json: [String: Any]) {
        let card = AgentSleepCard(json: CodingJSON.dict(json["card"]))
        self.init(card: (card?.sessions.isEmpty ?? true) ? nil : card,
                  needsYou: CodingJSON.maps(json["needs_you"]).map(AgentConv.init(json:)).filter { !$0.ckey.isEmpty },
                  projects: CodingJSON.maps(json["projects"]).map(AgentProjectGroup.init(json:))
                    .filter { !$0.sessions.isEmpty },
                  usage: AgentPlanUsage(json: CodingJSON.dict(json["usage"])),
                  codexUsage: AgentPlanUsage(json: CodingJSON.dict(json["usage_codex"])),
                  ts: CodingJSON.double(json["ts"]) ?? 0)
    }

    /// Every conversation once: what needs you, then each project's.
    var all: [AgentConv] { needsYou + projects.flatMap(\.sessions) }

    func conv(_ ckey: String) -> AgentConv? { all.first { $0.ckey == ckey } }

    var isEmpty: Bool { card == nil && needsYou.isEmpty && projects.isEmpty }
}

/// What became of a message sent from the phone (`POST /agents/send`).
struct AgentDelivery: Equatable {
    enum State: String, Equatable { case sent, queued, delivered, failed }

    let id: String
    let state: State
    let reason: String?

    init(id: String = "", state: State, reason: String? = nil) {
        self.id = id
        self.state = state
        self.reason = reason
    }

    init(json: [String: Any]) {
        id = CodingJSON.text(json["id"])
        state = State(rawValue: CodingJSON.text(json["state"])) ?? .failed
        reason = CodingJSON.str(json["reason"])
    }
}

/// One session's answer to `POST /agents/continue`.
struct AgentContinueResult: Equatable {
    let ok: Bool
    let reason: String?
    let error: String?

    /// The Mac went offline without sleeping, so it may still run the session:
    /// ask before moving it.
    var needsConfirmation: Bool { reason == "confirm_offline" }

    init(ok: Bool, reason: String? = nil, error: String? = nil) {
        self.ok = ok
        self.reason = reason
        self.error = error
    }

    init(json: [String: Any]) {
        ok = CodingJSON.bool(json["ok"])
        reason = CodingJSON.str(json["reason"])
        error = CodingJSON.str(json["error"])
    }
}

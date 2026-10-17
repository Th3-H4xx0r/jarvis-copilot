import Foundation

// The merged list's pure rules: what each row and the Mac-asleep card say,
// which project groups start open, which approval card belongs to which row,
// and why a session can't take a message. No state, no clock, no networking,
// so every rule is unit tested (`JarvisCopilotTests/Agents/AgentsListTests.swift`).

enum AgentsListLayout {

    // MARK: rows

    /// Where it runs: "Server", "MacBook", "MacBook (asleep)", "MacBook (offline)".
    static func whereLabel(_ c: AgentConv) -> String {
        if c.onServer { return "Server" }
        let name = c.ownerName.isEmpty ? "Mac" : c.ownerName
        switch c.status {
        case .asleep: return "\(name) (asleep)"
        case .offline: return "\(name) (offline)"
        default: return name
        }
    }

    /// "Claude Code · Server" in a project group; "jarvis-copilot · Claude Code ·
    /// Server" under Needs you, where the project isn't the heading.
    static func subtitle(_ c: AgentConv, showsProject: Bool) -> String {
        var parts: [String] = []
        if showsProject && !c.project.isEmpty && c.project != c.title { parts.append(c.project) }
        parts.append(c.agentName)
        parts.append(whereLabel(c))
        return parts.joined(separator: " · ")
    }

    /// The row's third line: what it waits on, what it's doing, or nil.
    static func detail(_ c: AgentConv, request: AgentRequest?) -> AgentRowDetail? {
        switch c.status {
        case .asleep, .offline:
            return nil
        case .moving:
            return AgentRowDetail(text: c.onServer ? "Moving to the Mac…" : "Moving to the server…", tone: .quiet)
        case .ended:
            return AgentRowDetail(text: "Ended", tone: .quiet)
        case .live:
            break
        }
        if let request { return AgentRowDetail(text: AgentsPresentation.ask(request), tone: .waiting) }
        if let p = c.pending { return AgentRowDetail(text: ask(p), tone: .waiting) }
        switch c.state {
        case .approval: return AgentRowDetail(text: "Needs approval", tone: .waiting)
        case .question: return AgentRowDetail(text: "Has a question", tone: .waiting)
        case .working, .thinking:
            return AgentRowDetail(text: AgentsPresentation.liveStep(c.step), tone: .working)
        case .error:
            let step = AgentsPresentation.firstLine(c.step)
            return AgentRowDetail(text: step.isEmpty ? "Stopped with an error" : step, tone: .failed)
        case .ratelimit:
            return AgentRowDetail(text: "Paused until the plan limit resets", tone: .quiet)
        case .finished, .idle:
            if c.onServer, !c.movedFromName.isEmpty { return AgentRowDetail(text: "Moved from \(c.movedFromName)", tone: .quiet) }
            return nil
        }
    }

    /// One line for what the hooks say it waits on, before its card has loaded.
    static func ask(_ p: AgentPending) -> String {
        if p.isQuestion {
            let q = AgentsPresentation.firstLine(p.questions.first?.question ?? "")
            return q.isEmpty ? "Has a question" : q
        }
        guard !p.summary.isEmpty || !p.tool.isEmpty else { return "Needs approval" }
        let line = AgentToolPhrase.line(tool: p.tool, summary: p.summary, tense: .imperative)
        return "Wants to \(line.text)"
    }

    /// The status mark: the hook state while live, the moon while its Mac sleeps.
    static func status(_ c: AgentConv, request: AgentRequest?) -> AgentRowStatus {
        switch c.status {
        case .asleep, .offline: return .paused
        case .moving: return .moving
        case .ended: return .ended
        case .live: return AgentRowStatus.of(c.state, waiting: request != nil || c.pending != nil)
        }
    }

    /// The pill in a session's top bar.
    static func statusLabel(_ c: AgentConv, request: AgentRequest?) -> String {
        switch c.status {
        case .asleep: return "Mac asleep"
        case .offline: return "Mac offline"
        case .moving: return "Moving"
        case .ended: return "Ended"
        case .live:
            if request == nil, let p = c.pending { return p.isQuestion ? "Has a question" : "Needs approval" }
            return AgentRowStatus.label(c.state, request: request)
        }
    }

    // MARK: the Mac-asleep card

    /// "MacBook went to sleep" / "MacBook went offline".
    static func cardTitle(_ card: AgentSleepCard) -> String {
        card.kind == .sleep ? "\(card.deviceName) went to sleep" : "\(card.deviceName) went offline"
    }

    /// What a paused session was doing when its Mac went.
    static func was(_ state: String) -> String {
        switch state {
        case "working", "thinking": return "was working"
        case "approval", "question": return "was waiting on you"
        case "ratelimit": return "was rate-limited"
        case "error": return "had stopped with an error"
        default: return "idle"
        }
    }

    /// "jarvis-copilot · was working".
    static func cardLine(_ s: AgentCardSession) -> String {
        let was = was(s.was)
        return s.project.isEmpty ? was.prefix(1).uppercased() + was.dropFirst() : "\(s.project) · \(was)"
    }

    /// The card's bottom button: one session needs no "all".
    static func continueAllTitle(_ card: AgentSleepCard) -> String? {
        switch card.sessions.count {
        case 0, 1: return nil
        case 2: return "Continue both on server"
        default: return "Continue all on server"
        }
    }

    /// Asked before an offline Mac's sessions move: it may still be running them.
    static func offlineWarning(_ deviceName: String, count: Int) -> String {
        let what = count == 1 ? "this session" : "these sessions"
        return "\(deviceName) went offline without going to sleep, so it may still be running \(what). "
            + "Continuing on the server could leave two copies running."
    }

    // MARK: Needs you and projects

    /// Needs you: newest first, as the list reads everywhere else.
    static func needsYou(_ list: AgentsList) -> [AgentConv] {
        list.needsYou.sorted { $0.lastEventAt > $1.lastEventAt }
    }

    /// Something in this project waits on you — its own row, or one of its
    /// sessions under Needs you.
    static func hasWaiting(_ group: AgentProjectGroup, needsYou: [AgentConv]) -> Bool {
        if group.sessions.contains(where: \.waitsOnYou) { return true }
        return needsYou.contains { c in
            if let pid = group.projectId { return c.projectId == pid }
            return c.projectId == nil && c.project == group.name
        }
    }

    /// A project opens on its own while something in it waits on you; otherwise
    /// it stays the way it was last left.
    static func isExpanded(_ group: AgentProjectGroup, collapsed: Set<String>, needsYou: [AgentConv]) -> Bool {
        hasWaiting(group, needsYou: needsYou) || !collapsed.contains(group.id)
    }

    /// The collapsed project ids, kept as one `@AppStorage` string.
    static func collapsed(from raw: String) -> Set<String> {
        Set(raw.split(separator: "\n").map(String.init).filter { !$0.isEmpty })
    }

    static func encode(_ collapsed: Set<String>) -> String {
        collapsed.sorted().joined(separator: "\n")
    }

    // MARK: approval cards

    /// The tracker key a push or Spotlight item carries (`host|agent|sid`) as the
    /// conversation key (`agent|sid`); a key that already is one passes through.
    static func ckey(fromKey key: String) -> String {
        let parts = key.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return key }
        return parts.suffix(2).joined(separator: "|")
    }

    static func matches(_ request: AgentRequest, _ c: AgentConv) -> Bool {
        if let key = c.key, !key.isEmpty, key == request.key { return true }
        if !request.key.isEmpty, ckey(fromKey: request.key) == c.ckey { return true }
        if let fp = c.pending?.fingerprint, !fp.isEmpty, fp == request.fingerprint { return true }
        return false
    }

    static func request(for c: AgentConv, in requests: [AgentRequest]) -> AgentRequest? {
        requests.first { matches($0, c) }
    }

    /// Cards whose session isn't in the list — shown on their own under Needs
    /// you so none is unreachable.
    static func orphans(_ requests: [AgentRequest], list: AgentsList) -> [AgentRequest] {
        let all = list.all
        return requests.filter { r in !all.contains { matches(r, $0) } }
    }

    /// The number beside "Needs you": its rows plus the cards without one.
    static func waitingCount(_ list: AgentsList, requests: [AgentRequest]) -> Int {
        list.needsYou.count + orphans(requests, list: list).count
    }

    // MARK: the open chat

    /// What the open chat refetches on: changes when something new may be in
    /// the server's transcript copy. Every hook moves `lastEventAt`. A Mac
    /// session's lines reach the server just after the hook that pushed the
    /// list (the hook pokes the shipper) and move nothing in the row, so for a
    /// short while after its own event every push counts — otherwise a turn's
    /// last answer stays missing until something else happens. A server
    /// session writes its transcript before its hooks fire.
    static func transcriptReloadKey(_ c: AgentConv?, listTs: Double) -> String {
        guard let c else { return "" }
        let last = c.lastEventAt.timeIntervalSince1970
        let shipping = c.status == .live && !c.onServer && listTs >= last
            && listTs - last <= transcriptCatchUp
        return shipping ? "\(last)|\(listTs)" : "\(last)"
    }

    /// How long after a Mac session's hook its transcript lines can still be
    /// on their way to the server (seconds).
    static let transcriptCatchUp: Double = 15

    // MARK: sending

    /// Why the message box is replaced, or nil when the session takes messages.
    static func cantSendReason(_ c: AgentConv) -> String? {
        // A message now would be typed into its approval / question menu, and
        // the Return picks the highlighted "Yes" — an approval without Face ID.
        // The card above answers it.
        if c.waitsOnYou {
            let question = c.pending.map(\.isQuestion) ?? (c.state == .question)
            return question ? "Answer the question above first." : "Allow or deny the request above first."
        }
        guard !c.canSend else { return nil }
        let name = c.ownerName.isEmpty || c.onServer ? "This Mac" : c.ownerName
        switch c.status {
        case .asleep: return "\(name) is asleep."
        case .offline: return "\(name) is offline."
        case .moving: return c.onServer ? "It’s moving to the Mac…" : "It’s moving to the server…"
        case .ended: return "This session has ended."
        case .live:
            let app = AgentNames.hostApp(bundleId: "", termProgram: c.terminalApp)
            let where_ = app.isEmpty ? "a terminal Jarvis can’t type into" : app
            return "Can’t send here: it’s idle in \(where_). Reply there, or wait until it’s working."
        }
    }
}

/// The phone's copy of the collapsed project groups.
enum AgentsListPrefs {
    static let collapsedKey = "jc.agents.collapsedProjects"
}

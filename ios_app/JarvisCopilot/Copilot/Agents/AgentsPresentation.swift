import SwiftUI

// The Agents tab's pure presentation rules: how a session's state reads at a
// glance, how the list is grouped, what a row says, what a failed send means,
// and whether a session screen shows the full transcript or the agent's own
// last turn. No state, no clock and no networking, so every rule is unit
// tested (`JarvisCopilotTests/Agents/AgentsPresentationTests.swift`).

// MARK: - Status

/// The quiet status mark on a row and the pill in a session's top bar: a
/// spinner while it works, a checkmark when it finished, an amber dot while it
/// waits on you.
enum AgentRowStatus: Equatable {
    case waiting, working, finished, failed, rateLimited, idle

    /// A request waiting on you wins over whatever the hooks last said: the
    /// card is what the person has to act on.
    static func of(_ state: AgentState, waiting: Bool) -> AgentRowStatus {
        if waiting || state.waitsOnYou { return .waiting }
        switch state {
        case .working, .thinking: return .working
        case .finished: return .finished
        case .error: return .failed
        case .ratelimit: return .rateLimited
        case .idle, .approval, .question: return .idle
        }
    }

    /// The pill's words — more specific than the status, so "Has a question"
    /// and "Needs approval" read differently.
    static func label(_ state: AgentState, request: AgentRequest?) -> String {
        if let request { return request.kind == .question ? "Has a question" : "Needs approval" }
        switch state {
        case .approval: return "Needs approval"
        case .question: return "Has a question"
        case .thinking: return "Thinking"
        case .working: return "Working"
        case .finished: return "Finished"
        case .error: return "Failed"
        case .ratelimit: return "Rate-limited"
        case .idle: return "Idle"
        }
    }

    var color: Color {
        switch self {
        case .waiting: return JcTheme.amber
        case .working: return JcTheme.accent
        case .finished: return JcTheme.success
        case .failed: return JcTheme.danger
        case .rateLimited: return JcTheme.muted
        case .idle: return CodingUI.grey
        }
    }
}

// MARK: - Grouping

/// One section of the sessions list.
struct AgentListSection: Identifiable, Equatable {
    enum Kind: String, CaseIterable {
        case needsYou, working, recent

        var title: String {
            switch self {
            case .needsYou: return "Needs you"
            case .working: return "Working"
            case .recent: return "Recent"
            }
        }
    }

    let kind: Kind
    let sessions: [AgentSessionItem]
    var id: String { kind.rawValue }
}

enum AgentsGrouping {
    /// Which section a session belongs in. A rate-limited session is still
    /// live (it resumes when the window resets), so it stays with the working.
    static func kind(of session: AgentSessionItem, waiting: Bool) -> AgentListSection.Kind {
        if waiting || session.state.waitsOnYou { return .needsYou }
        switch session.state {
        case .working, .thinking, .ratelimit: return .working
        default: return .recent
        }
    }

    /// "Needs you", then "Working", then "Recent", each newest first; empty
    /// sections are left out.
    static func sections(_ sessions: [AgentSessionItem], requests: [AgentRequest]) -> [AgentListSection] {
        let waitingKeys = Set(requests.map(\.key))
        let byKind = Dictionary(grouping: sessions) { kind(of: $0, waiting: waitingKeys.contains($0.key)) }
        return AgentListSection.Kind.allCases.compactMap { k in
            guard let rows = byKind[k], !rows.isEmpty else { return nil }
            return AgentListSection(kind: k, sessions: rows.sorted { $0.lastEventAt > $1.lastEventAt })
        }
    }

    /// Requests whose session isn't in the list (it ended, or it belongs to a
    /// Coding-tab session) — shown on their own so none is unreachable.
    static func orphans(_ requests: [AgentRequest], sessions: [AgentSessionItem]) -> [AgentRequest] {
        let keys = Set(sessions.map(\.key))
        return requests.filter { !keys.contains($0.key) }
    }

    /// What waits on you: the "Needs you" rows plus the orphaned cards — the
    /// same number the list shows, never a different count.
    static func waitingCount(_ sessions: [AgentSessionItem], requests: [AgentRequest]) -> Int {
        let rows = sections(sessions, requests: requests).first { $0.kind == .needsYou }?.sessions.count ?? 0
        return rows + orphans(requests, sessions: sessions).count
    }

    static func workingCount(_ sessions: [AgentSessionItem], requests: [AgentRequest]) -> Int {
        sections(sessions, requests: requests).first { $0.kind == .working }?.sessions.count ?? 0
    }
}

// MARK: - Rows

/// The third line of a row, for a session that waits or works.
struct AgentRowDetail: Equatable {
    enum Tone: Equatable { case waiting, working, failed, quiet }
    let text: String
    let tone: Tone
}

enum AgentsPresentation {
    /// The task: the first line of the last prompt, else the project.
    static func title(_ s: AgentSessionItem) -> String {
        let prompt = firstLine(s.turnSummary?.prompt ?? "")
        return prompt.isEmpty ? s.project : prompt
    }

    /// "project · agent · terminal", without the project when it is the title.
    static func subtitle(_ s: AgentSessionItem) -> String {
        var parts = title(s) == s.project ? [] : [s.project]
        parts.append(s.agentName)
        if !s.hostApp.isEmpty { parts.append(s.hostApp) }
        return parts.joined(separator: " · ")
    }

    /// What it waits on, or what it's doing, or nil when there's nothing to say.
    static func detail(_ s: AgentSessionItem, request: AgentRequest?) -> AgentRowDetail? {
        if let request { return AgentRowDetail(text: ask(request), tone: .waiting) }
        switch s.state {
        case .approval: return AgentRowDetail(text: "Needs approval", tone: .waiting)
        case .question: return AgentRowDetail(text: "Has a question", tone: .waiting)
        case .working, .thinking:
            return AgentRowDetail(text: liveStep(s.step), tone: .working)
        case .error:
            let step = firstLine(s.step)
            return AgentRowDetail(text: step.isEmpty ? "Stopped with an error" : step, tone: .failed)
        case .ratelimit:
            return AgentRowDetail(text: "Paused until the plan limit resets", tone: .quiet)
        case .finished, .idle:
            return nil
        }
    }

    /// One line for what a request asks: "Wants to run rm -rf build", or the question.
    static func ask(_ request: AgentRequest) -> String {
        if request.kind == .question {
            let q = firstLine(request.questions.first?.question ?? "")
            return q.isEmpty ? "Has a question" : q
        }
        let what = request.command.isEmpty ? request.summary : request.command
        let line = AgentToolPhrase.line(tool: request.tool, summary: what, tense: .imperative)
        return "Wants to \(line.text)"
    }

    /// The hooks' step label as a sentence in progress — "Bash: npm test" →
    /// "Running npm test…" — for the tools whose labels name them; anything
    /// else ("Search foo", "Agent: …") is already readable and stays.
    static func liveStep(_ step: String) -> String {
        let line = firstLine(step)
        guard !line.isEmpty else { return "Thinking…" }
        let tool = String(line.prefix { $0 != ":" && $0 != " " })
        guard ["Bash", "Read", "Edit", "MultiEdit", "Write", "NotebookEdit"].contains(tool) else { return line }
        return AgentToolPhrase.line(tool: tool, summary: line, tense: .progressive).text + "…"
    }

    /// The working row's words: Claude Code's own status line when the
    /// transcript has one ("Zesting… · 50s"), else the hooks' step.
    static func working(statusLine: String?, step: String, state: AgentState) -> String {
        if let s = LiveStatus.parse(statusLine) {
            return [s.verb, s.elapsed].compactMap { $0 }.joined(separator: " · ")
        }
        return state == .thinking && step.isEmpty ? "Thinking…" : liveStep(step)
    }

    /// The approval card's question.
    static func approvalTitle(_ request: AgentRequest) -> String {
        if request.kind == .question { return "\(request.agentName) has a question" }
        if request.tool == "Bash" { return "Allow \(request.agentName) to run this command?" }
        let what = request.command.isEmpty ? request.summary : request.command
        let line = AgentToolPhrase.line(tool: request.tool, summary: what, tense: .imperative)
        return "Allow \(request.agentName) to \(line.text)?"
    }

    /// A changed file's folder, relative to the session's directory ("src/ui"),
    /// "~/…" outside it, "" at its root.
    static func folder(of path: String, cwd: String) -> String {
        var p = path
        let base = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        if !base.isEmpty, p.hasPrefix(base + "/") {
            p = String(p.dropFirst(base.count + 1))
        } else if p.hasPrefix("/Users/"), let slash = p.dropFirst(7).firstIndex(of: "/") {
            p = "~" + p[slash...]
        }
        return (p as NSString).deletingLastPathComponent
    }

    /// "~/code/app" for "/Users/p/code/app".
    static func shortPath(_ path: String) -> String {
        guard path.hasPrefix("/Users/"), let slash = path.dropFirst(7).firstIndex(of: "/") else { return path }
        return "~" + path[slash...]
    }

    /// "now", "5m", "3h", "2d", then "Oct 3".
    static func time(_ date: Date, now: Date = Date()) -> String {
        CodingUI.relativeTime(date.timeIntervalSince1970, now: now)
    }

    /// The top line of the conversation: where it runs and on what.
    static func meta(_ s: AgentSessionItem) -> String {
        [s.project, s.agentName, s.hostApp, s.model].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func firstLine(_ text: String, limit: Int = 140) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > limit ? String(trimmed.prefix(limit - 1)) + "…" : trimmed
    }
}

// MARK: - Sending

/// Why an instruction didn't reach the agent, in words a person can act on.
enum AgentSendFailure: Equatable {
    /// 403: the Code Master switch "Instructions from the phone" is off.
    case phoneInstructionsOff
    /// 409 without a reason: nothing to deliver it to.
    case noTerminal
    /// 503: the Mac that runs it is offline.
    case macOffline
    case other(String)

    static func from(_ error: Error) -> AgentSendFailure {
        if case APIError.http(let status, let message) = error {
            switch status {
            case 403: return .phoneInstructionsOff
            // A 409 says why (idle where Jarvis can't type, Jarvis still answering…).
            case 409: return message.isEmpty ? .noTerminal : .other(message)
            case 503: return .macOffline
            default: return .other(message.isEmpty ? "Couldn’t send it (\(status))" : message)
            }
        }
        if let server = error as? CodingServerError { return .other(server.message) }
        return .other(apiErrorLine(error))
    }

    var message: String {
        switch self {
        case .phoneInstructionsOff:
            return "“Instructions from the phone” is off. Turn it on in Code Master settings to send this."
        case .noTerminal:
            return "This session can’t take a message right now."
        case .macOffline:
            return "The Mac running this session is offline. Try again once it’s back."
        case .other(let text):
            return text
        }
    }

    /// The 403 comes with a way to the switch.
    var opensSettings: Bool { self == .phoneInstructionsOff }
}

/// An instruction sent from this phone, kept on screen from the tap until the
/// transcript shows it.
struct AgentOutgoing: Identifiable, Equatable {
    enum Phase: Equatable {
        case sending
        case sent(via: String)
        case failed(AgentSendFailure)
    }

    let id: UUID
    let text: String
    /// How many of the conversation's prompts already read like this one when
    /// it was sent — a repeat ("continue") is only delivered once there's one more.
    let baseline: Int
    var phase: Phase

    init(id: UUID = UUID(), text: String, baseline: Int, phase: Phase = .sending) {
        self.id = id
        self.text = text
        self.baseline = baseline
        self.phase = phase
    }

    var caption: String {
        switch phase {
        case .sending: return "Sending…"
        case .sent(let via):
            switch via {
            case "queued": return "Queued · it gets this when it finishes its current step"
            case "typed", "terminal": return "Sent · typed into the terminal"
            case "chat": return "Sent to Jarvis"
            default: return "Sent"
            }
        case .failed(let failure): return failure.message
        }
    }

    static func count(_ text: String, in prompts: [String]) -> Int {
        let want = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return prompts.filter { $0.trimmingCharacters(in: .whitespacesAndNewlines) == want }.count
    }

    /// Drops what the conversation now shows. Sending and failed ones stay.
    static func reconcile(_ list: [AgentOutgoing], prompts: [String]) -> [AgentOutgoing] {
        list.filter { o in
            guard case .sent = o.phase else { return true }
            return count(o.text, in: prompts) <= o.baseline
        }
    }
}

// MARK: - Transcript or last turn

/// What a session screen shows: the full Claude Code transcript when the
/// session has one, else the agent's own record of its last turn.
enum AgentTranscriptChoice: Equatable {
    case loading, transcript, lastTurn, empty

    static func choose(codingSessionId: String?, transcript: CodingTranscript,
                       turn: AgentTurn?, detailLoaded: Bool) -> AgentTranscriptChoice {
        if codingSessionId != nil {
            if !transcript.messages.isEmpty { return .transcript }
            // The first page is in flight: wait for it rather than flash the
            // last turn and then swap it out.
            if transcript.loading && !transcript.noTranscript { return .loading }
        }
        if let turn, !turn.isEmpty { return .lastTurn }
        return detailLoaded ? .empty : .loading
    }
}

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
    /// Its Mac is asleep or offline: the moon.
    case paused
    /// A Continue is moving it between machines.
    case moving
    /// The process is gone.
    case ended

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
        case .idle, .ended: return AgentPane.grey
        case .paused: return JcTheme.blue
        case .moving: return JcTheme.muted
        }
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
        AgentPane.relativeTime(date.timeIntervalSince1970, now: now)
    }

    /// The top line of the conversation: where it runs and on what.
    static func meta(_ c: AgentConv) -> String {
        [c.project, c.agentName, AgentsListLayout.whereLabel(c), c.model].filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    static func firstLine(_ text: String, limit: Int = 140) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > limit ? String(trimmed.prefix(limit - 1)) + "…" : trimmed
    }
}

// MARK: - Sending

/// Why a message didn't reach the agent, in words a person can act on
/// (`POST /agents/send`'s `delivery.reason`, or the request failing).
enum AgentSendFailure: Equatable {
    /// `owner_offline`: the Mac that runs it is asleep or offline.
    case macOffline
    /// `no_runtime`: nothing runs it on the server.
    case noRuntime
    /// `ended`: the session is over.
    case ended
    /// `moving`: a Continue is moving it right now.
    case moving
    /// `no_session`: the server doesn't know it any more.
    case gone
    case other(String)

    static func from(reason: String?) -> AgentSendFailure {
        switch reason ?? "" {
        case "owner_offline": return .macOffline
        case "no_runtime": return .noRuntime
        case "ended": return .ended
        case "moving": return .moving
        case "no_session": return .gone
        case "": return .other("It didn’t go through.")
        case let text: return .other(text)
        }
    }

    static func from(_ error: Error) -> AgentSendFailure {
        if case APIError.http(let status, let message) = error {
            return .other(message.isEmpty ? "Couldn’t send it (\(status))." : message)
        }
        if let server = error as? CodingServerError { return .other(server.message) }
        return .other(apiErrorLine(error))
    }

    var message: String {
        switch self {
        case .macOffline: return "The Mac running it is asleep or offline."
        case .noRuntime: return "Nothing is running it on the server."
        case .ended: return "This session has ended."
        case .moving: return "It’s moving between machines. Try again in a moment."
        case .gone: return "That session is gone."
        case .other(let text): return text
        }
    }

    /// An asleep Mac's session can be continued on the server instead.
    var offersContinue: Bool { self == .macOffline }
}

/// A message sent from this phone, kept on screen from the tap until the
/// transcript shows it.
struct AgentOutgoing: Identifiable, Equatable {
    enum Phase: Equatable {
        case sending
        /// Handed to whatever runs it; not yet seen arriving.
        case sent
        /// Waiting for the turn to end (the Stop hook hands it over).
        case queued
        /// Its `UserPromptSubmit` arrived.
        case delivered
        case failed(AgentSendFailure)

        init(_ delivery: AgentDelivery) {
            switch delivery.state {
            case .sent: self = .sent
            case .queued: self = .queued
            case .delivered: self = .delivered
            case .failed: self = .failed(.from(reason: delivery.reason))
            }
        }
    }

    let id: UUID
    let text: String
    /// How many of the conversation's prompts already read like this one when
    /// it was sent — a repeat ("continue") is only delivered once there's one more.
    let baseline: Int
    /// Sent with "Send now" (straight in, not queued behind the turn): a retry
    /// sends it the same way.
    var now = false
    var phase: Phase
    /// The server's record of this send (`POST /agents/send`'s `delivery.id`):
    /// the list push carries its later state — typed, queued, delivered, refused.
    var deliveryId: String? = nil

    init(id: UUID = UUID(), text: String, baseline: Int, phase: Phase = .sending) {
        self.id = id
        self.text = text
        self.baseline = baseline
        self.phase = phase
    }

    var caption: String { Self.caption(phase) }

    static func caption(_ phase: Phase) -> String {
        switch phase {
        case .sending: return "Sending…"
        case .sent: return "Sent"
        case .queued: return "Queued — will send when the turn ends"
        case .delivered: return "Delivered"
        case .failed(let failure): return "Failed: \(failure.message)"
        }
    }

    var failure: AgentSendFailure? {
        if case .failed(let f) = phase { return f }
        return nil
    }

    /// The server's later word on this send, from the list push. A send in
    /// flight (a retry) keeps its spinner; Delivered is never taken back.
    func following(_ deliveries: [AgentDelivery]) -> AgentOutgoing {
        guard let deliveryId, !deliveryId.isEmpty, phase != .sending, phase != .delivered,
              let d = deliveries.first(where: { $0.id == deliveryId }) else { return self }
        var next = self
        next.phase = Phase(d)
        return next
    }

    static func count(_ text: String, in prompts: [String]) -> Int {
        let want = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return prompts.filter { $0.trimmingCharacters(in: .whitespacesAndNewlines) == want }.count
    }

    /// Drops what the conversation now shows (it arrived). Sending and failed
    /// ones stay.
    static func reconcile(_ list: [AgentOutgoing], prompts: [String]) -> [AgentOutgoing] {
        list.filter { o in
            switch o.phase {
            case .sending, .failed: return true
            case .sent, .queued, .delivered: return count(o.text, in: prompts) <= o.baseline
            }
        }
    }
}

// MARK: - Transcript or last turn

/// What a session screen shows: the full transcript (`/agents/messages`) when
/// the server has one, else the agent's own record of its last turn.
enum AgentTranscriptChoice: Equatable {
    case loading, transcript, lastTurn, empty

    static func choose(transcriptId: String?, transcript: CodingTranscript,
                       turn: AgentTurn?, detailLoaded: Bool) -> AgentTranscriptChoice {
        if transcriptId != nil {
            if !transcript.messages.isEmpty { return .transcript }
            // The first page is in flight: wait for it rather than flash the
            // last turn and then swap it out.
            if transcript.loading && !transcript.noTranscript { return .loading }
        }
        if let turn, !turn.isEmpty { return .lastTurn }
        return detailLoaded ? .empty : .loading
    }
}

// MARK: - Pane palette

/// The code-block ground and its text, diff colours and the resting grey —
/// the terminal look tool output, diffs and approval commands share.
enum AgentPane {
    static let pane = Color(jcHex: 0x0A0D13)
    static let paneText = Color(jcHex: 0xD7DAE0)
    static let paneMuted = Color(jcHex: 0xB9BFC9)
    static let diffAdd = Color(jcHex: 0x34D399)
    static let diffDel = Color(jcHex: 0xF87171)
    /// Idle — alive but nothing happening.
    static let grey = Color(jcHex: 0x838B97)

    /// "now" / "5m" / "3h" / "2d" / "Mar 4", or "" when the server never said.
    static func relativeTime(_ ts: Double, now: Date) -> String {
        guard ts > 0 else { return "" }
        let delta = now.timeIntervalSince1970 - ts
        // A clock skew (the server ahead of the phone) reads as "now".
        if delta < 45 { return "now" }
        if delta < 3600 { return "\(Int(delta / 60))m" }
        if delta < 86_400 { return "\(Int(delta / 3600))h" }
        if delta < 7 * 86_400 { return "\(Int(delta / 86_400))d" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d"
        return f.string(from: Date(timeIntervalSince1970: ts))
    }
}

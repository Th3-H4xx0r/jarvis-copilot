import AppIntents
import Foundation

/// "What are my agents doing?" — answered by Siri without opening the app.
struct AgentsStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Coding agents status"
    static let description = IntentDescription("Tells you what your coding agents are doing.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let overview = try await AgentsAPI().overview()
        return .result(dialog: IntentDialog(stringLiteral: AgentsStatusIntent.summary(overview)))
    }

    /// One spoken sentence or two: what waits on you first, then what's working.
    static func summary(_ overview: AgentsAPI.Overview) -> String {
        let live = overview.sessions.filter { $0.state != .idle }
        guard !live.isEmpty else { return "No coding agents are running." }
        var parts: [String] = []
        let waiting = live.filter { $0.state.waitsOnYou }
        if let first = waiting.first {
            let what = first.state == .question ? "has a question" : "needs your approval"
            parts.append("\(first.agentName) in \(first.project) \(what).")
            if waiting.count > 1 { parts.append("\(waiting.count - 1) more waiting on you.") }
        }
        let working = live.filter { $0.state == .working || $0.state == .thinking }
        if let first = working.first {
            let step = first.step.isEmpty ? "" : ": \(first.step)"
            parts.append("\(first.agentName) is working in \(first.project)\(step).")
            if working.count > 1 { parts.append("\(working.count - 1) other\(working.count == 2 ? "" : "s") working.") }
        }
        if parts.isEmpty, let first = live.first {
            parts.append("\(first.agentName) in \(first.project): \(first.state.label.lowercased()).")
        }
        return parts.joined(separator: " ")
    }
}

/// "Tell Claude …" — the next instruction for the agent that needs you, or the
/// one you used last. Runs on your computer, so it asks to unlock first.
struct SendAgentInstructionIntent: AppIntent {
    static let title: LocalizedStringResource = "Send an instruction to a coding agent"
    static let description = IntentDescription("Sends the next instruction to your most recent coding agent.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Instruction", requestValueDialog: "What should it do next?")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Tell my coding agent \(\.$text)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let overview = try await AgentsAPI().overview()
        guard let target = overview.sessions.first(where: { $0.state != .idle }) ?? overview.sessions.first else {
            return .result(dialog: "No coding agent is running.")
        }
        if let refusal = Self.refusal(for: target) {
            return .result(dialog: IntentDialog(stringLiteral: refusal))
        }
        let delivery = try await AgentsAPI().send(ckey: AgentsListLayout.ckey(fromKey: target.key), text: text)
        return .result(dialog: IntentDialog(stringLiteral: Self.reply(delivery, to: target)))
    }

    /// Why Siri won't send it: a session waiting on an approval or a question
    /// would get the words typed into that menu, and the Return picks "Yes".
    static func refusal(for target: AgentSessionItem) -> String? {
        let to = "\(target.agentName) in \(target.project)"
        switch target.state {
        case .approval: return "\(to) is waiting on an approval. Answer it in the Agents tab first."
        case .question: return "\(to) is waiting on your answer. Answer it in the Agents tab first."
        default: return nil
        }
    }

    /// What Siri says back: where it went, or honestly why it didn't.
    static func reply(_ delivery: AgentDelivery, to target: AgentSessionItem) -> String {
        let to = "\(target.agentName) in \(target.project)"
        switch delivery.state {
        case .delivered: return "Delivered to \(to)."
        case .sent: return "Sent to \(to)."
        case .queued: return "Queued for \(to). It gets it when the turn ends."
        case .failed: return "Couldn’t send it: \(AgentSendFailure.from(reason: delivery.reason).message)"
        }
    }
}

/// A Focus filter: while a Focus is on, only what waits on you (approvals,
/// questions) reaches the phone; finished / failed stay quiet. The server does
/// the filtering — iOS can't hold back a remote push on the phone.
struct AgentsFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Coding agents"
    static let description: IntentDescription? = IntentDescription("Only approvals and questions notify while this Focus is on.")

    @Parameter(title: "Only approvals and questions", default: false)
    var onlyWaiting: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: onlyWaiting ? "Only what waits on you" : "Every agent update")
    }

    func perform() async throws -> some IntentResult {
        _ = try? await JarvisAPI.shared.post("/api/coding/agents/focus", json: ["only_waiting": onlyWaiting])
        return .result()
    }
}

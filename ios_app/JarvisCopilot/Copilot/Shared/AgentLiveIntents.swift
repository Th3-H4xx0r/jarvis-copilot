import ActivityKit
import AppIntents
import Foundation

/// Allow / Deny / an answer on the Lock Screen and the Dynamic Island, for the
/// agent request the Live Activity shows. Live Activity intents, so iOS runs
/// them in the app's process (launching it in the background if needed), where
/// the decision can reach the server. None of them asks for Face ID or the
/// passcode: answering an agent from the Lock Screen in one tap is the point
/// (Pranav: "no face ID required").
///
/// Compiled into BOTH the app and the `JarvisWidget` extension: the widget only
/// builds the buttons, the app installs `AgentDecisionBridge.decide` at launch.
@MainActor
enum AgentDecisionBridge {
    /// (fingerprint, decision) → posts it; true when the server took it. Nil in
    /// the widget extension.
    static var decide: ((String, String) async -> Bool)?
    /// (fingerprint, question, option) → answers that question; true when taken.
    static var answer: ((String, String, String) async -> Bool)?
}

/// What a Live Activity shows the moment you answer it from the Lock Screen,
/// banner or island — before the server hears about it. The intent updates the
/// activity itself ("Allowed ✓ · <command>", buttons gone), then sends the
/// decision, and puts the request back if that fails. A poll or push that still
/// says "waiting" for a moment is overlaid with the decision (`overlay`) until the
/// server catches up.
@MainActor
enum AgentLiveDecision {
    struct Recent { let decision: String; let option: String; let at: Date }
    /// How long a decision made here outranks a server state still saying "waiting".
    static let holdFor: TimeInterval = 60
    private(set) static var recent: [String: Recent] = [:]

    static func record(_ fingerprint: String, decision: String, option: String = "", at: Date = Date()) {
        recent = recent.filter { at.timeIntervalSince($0.value.at) < holdFor }
        recent[fingerprint] = Recent(decision: decision, option: option, at: at)
    }

    static func forget(_ fingerprint: String) { recent[fingerprint] = nil }

    /// A server state for a request answered here in the last minute → the answered state.
    static func overlay(_ st: AgentActivityAttributes.ContentState, now: Date = Date())
    -> AgentActivityAttributes.ContentState {
        guard !st.fingerprint.isEmpty, let made = recent[st.fingerprint],
              now.timeIntervalSince(made.at) < holdFor else { return st }
        return decided(st, decision: made.decision, option: made.option)
    }

    /// The step line once answered: what you chose, then the command.
    static func outcome(_ step: String, decision: String, option: String) -> String {
        var command = step
        if command.lowercased().hasPrefix("needs approval:") {
            command = String(command.dropFirst("needs approval:".count)).trimmingCharacters(in: .whitespaces)
        }
        switch decision {
        case "allow", "always": return command.isEmpty ? "Allowed ✓" : "Allowed ✓ · \(command)"
        case "deny": return command.isEmpty ? "Denied" : "Denied · \(command)"
        default: return option.isEmpty ? "Answered" : "Answered: \(option)"
        }
    }

    /// An agent activity once its request is answered: it carries on working,
    /// no longer amber, no buttons.
    static func decided(_ st: AgentActivityAttributes.ContentState, decision: String, option: String = "")
    -> AgentActivityAttributes.ContentState {
        var out = st
        out.step = outcome(st.step, decision: decision, option: option)
        out.state = "working"
        out.kind = ""
        out.fingerprint = ""
        out.question = ""
        out.options = []
        out.waitingSince = 0
        if st.waitsOnYou {
            out.waiting = max(0, st.waiting - 1)
            out.working = st.working + 1
            var bar = st.barStates
            if let i = bar.firstIndex(of: "p") { bar[i] = "w" }
            out.bar = bar.joined(separator: ",")
        }
        return out
    }

    /// The Jarvis activity's coding lead, the same way.
    static func decided(_ st: JarvisActivityAttributes.ContentState, decision: String, option: String = "")
    -> JarvisActivityAttributes.ContentState {
        var out = st
        out.leadStep = outcome(st.leadStep, decision: decision, option: option)
        if st.leadState == "approval" || st.leadState == "question" {
            out.waitingCount = max(0, st.waitingCount - 1)
        }
        out.leadState = "working"
        out.leadKind = ""
        out.leadFingerprint = ""
        return out
    }

    /// Show the decision on every activity holding this request, then `send` it;
    /// if sending fails, put the request back. Returns whether it went through.
    @discardableResult
    static func apply(fingerprint: String, decision: String, option: String = "",
                      send: () async -> Bool) async -> Bool {
        record(fingerprint, decision: decision, option: option)
        var undo: [() async -> Void] = []
        for activity in Activity<AgentActivityAttributes>.activities
        where activity.content.state.fingerprint == fingerprint {
            let before = activity.content
            let after = ActivityContent(state: decided(before.state, decision: decision, option: option),
                                        staleDate: nil, relevanceScore: before.relevanceScore)
            await activity.update(after)
            undo.append { await activity.update(before) }
        }
        for activity in Activity<JarvisActivityAttributes>.activities
        where activity.content.state.leadFingerprint == fingerprint {
            let before = activity.content
            let after = ActivityContent(state: decided(before.state, decision: decision, option: option),
                                        staleDate: nil, relevanceScore: before.relevanceScore)
            await activity.update(after)
            undo.append { await activity.update(before) }
        }
        if await send() { return true }
        forget(fingerprint)
        for restore in undo { await restore() }
        return false
    }
}

struct AgentAllowIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Allow the agent's request"
    static let description = IntentDescription("Allows the command a coding agent is waiting on.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let isDiscoverable = false

    @Parameter(title: "Request")
    var fingerprint: String

    init() { fingerprint = "" }
    init(fingerprint: String) { self.fingerprint = fingerprint }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard !fingerprint.isEmpty else { return .result() }
        let fingerprint = self.fingerprint
        await AgentLiveDecision.apply(fingerprint: fingerprint, decision: "allow") {
            await AgentDecisionBridge.decide?(fingerprint, "allow") ?? false
        }
        return .result()
    }
}

struct AgentDenyIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Deny the agent's request"
    static let description = IntentDescription("Denies the command a coding agent is waiting on.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let isDiscoverable = false

    @Parameter(title: "Request")
    var fingerprint: String

    init() { fingerprint = "" }
    init(fingerprint: String) { self.fingerprint = fingerprint }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard !fingerprint.isEmpty else { return .result() }
        let fingerprint = self.fingerprint
        await AgentLiveDecision.apply(fingerprint: fingerprint, decision: "deny") {
            await AgentDecisionBridge.decide?(fingerprint, "deny") ?? false
        }
        return .result()
    }
}

struct AgentAnswerIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Answer the agent's question"
    static let description = IntentDescription("Picks one of the options a coding agent asked about.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let isDiscoverable = false

    @Parameter(title: "Request")
    var fingerprint: String
    @Parameter(title: "Question")
    var question: String
    @Parameter(title: "Option")
    var option: String

    init() { fingerprint = ""; question = ""; option = "" }
    init(fingerprint: String, question: String, option: String) {
        self.fingerprint = fingerprint
        self.question = question
        self.option = option
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard !fingerprint.isEmpty, !option.isEmpty else { return .result() }
        let (fingerprint, question, option) = (self.fingerprint, self.question, self.option)
        await AgentLiveDecision.apply(fingerprint: fingerprint, decision: "answer", option: option) {
            await AgentDecisionBridge.answer?(fingerprint, question, option) ?? false
        }
        return .result()
    }
}

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
    /// (fingerprint, decision) → posts it. Nil in the widget extension.
    static var decide: ((String, String) async -> Void)?
    /// (fingerprint, question, option) → answers that question. Nil in the widget.
    static var answer: ((String, String, String) async -> Void)?
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
        if !fingerprint.isEmpty { await AgentDecisionBridge.decide?(fingerprint, "allow") }
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
        if !fingerprint.isEmpty { await AgentDecisionBridge.decide?(fingerprint, "deny") }
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
        if !fingerprint.isEmpty && !option.isEmpty {
            await AgentDecisionBridge.answer?(fingerprint, question, option)
        }
        return .result()
    }
}

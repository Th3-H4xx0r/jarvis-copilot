import AppIntents
import Foundation

/// Allow / Deny on the Lock Screen and the Dynamic Island, for the agent
/// request the Live Activity shows. Live Activity intents, so iOS runs them in
/// the app's process (launching it in the background if needed), where the
/// decision can reach the server. Allow needs the unlocked phone; Deny doesn't.
///
/// Compiled into BOTH the app and the `JarvisWidget` extension: the widget only
/// builds the buttons, the app installs `AgentDecisionBridge.decide` at launch.
@MainActor
enum AgentDecisionBridge {
    /// (fingerprint, decision) → posts it. Nil in the widget extension.
    static var decide: ((String, String) async -> Void)?
}

struct AgentAllowIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Allow the agent's request"
    static let description = IntentDescription("Allows the command a coding agent is waiting on.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
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

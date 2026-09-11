import Combine
import Foundation

enum WatchState: Equatable {
    case idle, thinking
    case answer(String)
    case error(String)
}

/// Drives the single watch screen: sends a dictated turn through the connector
/// and speaks the reply with the built-in voice unless a JARVIS clip is coming.
@MainActor
final class WatchViewModel: ObservableObject {
    @Published var state: WatchState = .idle

    private let connector: WatchConnector

    init(connector: WatchConnector) {
        self.connector = connector
    }

    func submit(text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { state = .idle; return }
        guard state != .thinking else { return }   // ignore re-entrant / double-tap submits
        state = .thinking
        switch await connector.ask(text: trimmed) {
        case .success(let reply):
            state = .answer(reply.replyText)
            // A JARVIS clip plays on arrival (`WatchConnector`); don't talk over it.
            if !reply.expectsClip { Speaker.shared.speak(reply.replyText) }
        case .failure(.notConfigured):
            state = .error("Sign in on your iPhone first.")
        case .failure(.unreachable):
            state = .error("Open JarvisCopilot on your iPhone to use voice.")
        case .failure(.network(let detail)):
            // Show what actually went wrong; one generic message for every cause
            // gave nothing to act on.
            let reason = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            state = .error(reason.isEmpty ? "Couldn't reach JarvisCopilot. Try again." : reason)
        }
    }

    func reset() { state = .idle }
}

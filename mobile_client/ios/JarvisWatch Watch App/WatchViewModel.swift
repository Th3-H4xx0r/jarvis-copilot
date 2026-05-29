import Foundation

enum WatchState: Equatable {
    case idle, listening, thinking
    case answer(String)
    case error(String)
}

/// Drives the single watch screen. Dependency-injected `asker` so the state
/// machine is unit-testable without WCSession. Audio playback is handled by
/// `WatchConnector` when the clip arrives, not here.
@MainActor
final class WatchViewModel: ObservableObject {
    @Published var state: WatchState = .idle

    private let asker: (String) async -> Result<AskResult, AskError>

    init(asker: @escaping (String) async -> Result<AskResult, AskError>) {
        self.asker = asker
    }

    func submit(text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { state = .idle; return }
        guard state != .thinking else { return }   // ignore re-entrant / double-tap submits
        state = .thinking
        switch await asker(trimmed) {
        case .success(let r):
            state = .answer(r.replyText)
        case .failure(.notConfigured):
            state = .error("Sign in on your iPhone first.")
        case .failure(.unreachable):
            state = .error("Open JarvisCopilot on your iPhone to use voice.")
        case .failure(.network):
            state = .error("Couldn't reach JarvisCopilot. Try again.")
        }
    }

    func reset() { state = .idle }
}

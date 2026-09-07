import Combine
import Foundation

enum WatchState: Equatable {
    case idle, listening, thinking
    case answer(String)
    case error(String)
}

/// Drives the single watch screen. Dependency-injected `asker` + `speak` so the
/// state machine is unit-testable without WCSession or audio. `speak` plays the
/// JARVIS clip if present, else speaks the text with the built-in voice.
@MainActor
final class WatchViewModel: ObservableObject {
    @Published var state: WatchState = .idle
    @Published var serverVoiceNote: String = ""   // phone-side voice debug from the last reply

    private let asker: (String) async -> Result<AskResult, AskError>
    private let speak: (AskResult) -> Void

    init(asker: @escaping (String) async -> Result<AskResult, AskError>,
         speak: @escaping (AskResult) -> Void) {
        self.asker = asker
        self.speak = speak
    }

    func submit(text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { state = .idle; return }
        guard state != .thinking else { return }   // ignore re-entrant / double-tap submits
        state = .thinking
        switch await asker(trimmed) {
        case .success(let r):
            serverVoiceNote = r.voiceDbg
            state = .answer(r.replyText)
            speak(r)
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

import Foundation
import Observation

/// Which chat session voice talks into, chosen per device and remembered across
/// launches. The default is the server's dedicated "Voice" session; the user can
/// point voice at any existing chat or start a fresh one, and the Chat tab
/// follows whichever session voice writes to (see ``ChatSyncBus``).
@MainActor
@Observable
final class VoiceSessionSelection {
    static let shared = VoiceSessionSelection()

    enum Target: Equatable, Codable {
        /// The server's get-or-create "Voice" session.
        case defaultVoice
        /// A specific chat session (an existing one, or one created from the picker).
        case session(id: String, title: String)

        var sessionID: String? {
            if case .session(let id, _) = self { return id }
            return nil
        }
    }

    static let storageKey = "voice.session.target"

    private(set) var target: Target = .defaultVoice
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode(Target.self, from: data) {
            target = saved
        }
    }

    /// Toolbar chip text.
    var chipLabel: String {
        switch target {
        case .defaultVoice: return "Voice"
        case .session(_, let title):
            let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? "New session" : t
        }
    }

    func select(_ target: Target) {
        self.target = target
        if let data = try? JSONEncoder().encode(target) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    /// Point voice at a chat session from the picker.
    func select(session: ChatSessionSummary) {
        select(.session(id: session.id, title: session.displayTitle))
    }

    /// Create a fresh chat on the server and voice into it from now on; it takes
    /// its title from the first exchange, like a text chat.
    @discardableResult
    func startNewSession(api: SessionsAPI = SessionsAPI()) async throws -> String {
        let id = try await api.create()
        select(.session(id: id, title: ""))
        return id
    }

    /// Keep the chip's title current (a new session gets titled after its first
    /// exchange), and drop a target whose session no longer exists.
    func reconcile(with sessions: [ChatSessionSummary]) {
        guard case .session(let id, let title) = target else { return }
        guard let live = sessions.first(where: { $0.id == id }) else {
            select(.defaultVoice)
            return
        }
        if live.displayTitle != title { select(.session(id: id, title: live.displayTitle)) }
    }
}

import Foundation

/// App-wide signal that a chat session changed (a turn was added) somewhere OTHER
/// than the chat screen — e.g. a voice conversation persisted a turn.
/// Ported from `services/chat_sync_bus.dart`.
///
/// The chat screen owns its own ``ChatStore`` and has no other way to learn that
/// the voice controller just wrote to a session. It subscribes here and refreshes
/// the sessions list (and the open thread, when it's the one that changed) so the
/// new turn shows up live instead of only after a manual reload.
final class ChatSyncBus: @unchecked Sendable {
    static let shared = ChatSyncBus()

    private let lock = NSLock()
    private var subscribers: [UUID: AsyncStream<String?>.Continuation] = [:]

    init() {}

    /// A fresh subscription. Every subscriber sees every signal; drop the stream
    /// (or cancel the consuming task) to unsubscribe.
    ///
    /// Signals carry the affected session id, or nil when it is unknown — a
    /// list-only refresh. Listeners must tolerate bursts and unknown ids.
    func changes() -> AsyncStream<String?> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock(); subscribers[id] = continuation; lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                lock.lock(); subscribers[id] = nil; lock.unlock()
            }
        }
    }

    /// Announce that `sessionID` gained a turn (or that some session changed, when nil).
    func sessionChanged(_ sessionID: String? = nil) {
        lock.lock(); let current = subscribers.values; lock.unlock()
        for continuation in current { continuation.yield(sessionID) }
    }

    var subscriberCount: Int { lock.lock(); defer { lock.unlock() }; return subscribers.count }
}

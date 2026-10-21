import Foundation
import UserNotifications

/// The "N new facts from Sam Lee" push (`imessage_memory_writer.push_facts`): one
/// per conversation, category `IMESSAGE_FACTS`, with **Store all** / **Skip all**
/// that finish in the background — saving a memory isn't destructive, so neither
/// asks to unlock. Tapping the body opens the Chat tab, where the cards wait.
///
/// The server's data dict rides in the `jarviscopilot` envelope of `userInfo`:
/// `{"type": "imessage_facts", "burst": "<guid>|<first_rowid>"}`.
enum IMessageFactsPush {
    static let category = "IMESSAGE_FACTS"
    static let storeAll = "IMESSAGE_FACTS_STORE"
    static let skipAll = "IMESSAGE_FACTS_SKIP"
    /// The envelope's `type`.
    static let pushKind = "imessage_facts"
    /// Posted (on the main actor) when a facts push lands while the app is open,
    /// or a lock-screen answer went through — the Chat home re-reads its cards.
    static let changed = Notification.Name("jc.imessageFacts.changed")

    static func categories() -> Set<UNNotificationCategory> {
        // No `.foreground`, no `.authenticationRequired`: answered from the lock screen.
        let store = UNNotificationAction(identifier: storeAll, title: "Store all", options: [])
        let skip = UNNotificationAction(identifier: skipAll, title: "Skip all", options: [.destructive])
        return [UNNotificationCategory(identifier: category, actions: [store, skip],
                                       intentIdentifiers: [], options: [])]
    }

    /// true = Store all, false = Skip all, nil = not one of this push's buttons.
    static func store(forAction identifier: String) -> Bool? {
        switch identifier {
        case storeAll: return true
        case skipAll: return false
        default: return nil
        }
    }

    private static func envelope(_ userInfo: [AnyHashable: Any]) -> [String: Any] {
        userInfo[NotificationAction.envelopeKey] as? [String: Any] ?? [:]
    }

    /// Whether this notification is a facts push.
    static func isFactsPush(_ userInfo: [AnyHashable: Any]) -> Bool {
        let env = envelope(userInfo)
        return (env["type"] as? String ?? env["kind"] as? String) == pushKind
    }

    /// The conversation the push is about (`"<guid>|<first_rowid>"`), or nil.
    static func burst(from userInfo: [AnyHashable: Any]) -> String? {
        let value = (envelope(userInfo)["burst"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    /// Store or skip every card of one conversation. True when the server took it
    /// (cards already answered in the app count as done, not as a failure).
    static func decide(burst: String, store: Bool, api: IMessageMemoryAPI) async -> Bool {
        guard !burst.isEmpty else { return false }
        do {
            try await api.decide(burst: burst, store: store)
            return true
        } catch {
            _ = JcLog.report(JcLog.services, "imessage facts decide", error)
            return false
        }
    }

    /// Longest a lock-screen answer may take. iOS gives a background action
    /// about 30 s, and the shared session would otherwise wait for a network
    /// for up to an hour — the app would be suspended mid-request, no failure
    /// banner would show, and the cards would auto-store a day later.
    static let backgroundLimit: Duration = .seconds(20)

    /// The same, holding a background task so iOS doesn't suspend the app halfway
    /// (the action doesn't bring it to the foreground), giving up after
    /// `backgroundLimit`, and running `onFailure` (the "couldn't" banner) while
    /// the task is still held. Tells the Chat home to re-read its cards when it
    /// went through.
    @MainActor
    static func decideInBackground(burst: String, store: Bool,
                                   api: IMessageMemoryAPI = IMessageMemoryAPI(),
                                   onFailure: @MainActor () async -> Void = {}) async -> Bool {
        let task = BackgroundTask.begin("imessage.facts.decide")
        defer { task.end() }
        let attempt = Task { await decide(burst: burst, store: store, api: api) }
        let limit = Task {
            try? await Task.sleep(for: backgroundLimit)
            attempt.cancel()
        }
        let ok = await attempt.value
        limit.cancel()
        if ok {
            NotificationCenter.default.post(name: changed, object: nil)
        } else {
            await onFailure()
        }
        return ok
    }
}

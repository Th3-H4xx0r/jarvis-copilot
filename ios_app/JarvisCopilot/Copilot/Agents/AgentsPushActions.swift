import UIKit
import UserNotifications

/// The "your Mac went to sleep" push (`agents_core._push_paused`): category
/// `MAC_SLEPT` carries one action, **Continue all on server**, that works from
/// the lock screen without opening the app; `MAC_OFFLINE` has none (an offline
/// Mac may still be running its sessions, so moving them asks first, in the
/// app). Tapping either opens the Agents tab, where the card waits.
enum AgentsPushActions {
    static let macSlept = "MAC_SLEPT"
    static let macOffline = "MAC_OFFLINE"
    static let continueAll = "CONTINUE_ALL"
    /// The push envelope's `kind`.
    static let pushKind = "mac_paused"

    static func categories() -> Set<UNNotificationCategory> {
        // Moving sessions runs things on the server: unlock first. No
        // `.foreground` — it finishes in the background.
        let action = UNNotificationAction(identifier: continueAll, title: "Continue all on server",
                                          options: [.authenticationRequired])
        return [UNNotificationCategory(identifier: macSlept, actions: [action],
                                       intentIdentifiers: [], options: []),
                UNNotificationCategory(identifier: macOffline, actions: [],
                                       intentIdentifiers: [], options: [])]
    }

    /// Fetch the list and continue every session on its Mac-asleep card on the
    /// server. True when every one moved (or there was nothing left to move).
    /// `deviceId` is the Mac the push was about: the card shows whichever Mac
    /// went most recently, and another Mac's sessions are never moved from
    /// this push (that's a false, so the app says to open the Agents tab).
    static func continueAllOnServer(api: AgentsAPI, deviceId: String = "") async -> Bool {
        do {
            guard let card = try await api.list().card, !card.sessions.isEmpty else { return true }
            if !deviceId.isEmpty && card.deviceId != deviceId { return false }
            let results = try await api.continueSessions(card.sessions.map(\.ckey), to: "server")
            return card.sessions.allSatisfy { results[$0.ckey]?.ok == true }
        } catch {
            _ = JcLog.report(JcLog.coding, "continue all on server", error)
            return false
        }
    }

    /// The same, holding a background task so iOS doesn't suspend the app
    /// halfway through (the action doesn't bring it to the foreground).
    @MainActor
    static func continueAllInBackground(api: AgentsAPI = AgentsAPI(), deviceId: String = "") async -> Bool {
        let task = BackgroundTask.begin("agents.continue-all")
        defer { task.end() }
        return await continueAllOnServer(api: api, deviceId: deviceId)
    }
}

/// One `UIApplication` background task, ended exactly once.
@MainActor
private final class BackgroundTask {
    private var id: UIBackgroundTaskIdentifier = .invalid

    static func begin(_ name: String) -> BackgroundTask {
        let task = BackgroundTask()
        task.id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak task] in
            MainActor.assumeIsolated { task?.end() }
        }
        return task
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

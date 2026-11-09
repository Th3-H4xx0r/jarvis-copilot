import Foundation
import UIKit
import UserNotifications

/// A Security Advisor alert push: category `SECURITY_ALERT`, with **Block**, **Allow** and **Open**.
/// The server's data rides in the `jarviscopilot` envelope: `{"type": "security_alert", "alert_id": <id>}`.
///
/// Block and Allow must be signed with Face ID (`jarvis-security`), and Face ID only prompts in
/// the foreground — so both buttons bring the app forward (after the unlock iOS asks for) onto
/// More → Security, then sign and answer. Open just shows the page.
enum SecurityPush {
    static let category = "SECURITY_ALERT"
    static let block = "SECURITY_BLOCK"
    static let allow = "SECURITY_ALLOW"
    static let open = "SECURITY_OPEN"
    /// The envelope's `type`.
    static let pushKind = "security_alert"

    static func categories() -> Set<UNNotificationCategory> {
        let block = UNNotificationAction(identifier: block, title: "Block",
                                         options: [.destructive, .authenticationRequired, .foreground])
        let allow = UNNotificationAction(identifier: allow, title: "Allow",
                                         options: [.authenticationRequired, .foreground])
        let open = UNNotificationAction(identifier: open, title: "Open", options: [.foreground])
        return [UNNotificationCategory(identifier: category, actions: [block, allow, open],
                                       intentIdentifiers: [], options: [])]
    }

    private static func envelope(_ userInfo: [AnyHashable: Any]) -> [String: Any] {
        userInfo[NotificationAction.envelopeKey] as? [String: Any] ?? [:]
    }

    static func isSecurityPush(_ userInfo: [AnyHashable: Any]) -> Bool {
        let env = envelope(userInfo)
        return (env["type"] as? String ?? env["kind"] as? String) == pushKind
    }

    /// The alert the push is about (a number or a string on the wire), or nil.
    static func alertID(from userInfo: [AnyHashable: Any]) -> String? {
        securityText(envelope(userInfo)["alert_id"])
    }

    /// Block or Allow from the banner: show the page, wait for the app to be in front (Face ID
    /// can't prompt before), then sign and answer. A failure stays visible on the page.
    @MainActor
    static func answer(_ action: SecurityStore.Action, alertID: String, router: AppRouter,
                       store: SecurityStore = .shared) async -> Bool {
        router.openMore(.security)
        await untilActive()
        let ok = await store.resolve(alertID, action)
        await store.load()
        return ok
    }

    /// Returns once the app is active, or after `limit`.
    @MainActor
    private static func untilActive(limit: Duration = .seconds(10)) async {
        if UIApplication.shared.applicationState == .active { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) {
                    return
                }
            }
            group.addTask { try? await Task.sleep(for: limit) }
            await group.next()
            group.cancelAll()
        }
    }
}

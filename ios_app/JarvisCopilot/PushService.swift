import Foundation
import UIKit
import UserNotifications

/// APNs plumbing for the Jarvis bridge.
///
/// The server sends a **silent** push (`content-available: 1`, `apns-push-type:
/// background`, see `webui/api/push/apns.py`) when it has queued a command for this
/// device. That wakes the app long enough to drain `/api/devices/mobile/poll` — the only
/// way to serve Jarvis promptly while suspended, since a WebSocket can't survive
/// backgrounding.
final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil)
    -> Bool {
        // Before anything else: an exception that ends the app leaves its reason behind.
        CrashNote.watch()
        Task { @MainActor in
            PushService.shared.registerIfPaired()
            // Listens for ring syncs from here on, and catches up now.
            AppleHealthSync.shared.syncSoon(after: 5)
        }
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in await PushService.shared.submit(token: hex) }
    }

    /// A tapped home-screen quick action. In a scene-based app iOS normally
    /// routes these to the window scene delegate, which SwiftUI owns — this is
    /// the pre-scene fallback, and harmless when it is never called (App
    /// Shortcuts already put the same three actions in the long-press menu).
    func application(_ application: UIApplication,
                     performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        Task { @MainActor in
            completionHandler(AppServices.shared.performQuickAction(type: shortcutItem.type))
        }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        JcLog.dropped(JcLog.services, "remote notification registration", error)
    }

    /// Silent push: the server has work queued. Drain it and report back honestly —
    /// iOS throttles apps that claim `.newData` without doing anything.
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification info: [AnyHashable: Any],
                     fetchCompletionHandler completion: @escaping (UIBackgroundFetchResult) -> Void) {
        Task { @MainActor in
            // Route device-channel notifications (glasses, ring, etc.) to the
            // wearable that owns the channel. Falls back to the generic APS alert
            // path for non-device pushes.
            let card = WearableNotification.decode(info)
            if let card {
                PushService.shared.forward(card)
            } else if let aps = info["aps"] as? [String: Any] {
                if let alert = aps["alert"] as? [String: Any] {
                    InmoSession.shared.forwardNotification(title: alert["title"] as? String ?? "",
                                                           body: alert["body"] as? String ?? "")
                } else if let alert = aps["alert"] as? String {
                    InmoSession.shared.forwardNotification(title: "", body: alert)
                }
            }
            let before = BridgeClient.shared.lastActivity
            await BridgeClient.shared.drainQueue(foreground: false)
            completion(card != nil || BridgeClient.shared.lastActivity != before ? .newData : .noData)
        }
    }
}

@MainActor
final class PushService {
    static let shared = PushService()

    private init() {}

    func forward(_ card: WearableNotification) {
        if card.channel == "glasses" {
            InmoSession.shared.forwardNotification(title: card.title, body: card.body, app: card.app)
        } else {
            DeviceRegistry.shared.forwardNotification(channel: card.channel, title: card.title, body: card.body)
        }
    }

    /// An alert-only APNs push can display without waking the app. The ESP32's
    /// ANCS event DOES wake our BLE session: recover the original routing metadata
    /// from Notification Center instead of dropping Jarvis's own iMessage banners.
    /// Never infer the channel from banner text or relay unrelated Jarvis alerts.
    func recoverRelayedNotification(title: String, body: String) async {
        for attempt in 0..<3 {
            if attempt > 0 {
                do { try await Task.sleep(nanoseconds: 300_000_000) }
                catch { return }
            }
            let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
            if let notification = delivered.sorted(by: { $0.date > $1.date }).first(where: {
                Date().timeIntervalSince($0.date) < 60 &&
                WearableNotification.decode($0.request.content.userInfo) != nil &&
                WearableNotification.matchesRelay(title: $0.request.content.title,
                    body: $0.request.content.body, relayTitle: title, relayBody: body)
            }), let card = WearableNotification.decode(notification.request.content.userInfo) {
                forward(card)
                InmoRuntimeDiagnostics.note("device notification recovered through ANCS")
                return
            }
        }
        InmoRuntimeDiagnostics.note("ANCS Jarvis banner had no matching recent device notification")
    }

    /// Asks iOS for a device token. Silent pushes don't need user permission, so this
    /// shows no prompt — the app only registers for background delivery.
    func registerIfPaired() {
        guard BridgeClient.shared.isPaired else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// Hands the token to JarvisCopilot so `_invoke_via_mobile_push` can reach us.
    func submit(token hex: String) async {
        await PushHandler.shared.registerToken(hex)
    }
}

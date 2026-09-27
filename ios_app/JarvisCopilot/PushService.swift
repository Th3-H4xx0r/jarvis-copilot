import Foundation
import UIKit

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
            if (info["type"] as? String) == "device_notify",
               let channel = info["channel"] as? String {
                let title = info["notify_title"] as? String ?? ""
                let body = info["notify_body"] as? String ?? ""
                if !title.isEmpty || !body.isEmpty {
                    DeviceRegistry.shared.forwardNotification(channel: channel, title: title, body: body)
                }
            } else if (info["type"] as? String) == "glasses_notify" {
                // Legacy: support old server payloads until fully deployed.
                let title = info["glasses_title"] as? String ?? ""
                let body = info["glasses_body"] as? String ?? ""
                if !title.isEmpty || !body.isEmpty {
                    DeviceRegistry.shared.forwardNotification(channel: "glasses", title: title, body: body)
                }
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
            completion(BridgeClient.shared.lastActivity != before ? .newData : .noData)
        }
    }
}

@MainActor
final class PushService {
    static let shared = PushService()

    private init() {}

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

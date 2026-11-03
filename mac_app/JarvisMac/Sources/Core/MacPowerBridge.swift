import AppKit
import IOKit.pwr_mgt

/// Wake Mac: the app registers for Apple push and hands its token to jc-client,
/// which gives it to the server. A "wake" push (sent when he taps Wake Mac on the
/// phone) reaches a sleeping Mac over Apple's push link; the app turns that brief
/// wake into a full one and tells jc-client, which then holds the Mac awake.
@MainActor
enum MacPowerBridge {
    static func start() {
        NSApp.registerForRemoteNotifications()
    }

    nonisolated static func tokenMessage(_ token: Data) -> [String: Any] {
        ["type": "mac_power_token", "token": token.map { String(format: "%02x", $0) }.joined(),
         "env": "development"]
    }

    static func didRegister(_ token: Data, link: JcLink = .shared) {
        link.request(tokenMessage(token))
    }

    static func didReceive(_ userInfo: [String: Any], link: JcLink = .shared) {
        let envelope = userInfo["jarviscopilot"] as? [String: Any] ?? userInfo
        guard (envelope["kind"] as? String) == "mac_wake" else { return }
        // A push can arrive during a dark wake (screen off): say there's a user,
        // so macOS finishes waking instead of dropping back to sleep.
        var id: IOPMAssertionID = 0
        _ = IOPMAssertionDeclareUserActivity("Jarvis: Wake Mac" as CFString, kIOPMUserActiveLocal, &id)
        link.request(["type": "mac_power_wake"])
    }
}

extension AppDelegate {
    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        MacPowerBridge.didRegister(deviceToken)
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NSLog("Jarvis: push registration failed: \(error.localizedDescription)")
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        MacPowerBridge.didReceive(userInfo)
    }

    /// jarvismac://settings[/<tab>] opens Jarvis Settings (e.g. /mac-power); the app
    /// has no menu bar icon, so this is the direct way in.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "jarvismac" && url.host == "settings" {
            let tab = url.pathComponents.dropFirst().first
            SettingsWindow.show(model: AppModel.shared, tab: tab)
        }
    }
}

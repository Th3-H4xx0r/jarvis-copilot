import AudioToolbox
import UIKit
import UserNotifications

/// Tells the person their rest is over.
@MainActor
protocol RestAlerting: AnyObject {
    /// A notification for when the rest ends — heard with the phone locked or
    /// in another app. Replaces any earlier one.
    func schedule(at date: Date, title: String, body: String)
    func cancel()
    /// The rest ran out with the app open: a tap and a chime instead of a banner.
    func arrived()
}

/// Rest alerts as a time-sensitive local notification (it breaks through a
/// Focus), and a haptic plus a sound when the app is on screen.
@MainActor
final class RestAlerts: RestAlerting {
    nonisolated static let identifier = "jc.rest"

    func schedule(at date: Date, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.threadIdentifier = Self.identifier
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, date.timeIntervalSinceNow), repeats: false)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
        center.add(UNNotificationRequest(identifier: Self.identifier, content: content, trigger: trigger)) { error in
            if let error { JcLog.dropped(JcLog.devices, "rest alert", error) }
        }
    }

    func cancel() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
    }

    func arrived() {
        guard UIApplication.shared.applicationState == .active else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        AudioServicesPlaySystemSound(1007)
    }
}

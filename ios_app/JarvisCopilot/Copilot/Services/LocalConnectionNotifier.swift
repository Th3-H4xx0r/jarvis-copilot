import Combine
import Foundation
import UserNotifications

/// Posts the connection monitor's "JARVIS disconnected / reconnected" lines as
/// local notifications.
///
/// Fire-and-forget: `ConnectionNotifier.notify` is called from the monitor's
/// debounce task and must not make it wait on the notification centre. A refused
/// authorization simply means nothing appears, which is the same outcome the
/// Flutter client had.
final class LocalConnectionNotifier: ConnectionNotifier, @unchecked Sendable {
    /// A fixed identifier per kind, so a flap replaces the previous banner
    /// instead of stacking two contradictory ones in Notification Centre.
    static let identifierPrefix = "jc.connection."

    private let notifier: any Notifying
    private let preferences: any KeyValueStore
    /// The in-flight post, so a test can await it instead of sleeping. NOT a
    /// `TaskHandle`: replacing one would cancel a banner that is still being
    /// posted, and a flap must not swallow the notification it just queued.
    private let lock = NSLock()
    private var lastPost: Task<Void, Never>?

    init(notifier: any Notifying = DefaultNotifier(),
         preferences: any KeyValueStore = UserDefaults.standard) {
        self.notifier = notifier
        self.preferences = preferences
    }

    /// The identifier a given banner is posted under. Pure, so the "one slot per
    /// kind" rule can be asserted without a notification centre.
    static func identifier(for title: String) -> String {
        identifierPrefix + (title.contains("reconnected") ? "up" : "down")
    }

    /// The banner this one has to replace — the opposite kind.
    static func opposite(of identifier: String) -> String {
        identifierPrefix + (identifier.hasSuffix("up") ? "down" : "up")
    }

    func notify(title: String, body: String) {
        let notifier = self.notifier
        let preferences = self.preferences
        let identifier = Self.identifier(for: title)
        let task = Task {
            // Cancel the opposite banner: seeing "disconnected" still sitting
            // there after a reconnect is worse than seeing nothing.
            await notifier.cancel(identifiers: [Self.opposite(of: identifier)])
            do {
                _ = try await notifier.post(LocalNotificationRequest(
                    title: title, body: body, identifier: identifier))
                preferences.set(true, forKey: SettingsStore.Keys.notificationsGranted)
            } catch {
                // The only realistic failure is a refused permission, and that
                // is worth telling the user about ONCE, in Settings, rather
                // than leaving them to wonder why drop banners never appear.
                JcLog.dropped(JcLog.services, "connection banner", error)
                preferences.set(false, forKey: SettingsStore.Keys.notificationsGranted)
            }
        }
        lock.lock(); lastPost = task; lock.unlock()
    }

    /// Await the in-flight post (tests).
    func waitForPost() async {
        lock.lock(); let task = lastPost; lock.unlock()
        await task?.value
    }
}

/// Feeds `ConnectionMonitor` from `BridgeClient`'s status.
///
/// Subscribes to the published `status` and reports edges only, so the
/// monitor's 4 s debounce can settle.
@MainActor
final class BridgeConnectionFeed {
    private let monitor: ConnectionMonitor
    private let connected: AnyPublisher<Bool, Never>
    private var subscription: AnyCancellable?

    init(monitor: ConnectionMonitor, connected: AnyPublisher<Bool, Never>? = nil) {
        self.monitor = monitor
        self.connected = connected
            ?? BridgeClient.shared.$status.map { $0 == .online }.eraseToAnyPublisher()
    }

    func start() {
        subscription = connected
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isConnected in
                MainActor.assumeIsolated { self?.monitor.connectionChanged(isConnected) }
            }
    }

    func stop() { subscription = nil }
}

import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

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
/// `BridgeClient` is still an `ObservableObject`, so there is no `AsyncSequence`
/// to await — this polls its `status` on a slow timer instead. A poll is enough
/// because the monitor debounces anyway (4 s), so a sub-second latency on the
/// edge would be thrown away regardless.
@MainActor
final class BridgeConnectionFeed {
    /// How often the bridge status is sampled. Well under the monitor's debounce
    /// window, so a real transition is never missed by more than one tick.
    static let intervalSeconds: TimeInterval = 1

    private let monitor: ConnectionMonitor
    private let isConnected: @MainActor () -> Bool
    private let sleeper: @Sendable (TimeInterval) async throws -> Void
    private let handle = TaskHandle()

    init(monitor: ConnectionMonitor,
         isConnected: @escaping @MainActor () -> Bool = { BridgeClient.shared.status == .online },
         sleeper: (@Sendable (TimeInterval) async throws -> Void)? = nil) {
        self.monitor = monitor
        self.isConnected = isConnected
        self.sleeper = sleeper ?? { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    }

    deinit { handle.cancel() }

    func start() {
        handle.replace(Task { [weak self] in
            var last: Bool?
            // Guard inside the loop: hoisted, the 1 s sampler pins the feed for
            // the life of the app and `deinit` (which cancels it) never runs.
            while !Task.isCancelled {
                guard let self else { return }
                let now = self.isConnected()
                if now != last {
                    last = now
                    self.monitor.connectionChanged(now)
                }
                try? await self.sleeper(Self.intervalSeconds)
            }
        })
    }

    func stop() { handle.cancel() }
}

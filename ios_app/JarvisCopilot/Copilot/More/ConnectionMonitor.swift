import Foundation

/// Where a "JARVIS disconnected / reconnected" line goes. Production posts a
/// `UNNotificationRequest`; tests record the calls.
protocol ConnectionNotifier: AnyObject, Sendable {
    func notify(title: String, body: String)
}

/// What the monitor decided to announce once a connection state settled.
enum ConnectionNotice: Equatable, Sendable {
    case reconnected
    case disconnected

    var title: String {
        switch self {
        case .reconnected: return "JARVIS reconnected"
        case .disconnected: return "JARVIS disconnected"
        }
    }

    var body: String {
        switch self {
        case .reconnected: return "Back online with your server."
        case .disconnected: return "Lost connection to your server."
        }
    }
}

/// The whole announce/stay-quiet decision, with no timers and no I/O.
///
/// Two rules, both from the Flutter monitor: the very first settle after launch
/// only establishes a baseline (we never announce the initial connect), and a
/// settle that matches the last announced state is a no-op.
struct ConnectionMonitorPolicy: Equatable, Sendable {
    /// The last state we actually announced; nil until the first settle.
    private(set) var lastNotified: Bool?

    init(lastNotified: Bool? = nil) { self.lastNotified = lastNotified }

    mutating func settled(_ connected: Bool) -> ConnectionNotice? {
        guard let last = lastNotified else {
            lastNotified = connected      // first settle: baseline, silently
            return nil
        }
        guard connected != last else { return nil }
        lastNotified = connected
        return connected ? .reconnected : .disconnected
    }
}

/// Watches the bridge connection flag and posts a local notification when the
/// link to the JARVIS server drops, and again when it comes back.
///
/// Debounced (4 s by default) so a reconnect flap doesn't spam: a change that
/// reverts before the delay elapses is dropped entirely. The delay is injected
/// so tests don't wait on wall-clock time.
@MainActor
final class ConnectionMonitor {
    /// Sleeps for the debounce window. Injected so tests can resume it instantly.
    typealias Sleeper = @Sendable (TimeInterval) async throws -> Void

    private let notifier: ConnectionNotifier
    private let debounce: TimeInterval
    private let sleeper: Sleeper
    private var policy = ConnectionMonitorPolicy()
    private let pending = TaskHandle()

    /// The current state as last reported, before debouncing.
    private(set) var connected: Bool

    init(connected: Bool = false,
         notifier: ConnectionNotifier,
         debounce: TimeInterval = 4,
         sleeper: Sleeper? = nil) {
        self.connected = connected
        self.notifier = notifier
        self.debounce = debounce
        self.sleeper = sleeper ?? { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    }

    deinit { pending.cancel() }

    /// Feed a new connection state. Safe to call on every flip.
    func connectionChanged(_ value: Bool) {
        connected = value
        let target = value
        pending.replace(Task { [weak self] in
            guard let self else { return }
            try? await self.sleeper(self.debounce)
            if Task.isCancelled { return }
            self.settle(target)
        })
    }

    /// Await the in-flight debounce (tests; also handy on `scenePhase` changes).
    func waitForPending() async {
        await pending.wait()
    }

    func cancel() { pending.cancel() }

    private func settle(_ target: Bool) {
        // Flapped back while we waited — the state we were about to announce is
        // no longer the truth, so say nothing at all.
        guard connected == target else { return }
        guard let notice = policy.settled(target) else { return }
        notifier.notify(title: notice.title, body: notice.body)
    }
}

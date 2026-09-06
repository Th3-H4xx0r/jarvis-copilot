import Foundation

/// One dispatched invoke, newest-first in `InvokeRunner.log`.
struct InvokeLogEntry {
    let skill: String
    let args: [String: Any]
    let result: [String: Any]?
    let error: String?
    let at: Date
}

/// Central skill dispatch. Whether the invoke arrived over the bridge socket or
/// via the silent-push poll path, both call in here so:
///
/// - disabled-skill ACLs are enforced in one place
/// - logging lives in one place
/// - the foreground UI can pause execution via a single flag
/// - foreground-required actions are deferred consistently
///
/// Port of `mobile_client/lib/services/invoke_runner.dart`.
@MainActor
final class InvokeRunner {
    struct Outcome {
        let result: [String: Any]?
        let error: String?

        static func ok(_ result: [String: Any]) -> Outcome { Outcome(result: result, error: nil) }
        static func err(_ message: String) -> Outcome { Outcome(result: nil, error: message) }
    }

    static let shared = InvokeRunner()

    /// Preference key for the kill switch. Its own key rather than a
    /// SettingsStore field: the runner has to answer `paused` before any store
    /// has loaded, on the very first invoke after a cold launch.
    static let pausedKey = "skills_paused"

    private let registry: SkillRegistry
    private let lifecycle: AppLifecycle
    private let pending: PendingActions
    private let notifier: any Notifying
    private let store: any KeyValueStore
    private let now: () -> Date

    /// When true, every invoke returns `error: "paused"` without touching the
    /// skill. A settings toggle owns this.
    ///
    /// Persisted: this is a kill switch. Losing it on relaunch silently re-armed
    /// every skill for a user who had deliberately switched dispatch off.
    var paused: Bool {
        didSet {
            guard paused != oldValue else { return }
            store.set(paused, forKey: Self.pausedKey)
        }
    }

    /// Most-recent invocations, newest first. Bounded — a logs view reads this
    /// to show history without paging from the server.
    private(set) var log: [InvokeLogEntry] = []
    private static let logCap = 200

    init(registry: SkillRegistry = .shared,
         lifecycle: AppLifecycle = .shared,
         pending: PendingActions = .shared,
         notifier: any Notifying = DefaultNotifier(),
         store: (any KeyValueStore)? = nil,
         now: @escaping () -> Date = Date.init) {
        self.registry = registry
        self.lifecycle = lifecycle
        self.pending = pending
        self.notifier = notifier
        // Defaults to the registry's own store (UserDefaults in production) so a
        // runner built around a test registry never writes to the real one.
        let store = store ?? registry.preferences
        self.store = store
        self.paused = store.bool(Self.pausedKey) ?? false
        self.now = now
    }

    func run(_ skillName: String, _ args: [String: Any]) async -> Outcome {
        if paused {
            append(skillName, args, error: "paused")
            return .err("paused")
        }
        if registry.disabled.contains(skillName) {
            append(skillName, args, error: "disabled")
            return .err("skill disabled by user")
        }
        guard let skill = registry.find(skillName) else {
            append(skillName, args, error: "unknown skill")
            return .err("unknown skill: \(skillName)")
        }
        // A foreground-required action (openURL / launch an app) can't run while
        // the app is backgrounded — iOS refuses it. The app stays alive in the
        // background (audio / bluetooth-central modes), so instead of failing we
        // DEFER: stash the action, post a LOCAL notification, and run it when
        // the user taps (the app foregrounds → the resume drain runs
        // PendingActions). This needs no remote push, so it works regardless of
        // whether APNs delivered anything.
        if shouldDeferToForeground(requiresForeground: skill.requiresForeground,
                                   isForeground: lifecycle.isForeground) {
            let banner = actionBannerTitle(skillName, args)
            let payload = notificationActionPayload(skill: skillName, args: args)
            // Awaited, not fired into a detached Task: the notification IS the
            // deferral. If it can't be posted (notifications off) there is
            // nothing for the user to tap, and answering `queued: true` told the
            // agent the action was on its way when it had silently vanished.
            do {
                try await notifier.post(LocalNotificationRequest(
                    title: banner, body: "Tap to run", payload: payload))
            } catch {
                let message = JcLog.report(JcLog.skills, "deferred-action notification", error)
                append(skillName, args, error: message)
                return .err("notifications are off — enable them to run this")
            }
            pending.add(skillName, args)
            append(skillName, args, result: ["deferred": true])
            return .ok([
                "queued": true,
                "note": "Sent to your phone — tap the notification to run it.",
            ])
        }
        do {
            let result = try await skill.run(args)
            append(skillName, args, result: result)
            return .ok(result)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            append(skillName, args, error: message)
            return .err(message)
        }
    }

    /// Drain the deferred queue. Called on foreground and whenever a
    /// notification tap enqueues something.
    @discardableResult
    func drainPending() async -> Int {
        guard lifecycle.isForeground else { return 0 }
        let actions = pending.drainFresh(now: now())
        for action in actions {
            _ = await run(action.skill, action.args)
        }
        return actions.count
    }

    private func append(_ skill: String, _ args: [String: Any],
                        result: [String: Any]? = nil, error: String? = nil) {
        log.insert(InvokeLogEntry(skill: skill, args: args, result: result,
                                  error: error, at: now()), at: 0)
        if log.count > Self.logCap { log.removeLast(log.count - Self.logCap) }
    }
}

/// True when a local tool ran WITHOUT throwing but didn't achieve its effect —
/// today only `open_app`, which returns `{launched:false}` when iOS has no URL
/// scheme for the requested app (many bank apps). The local matcher path uses
/// this to escalate to the server (which can supply a known scheme or answer
/// honestly) instead of speaking a fabricated "Opening X". A THROWN error is not
/// a "miss" — it's surfaced normally.
func localToolMissed(_ name: String, _ outcome: InvokeRunner.Outcome) -> Bool {
    guard outcome.error == nil else { return false }
    guard name == "open_app", let result = outcome.result else { return false }
    return SkillArgs.bool(result, "launched") == false
}

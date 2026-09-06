import Foundation
#if os(iOS)
import ActivityKit
#endif

/// The ActivityKit half of the Live Activity: starts one when there is something
/// to show, updates the running one, and forwards each activity's APNs push token.
///
/// Port of `LiveActivityManager` in the Flutter client's `AppDelegate.swift`.
/// Everything above it (what to show, when, how often) lives in
/// `LiveActivityCoordinator`, which talks to this through `ActivityControlling`.
@MainActor
final class DefaultActivityController: ActivityControlling {

    var onPushToken: ((String) -> Void)?

    /// Prefetches remote images referenced by a custom design's data payload, so
    /// the widget can render them without a network of its own.
    private let images: IslandImagePrefetching?
    /// Push-token observers, keyed by activity id, so each can be cancelled when
    /// its activity goes away instead of leaking a live `for await` per activity.
    private var tokenTasks: [String: Task<Void, Never>] = [:]
    private var observing = false
    /// Serialises the `await`-ing ActivityKit calls (see `ActivityUpdateQueue`).
    private let queue = ActivityUpdateQueue()
    /// The last ActivityKit failure, for diagnostics and the tests.
    private(set) var lastActivityError: String?

    /// Await whatever ActivityKit work is in flight (tests, scene handoffs).
    func drain() async { await queue.drain() }

    init(images: IslandImagePrefetching? = IslandImageCache()) {
        self.images = images
    }

    var areActivitiesEnabled: Bool {
        #if os(iOS)
        return ActivityAuthorizationInfo().areActivitiesEnabled
        #else
        return false
        #endif
    }

    func update(_ state: LiveActivityState) {
        #if os(iOS)
        guard areActivitiesEnabled else { return }
        images?.prefetch(IslandImageCache.urls(inData: state.data))
        let content = ActivityContent(state: Self.contentState(state), staleDate: nil)
        if let existing = Activity<JarvisActivityAttributes>.activities.first {
            // Through the queue, not a bare `Task`: unstructured tasks run in an
            // arbitrary order, so a stale frame could land after a newer one and
            // freeze the island on old text.
            queue.enqueue { await existing.update(content) }
            return
        }
        guard state.isWorthStarting else { return }
        startObserving()
        do {
            // Ask for a push token so the server can keep the activity fresh
            // while we are suspended. A build without the Push Notifications
            // capability (a free Apple account) FAILS this request outright, so
            // fall back to a token-less activity rather than showing nothing.
            let activity = try Activity.request(
                attributes: JarvisActivityAttributes(title: "JARVIS"),
                content: content, pushType: .token)
            observe(activity)
            lastActivityError = nil
        } catch {
            JcLog.dropped(JcLog.services, "live activity request (push token)", error)
            do {
                let activity = try Activity.request(
                    attributes: JarvisActivityAttributes(title: "JARVIS"), content: content)
                observe(activity)
                lastActivityError = nil
            } catch {
                // Both attempts failed — Live Activities are off for this app,
                // the budget is spent, or the target has no entitlement. Nothing
                // appears and nothing throws, so record why.
                lastActivityError = JcLog.report(JcLog.services, "live activity request", error)
            }
        }
        #endif
    }

    func end() {
        #if os(iOS)
        // The token streams only finish when their activity does, so cancel them
        // here: otherwise every ended activity leaves a live `for await` behind.
        for task in tokenTasks.values { task.cancel() }
        tokenTasks.removeAll()
        queue.enqueue {
            for activity in Activity<JarvisActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        #endif
    }

    #if os(iOS)
    static func contentState(_ s: LiveActivityState) -> JarvisActivityAttributes.ContentState {
        // Clamp both strips: the ~4 KB ContentState budget is a hard failure (iOS
        // silently drops the update), not a truncation.
        var devices = s.devices
        if devices.count > 8 { devices = Array(devices.prefix(8)) }
        var sessions = s.sessions
        if sessions.count > LiveFleet.maxRows { sessions = Array(sessions.prefix(LiveFleet.maxRows)) }
        return JarvisActivityAttributes.ContentState(
            state: s.state, transcript: s.transcript, activity: s.activity,
            connected: s.connected, devices: devices,
            mode: s.mode, sessions: sessions,
            sessionTotal: s.sessionTotal, entryTotal: s.entryTotal,
            waitingCount: s.waitingCount,
            usage5: s.usage5, usageWeek: s.usageWeek,
            usage5Resets: s.usage5Resets, usageWeekResets: s.usageWeekResets,
            designId: s.designId, designVersion: s.designVersion, data: s.data)
    }

    /// Observe push tokens for every current AND future activity. The
    /// per-activity token is what APNs uses to push-to-update while the app is
    /// suspended or closed.
    private func startObserving() {
        guard !observing else { return }
        observing = true
        Task { [weak self] in
            for activity in Activity<JarvisActivityAttributes>.activities {
                self?.observe(activity)
            }
            for await activity in Activity<JarvisActivityAttributes>.activityUpdates {
                self?.observe(activity)
            }
        }
    }

    private func observe(_ activity: Activity<JarvisActivityAttributes>) {
        let id = activity.id
        guard tokenTasks[id] == nil else { return }
        tokenTasks[id] = Task { [weak self] in
            for await data in activity.pushTokenUpdates {
                let hex = data.map { String(format: "%02x", $0) }.joined()
                await MainActor.run { self?.onPushToken?(hex) }
            }
            // The stream ends when the activity does; drop the slot so the map
            // can't grow for the life of the process.
            await MainActor.run { self?.tokenTasks[id] = nil }
        }
    }
    #endif
}

/// Runs `await`-ing work strictly in the order it was submitted.
///
/// ActivityKit's `update` / `end` are async, and firing an unstructured `Task`
/// per call lets the runtime interleave them: a stale frame can land after a
/// newer one and leave the island showing old text until the next update.
@MainActor
final class ActivityUpdateQueue {
    private var tail: Task<Void, Never>?

    func enqueue(_ work: @escaping @Sendable () async -> Void) {
        let previous = tail
        tail = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    /// Await everything currently queued (tests, and scene-phase handoffs).
    func drain() async { await tail?.value }
}

/// Records instead of pushing — used on macOS, in previews, and whenever
/// ActivityKit is unavailable.
@MainActor
final class NoopActivityController: ActivityControlling {
    var onPushToken: ((String) -> Void)?
    var areActivitiesEnabled: Bool { false }
    private(set) var updates: [LiveActivityState] = []
    private(set) var ends = 0
    func update(_ state: LiveActivityState) { updates.append(state) }
    func end() { ends += 1 }
}

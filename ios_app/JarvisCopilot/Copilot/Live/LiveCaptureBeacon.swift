import ActivityKit
import Foundation
#if os(iOS)
import UIKit
#endif

/// The one place outside the Live screen that knows the phone is recording the
/// room: the tab-bar indicator and the Live Activity.
///
/// **Why this is not on `LiveStore`.** The nav bar is built at launch on every
/// tab, and `LiveStore` owns a microphone, an audio session, a speech
/// recogniser and an on-disk spool. Reading `LiveStore.shared.capturing` from
/// the tab bar would construct all of that at launch for a user who never opens
/// Live. This type holds nothing but two facts and an `Activity` handle, so the
/// tab bar can observe it for free.
///
/// **Why the activity can never outlive capture.** Three independent guards,
/// because a Live Activity still saying "recording" after recording stopped
/// tells the user they are being listened to when they are not — the worst
/// failure this feature has:
///
///   1. `end()` on every path that stops capture (`LiveStore.stop`, which every
///      halt, lane switch and interruption teardown funnels through).
///   2. `reapOrphans()` on app termination, from `willTerminateNotification`.
///   3. `reapOrphans()` whenever the app comes to the foreground. iOS does not
///      promise to deliver `willTerminate`, and an activity outlives the
///      process, so this is the backstop: a fresh process is by definition not
///      capturing, and any activity it finds is therefore a ghost.
@MainActor
@Observable
final class LiveCaptureBeacon {

    static let shared = LiveCaptureBeacon()

    /// Minimum gap between pushes of the retained-audio figure. Everything else
    /// here is event-driven; this is the only value that moves on its own, and
    /// a byte count creeping up is not worth an island update per frame.
    static let figureWindowSeconds: TimeInterval = 30

    /// True from the moment the microphone is running to the moment it stops.
    /// The tab bar reads exactly this.
    private(set) var capturing = false
    /// When capture began, or nil. Also the activity's clock origin.
    private(set) var startedAt: Date?
    /// True while the mic is held by something else. The tab dot goes amber.
    private(set) var interrupted = false

    private var activity: Activity<LiveCaptureAttributes>?
    private var lastPush = Date.distantPast
    private var sent: LiveCaptureAttributes.ContentState?
    /// `Activity.request` throws while the app is backgrounded, which is where
    /// a recording resumed by the mic watchdog runs. Retried, not abandoned.
    private var lastAttempt = Date.distantPast
    static let retrySeconds: TimeInterval = 4

    private init() {}

    // MARK: - Capture lifecycle

    /// Capture started. `at` is the true origin so a session resumed after a
    /// relaunch can hand over the clock it already had.
    func began(at: Date = Date(), kept: String, detail: String) {
        capturing = true
        interrupted = false
        startedAt = at
        sent = nil
        lastPush = .distantPast
        lastAttempt = .distantPast
        push(state(paused: false, elapsed: 0, kept: kept, detail: detail), force: true)
    }

    /// Something changed that the island should reflect. Cheap to call often —
    /// it drops anything the island already shows, and rate-limits the rest.
    func update(interrupted paused: Bool, elapsed: TimeInterval,
                kept: String, detail: String) {
        guard capturing else { return }
        interrupted = paused
        // A pause or a new qualifier is an EVENT and goes at once; a figure that
        // merely grew waits for the window.
        let next = state(paused: paused, elapsed: elapsed, kept: kept, detail: detail)
        let eventful = sent.map { $0.paused != next.paused || $0.detail != next.detail } ?? true
        push(next, force: eventful)
    }

    /// Capture stopped, for any reason at all.
    func ended() {
        capturing = false
        interrupted = false
        startedAt = nil
        sent = nil
        end()
    }

    // MARK: - Orphans

    /// End any activity left behind by a previous process, or by a stop this
    /// process somehow failed to report.
    ///
    /// Safe to call at launch, on every foreground and on termination: it only
    /// ends activities when this process is not capturing.
    func reapOrphans() {
        guard !capturing else {
            // Capturing and the activity went missing (the user swiped it away,
            // or `request` failed while backgrounded) — ask for it again.
            if activity == nil { lastAttempt = .distantPast }
            return
        }
        guard !Activity<LiveCaptureAttributes>.activities.isEmpty else { return }
        JcLog.voice.notice("live: ending a recording Live Activity left over from a previous run")
        end()
    }

    /// Wire the process-wide hooks. Called once from the app entry point.
    func observeAppLifecycle() {
        #if os(iOS)
        NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                // Not `ended()`: the store is the owner of `capturing`, and a
                // termination is not a stop. The activity must go regardless,
                // because nothing will be recording a moment from now.
                LiveCaptureBeacon.shared.end()
            }
        }
        #endif
    }

    // MARK: - ActivityKit

    private func state(paused: Bool, elapsed: TimeInterval,
                       kept: String, detail: String) -> LiveCaptureAttributes.ContentState {
        LiveCaptureAttributes.ContentState(
            paused: paused,
            pausedElapsed: max(0, elapsed),
            kept: Self.clamp(kept),
            detail: Self.clamp(detail))
    }

    private static func clamp(_ text: String) -> String {
        let limit = LiveCaptureAttributes.maxTextChars
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }

    private func push(_ next: LiveCaptureAttributes.ContentState, force: Bool) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard let activity else { request(next); return }
        guard next != sent else { return }
        guard force || Date().timeIntervalSince(lastPush) >= Self.figureWindowSeconds else { return }
        sent = next
        lastPush = Date()
        let content = ActivityContent(state: next, staleDate: nil)
        Task { await activity.update(content) }
    }

    private func request(_ next: LiveCaptureAttributes.ContentState) {
        guard Date().timeIntervalSince(lastAttempt) > Self.retrySeconds else { return }
        lastAttempt = Date()
        let attributes = LiveCaptureAttributes(startedAt: startedAt ?? Date())
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: next, staleDate: nil))
            sent = next
            lastPush = Date()
        } catch {
            // A background `request` is refused; so is a build with Live
            // Activities switched off for the app. Recorded, never fatal — the
            // recording itself is unaffected.
            JcLog.dropped(JcLog.voice, "live recording activity", error)
        }
    }

    /// Ends the handle we hold AND anything else of this type that exists, so a
    /// ghost from an earlier process goes with it.
    private func end() {
        activity = nil
        sent = nil
        let ending = Activity<LiveCaptureAttributes>.activities
        guard !ending.isEmpty else { return }
        Task { for one in ending { await one.end(nil, dismissalPolicy: .immediate) } }
    }
}

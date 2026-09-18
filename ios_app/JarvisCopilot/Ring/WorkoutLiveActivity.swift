import ActivityKit
import Foundation

/// The running workout's Live Activity. The timer counts itself; heart rate
/// and distance are pushed on a state change or every 10 s at most — the
/// update budget, not every tick.
@MainActor
final class WorkoutLiveActivity {
    private var activity: Activity<RingWorkoutAttributes>?
    private var lastPush = Date.distantPast
    private var lastRunning: Bool?
    private var lastAttempt = Date.distantPast

    init() {
        // After a crash the activity outlives the app: adopt it rather than
        // open a second one beside it.
        activity = Activity<RingWorkoutAttributes>.activities.first
    }

    var isShowing: Bool { activity != nil }

    func update(sport: RingSport, running: Bool, elapsed: Int, heartRate: Int?, distanceKm: Double?, zone: Int?) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = RingWorkoutAttributes.ContentState(
            running: running, reference: Date().addingTimeInterval(-Double(elapsed)),
            frozenElapsed: Double(elapsed), heartRate: heartRate, distanceKm: distanceKm, zone: zone)
        let content = ActivityContent(state: state, staleDate: nil)
        guard let activity else {
            // iOS refuses a request while the app is in the background (a
            // workout picked up after a relaunch); try again every few seconds
            // and when the app comes forward.
            guard Date().timeIntervalSince(lastAttempt) > 4 else { return }
            lastAttempt = Date()
            do {
                self.activity = try Activity.request(
                    attributes: RingWorkoutAttributes(sport: sport.name, symbol: sport.symbol), content: content)
                lastPush = Date()
                lastRunning = running
            } catch {
                JcLog.dropped(JcLog.devices, "workout live activity", error)
            }
            return
        }
        guard running != lastRunning || Date().timeIntervalSince(lastPush) >= 10 else { return }
        lastPush = Date()
        lastRunning = running
        Task { await activity.update(content) }
    }

    /// Try again now (the app just came forward).
    func retry() { lastAttempt = .distantPast }

    func end() {
        let ending = Activity<RingWorkoutAttributes>.activities
        activity = nil
        lastRunning = nil
        Task { for a in ending { await a.end(nil, dismissalPolicy: .immediate) } }
    }
}

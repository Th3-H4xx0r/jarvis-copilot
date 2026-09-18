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

    func update(sport: RingSport, running: Bool, elapsed: Int, heartRate: Int?, distanceKm: Double?, zone: Int?) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = RingWorkoutAttributes.ContentState(
            running: running, reference: Date().addingTimeInterval(-Double(elapsed)),
            frozenElapsed: Double(elapsed), heartRate: heartRate, distanceKm: distanceKm, zone: zone)
        let content = ActivityContent(state: state, staleDate: nil)
        guard let activity else {
            self.activity = try? Activity.request(
                attributes: RingWorkoutAttributes(sport: sport.name, symbol: sport.symbol), content: content)
            lastPush = Date()
            lastRunning = running
            return
        }
        guard running != lastRunning || Date().timeIntervalSince(lastPush) >= 10 else { return }
        lastPush = Date()
        lastRunning = running
        Task { await activity.update(content) }
    }

    func end() {
        let ending = activity
        activity = nil
        lastRunning = nil
        Task { await ending?.end(nil, dismissalPolicy: .immediate) }
    }
}

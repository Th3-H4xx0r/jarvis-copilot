import Foundation
import ActivityKit

/// The skill's view of the stopwatch. `StopwatchService` is the real one;
/// tests use `MockStopwatch`.
protocol Stopwatching: Sendable {
    /// Apply one action and return the resulting state.
    @MainActor func perform(_ action: StopwatchAction, at now: Date) -> StopwatchCore
}

enum StopwatchAction: String, CaseIterable, Sendable {
    case start, stop, lap, reset, read
}

/// Boundary default: reaches the main-actor singleton only inside the
/// main-actor call, so it can be built from a nonisolated initializer.
struct DefaultStopwatch: Stopwatching {
    @MainActor func perform(_ action: StopwatchAction, at now: Date) -> StopwatchCore {
        StopwatchService.shared.perform(action, at: now)
    }
}

/// App-lifetime stopwatch: persists across launches (UserDefaults) and mirrors
/// itself into a Live Activity so the Dynamic Island counts up while the app
/// is closed. iOS has no system stopwatch API — this is the whole thing.
@MainActor
final class StopwatchService: Stopwatching {
    static let shared = StopwatchService()
    private static let key = "jc.stopwatch"

    private(set) var core: StopwatchCore
    private let defaults: UserDefaults
    /// A Live Activity we could not open (backgrounded); retried on `.active`.
    private var pendingActivity = false
    private let queue = ActivityUpdateQueue()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(StopwatchCore.self, from: data) {
            core = saved
        } else {
            core = StopwatchCore()
        }
    }

    func perform(_ action: StopwatchAction, at now: Date = Date()) -> StopwatchCore {
        switch action {
        case .start: core.start(at: now)
        case .stop: core.stop(at: now)
        case .lap: core.lap(at: now)
        case .reset: core.reset()
        case .read: break
        }
        if action != .read {
            if let data = try? JSONEncoder().encode(core) { defaults.set(data, forKey: Self.key) }
            syncActivity(now: now, ended: action == .reset)
        }
        return core
    }

    // MARK: - Live Activity

    private func syncActivity(now: Date, ended: Bool) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let elapsed = core.elapsed(at: now)
        let state = JarvisStopwatchAttributes.ContentState(
            running: core.isRunning,
            reference: now.addingTimeInterval(-elapsed),
            frozenElapsed: elapsed,
            laps: Array(core.laps.suffix(8)),   // ~4 KB ContentState budget
            lapCount: core.laps.count)
        let content = ActivityContent(state: state, staleDate: nil)
        let live = Activity<JarvisStopwatchAttributes>.activities
        // Through a serial queue, never a bare `Task`: unstructured tasks run
        // in an arbitrary order, so start→lap could land backwards and freeze
        // the island on a stale frame (the same hazard LiveActivityController
        // documents).
        if ended {
            queue.enqueue { for a in live { await a.end(nil, dismissalPolicy: .immediate) } }
            return
        }
        if let existing = live.first {
            queue.enqueue { await existing.update(content) }
            return
        }
        do {
            _ = try Activity.request(attributes: JarvisStopwatchAttributes(label: "Stopwatch"), content: content)
            pendingActivity = false
        } catch {
            // `Activity.request` throws when the app is backgrounded, which is
            // exactly where a voice-driven "start the stopwatch" runs. Remember
            // that we owe an activity and open it when we next come forward.
            pendingActivity = true
            JcLog.dropped(JcLog.services, "stopwatch live activity", error)
        }
    }

    /// Called when the app becomes active: opens the Live Activity that
    /// `Activity.request` refused while we were in the background.
    func resyncActivity() {
        guard pendingActivity, core.isRunning || core.elapsed(at: Date()) > 0 else { return }
        syncActivity(now: Date(), ended: false)
    }
}

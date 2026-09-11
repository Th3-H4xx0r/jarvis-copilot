import ActivityKit
import Foundation

/// The JARVIS stopwatch as a Live Activity (Dynamic Island + Lock Screen).
/// Shared between the app (which owns the stopwatch) and the widget (which
/// renders it). iOS has no system stopwatch API, so this IS the stopwatch UI
/// outside the app.
struct JarvisStopwatchAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// True while running. The widget then counts up from `reference`.
        var running: Bool
        /// When running: the instant the display should treat as t=0 (now minus
        /// the elapsed time so far). When stopped: unused.
        var reference: Date
        /// Elapsed seconds at the moment of the last stop (shown while stopped).
        var frozenElapsed: TimeInterval
        /// The most recent lap durations, oldest first. Capped by the app
        /// (4 KB ContentState budget) — see `lapCount` for how many there are.
        var laps: [TimeInterval]
        /// Total laps taken, which `laps` may not hold all of. The island
        /// labels the newest lap with this, so lap 12 doesn't read "Lap 8".
        var lapCount: Int = 0
    }

    var label: String
}

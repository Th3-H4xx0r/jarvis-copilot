#if os(iOS)
import ActivityKit
import Foundation

/// The JARVIS stopwatch as a Live Activity (Dynamic Island + Lock Screen).
/// Shared between the app (which owns the stopwatch) and the widget (which
/// renders it). iOS has no system stopwatch API, so this IS the stopwatch UI
/// outside the app.
@available(iOS 16.2, *)
struct JarvisStopwatchAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// True while running. The widget then counts up from `reference`.
        var running: Bool
        /// When running: the instant the display should treat as t=0 (now minus
        /// the elapsed time so far). When stopped: unused.
        var reference: Date
        /// Elapsed seconds at the moment of the last stop (shown while stopped).
        var frozenElapsed: TimeInterval
        /// Lap durations, most recent last. Capped by the app (4 KB budget).
        var laps: [TimeInterval]
    }

    var label: String
}
#endif

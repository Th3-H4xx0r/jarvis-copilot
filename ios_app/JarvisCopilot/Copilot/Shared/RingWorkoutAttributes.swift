import ActivityKit
import Foundation

/// A ring workout on the Lock Screen and in the Dynamic Island. Shared by the
/// app (which runs the workout) and the widget (which draws it).
struct RingWorkoutAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// True while running: the widget counts up from `reference` itself.
        var running: Bool
        /// Now minus the active time so far — t = 0 for a live timer.
        var reference: Date
        /// Active seconds at the last pause (shown while paused).
        var frozenElapsed: TimeInterval
        var heartRate: Int?
        var distanceKm: Double?
        /// Heart-rate zone 1–5.
        var zone: Int?
        /// Strength: a rest running until then (the widget counts it down itself).
        var restEnds: Date? = nil
        var restStarted: Date? = nil
        /// Strength: what comes next — "Bench Press · set 3 · 60 kg × 8".
        var detail: String? = nil
        /// Distance shown in miles (the person's unit), else kilometres.
        var miles: Bool? = nil

        /// "3.42 mi" or "5.51 km".
        var distanceText: String? {
            distanceKm.map { miles == true ? String(format: "%.2f mi", $0 / 1.609344) : String(format: "%.2f km", $0) }
        }
    }

    var sport: String
    /// SF Symbol for the sport.
    var symbol: String
}

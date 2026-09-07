import Foundation

/// The stopwatch's arithmetic, free of clocks and Live Activities so it can
/// be tested with fixed dates. `StopwatchService` wraps it with persistence
/// and the Dynamic Island.
struct StopwatchCore: Codable, Equatable, Sendable {
    /// Elapsed time accumulated across earlier run segments.
    var accumulated: TimeInterval = 0
    /// Start of the current run segment; nil while stopped.
    var runningSince: Date?
    /// Lap durations (time since the previous lap / start), oldest first.
    var laps: [TimeInterval] = []
    /// Elapsed at the last lap mark, so the next lap measures from there.
    var lastLapMark: TimeInterval = 0

    static let maxLaps = 50

    var isRunning: Bool { runningSince != nil }

    func elapsed(at now: Date) -> TimeInterval {
        guard let since = runningSince else { return accumulated }
        return accumulated + max(0, now.timeIntervalSince(since))
    }

    /// No-op when already running.
    mutating func start(at now: Date) {
        guard runningSince == nil else { return }
        runningSince = now
    }

    /// No-op when already stopped.
    mutating func stop(at now: Date) {
        guard let since = runningSince else { return }
        accumulated += max(0, now.timeIntervalSince(since))
        runningSince = nil
    }

    /// Records the time since the previous lap. Works while stopped too (a lap
    /// of the frozen remainder), matching the Clock app.
    @discardableResult
    mutating func lap(at now: Date) -> TimeInterval {
        let total = elapsed(at: now)
        let lapTime = max(0, total - lastLapMark)
        lastLapMark = total
        laps.append(lapTime)
        if laps.count > Self.maxLaps { laps.removeFirst(laps.count - Self.maxLaps) }
        return lapTime
    }

    mutating func reset() {
        self = StopwatchCore()
    }

    /// "1:02:03.4" / "02:03.4" — what the skill reports and the island shows.
    static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, seconds)
        let h = Int(total) / 3600
        let m = (Int(total) % 3600) / 60
        let s = total - Double(h * 3600 + m * 60)
        if h > 0 { return String(format: "%d:%02d:%04.1f", h, m, s) }
        return String(format: "%02d:%04.1f", m, s)
    }
}

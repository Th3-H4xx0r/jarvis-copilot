import Foundation

/// A day's resting heart rate from the ring's readings.
///
/// The night says it best: asleep, the heart settles, so the lowest steady
/// stretch of the main sleep is the resting rate (a single dip is noise, so
/// it is the mean of the three lowest readings). With no sleep recorded, the
/// day's readings are smoothed over three in a row and the lowest of those
/// stands in — a few quiet minutes, not one odd beat.
enum RestingHeartRate {
    /// Below this is a misread, above it is not resting.
    static let plausible = 30.0...120.0

    static func forDay(_ day: RingDay, calendar: Calendar = .current) -> (bpm: Int, at: Date?)? {
        guard let series = day.heartRate, let midnight = RingDates.date(forKey: day.date, calendar: calendar) else {
            return nil
        }
        let readings = series.readings.filter { plausible.contains($0.value) }
        guard readings.count >= 3 else { return nil }
        if let night = day.sleep.max(by: { $0.asleepMinutes < $1.asleepMinutes }) {
            let asleep = readings.filter { reading in
                let at = midnight.addingTimeInterval(Double(reading.minute) * 60)
                return at >= night.start && at <= night.end
            }
            if asleep.count >= 3 {
                let lowest = asleep.map(\.value).sorted().prefix(3)
                return (Int((lowest.reduce(0, +) / 3).rounded()), night.end)
            }
        }
        guard readings.count >= 5, let quiet = quietest(readings) else { return nil }
        return (Int(quiet.value.rounded()), midnight.addingTimeInterval(Double(quiet.minute) * 60))
    }

    /// The lowest three-in-a-row average, and the minute it sits on.
    static func quietest(_ readings: [(minute: Int, value: Double)]) -> (minute: Int, value: Double)? {
        guard readings.count >= 3 else { return nil }
        var best: (minute: Int, value: Double)?
        for i in 1..<(readings.count - 1) {
            let mean = (readings[i - 1].value + readings[i].value + readings[i + 1].value) / 3
            if mean < (best?.value ?? .infinity) { best = (readings[i].minute, mean) }
        }
        return best
    }
}

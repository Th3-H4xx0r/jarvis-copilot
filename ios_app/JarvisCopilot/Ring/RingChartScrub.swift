import Foundation

/// What a ring chart's headline says while a finger is on the chart: the reading at
/// that moment, and when it was.
struct RingScrubReadout: Equatable {
    let value: String
    let caption: String
}

/// The "what was it at this time" lookups behind the scrubbable ring charts. Pure,
/// so they are tested without a chart on screen.
enum RingChartScrub {

    /// The reading closest to `hour` (fractional hour of the day), or nil when none
    /// is within `tolerance` minutes — scrubbing across a gap says so rather than
    /// borrowing a reading from hours away.
    static func nearest(_ readings: [RingTimedValue], hour: Double,
                        toleranceMinutes tolerance: Int) -> RingTimedValue? {
        let target = hour * 60
        guard let best = readings.min(by: { abs(Double($0.minute) - target) < abs(Double($1.minute) - target) })
        else { return nil }
        return abs(Double(best.minute) - target) <= Double(tolerance) ? best : nil
    }

    /// The 15-minute step slot under `hour`, and the day's steps up to the end of it.
    static func steps(_ slots: [RingStepSlot], hour: Double) -> (slot: Int, steps: Int, soFar: Int) {
        let index = min(95, max(0, Int(hour * 4)))
        let steps = slots.filter { $0.slot == index }.reduce(0) { $0 + $1.steps }
        let soFar = slots.filter { $0.slot <= index }.reduce(0) { $0 + $1.steps }
        return (index, steps, soFar)
    }

    /// The sleep stage running at `date`, with its bounds.
    static func stage(in night: RingSleepSession, at date: Date) -> (stage: Int, start: Date, end: Date)? {
        var cursor = night.start
        for stage in night.stages {
            let end = cursor.addingTimeInterval(TimeInterval(stage.minutes * 60))
            if date >= cursor && date < end { return (stage.stage, cursor, end) }
            cursor = end
        }
        return nil
    }

    /// The hour's low–high band from a ring min/max series, when it has one.
    static func hourRange(_ values: RingMinMax?, hour: Double) -> (low: Int, high: Int)? {
        guard let values else { return nil }
        let index = Int(hour)
        guard index >= 0, index < values.min.count, index < values.max.count else { return nil }
        let low = values.min[index], high = values.max[index]
        guard low > 0, high > 0 else { return nil }
        return (min(low, high), max(low, high))
    }

    /// "2:15 PM" for a minute of the day.
    /// A chart hour as the phone's own clock: "6 PM" here, "18" where the locale is 24-hour.
    static func hourLabel(_ hour: Double, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("j")
        let clamped = min(23, max(0, Int(hour.rounded()) % 24))
        let date = Calendar.current.startOfDay(for: Date()).addingTimeInterval(TimeInterval(clamped * 3600))
        return formatter.string(from: date)
    }

    static func clock(minute: Int) -> String {
        Calendar.current.startOfDay(for: Date())
            .addingTimeInterval(TimeInterval(minute * 60))
            .formatted(date: .omitted, time: .shortened)
    }
}

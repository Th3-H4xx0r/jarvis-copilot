import Foundation

/// The numbers on a habit's card and page, worked out from its relapses:
/// streaks, relapses per hour / day / week / month, the goal, the month's
/// calendar. Pure, with the calendar passed in, so tests pin a timezone.
enum HabitMath {

    // MARK: Streaks

    /// Where the streak under way began: the last relapse, or the quit date
    /// when that is later (moving the quit date is a fresh start).
    static func since(_ habit: Habit, _ relapses: [HabitRelapse]) -> Date {
        max(habit.startedAt, relapses.map(\.at).max() ?? .distantPast)
    }

    /// Where the habit's history begins: the quit date, or an earlier relapse.
    static func start(_ habit: Habit, _ relapses: [HabitRelapse]) -> Date {
        min(habit.startedAt, relapses.map(\.at).min() ?? .distantFuture)
    }

    /// The longest stretch without a relapse, the one under way included.
    static func longestStreak(_ habit: Habit, _ relapses: [HabitRelapse], now: Date) -> TimeInterval {
        let points = [start(habit, relapses)] + relapses.map(\.at).sorted()
        let gaps = zip(points, points.dropFirst()).map { $1.timeIntervalSince($0) }
        return max(gaps.max() ?? 0, now.timeIntervalSince(since(habit, relapses)), 0)
    }

    /// "42s", "4m 12s", "3h 5m", "12d 4h 31m".
    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let days = s / 86_400, hours = s % 86_400 / 3600, minutes = s % 3600 / 60
        if days > 0 { return "\(days)d \(hours)h \(minutes)m" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(s % 60)s" }
        return "\(s)s"
    }

    static func count(_ relapses: [HabitRelapse], in interval: DateInterval) -> Int {
        relapses.reduce(0) { $0 + ($1.at >= interval.start && $1.at < interval.end ? 1 : 0) }
    }

    // MARK: Periods

    /// What a range shows around `date`: the day; the 7 days ending on it; its
    /// calendar month; the 6 or 12 months ending with its month.
    static func period(_ range: HealthRange, containing date: Date, calendar: Calendar = .current) -> DateInterval {
        let day = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        let month = calendar.dateInterval(of: .month, for: date) ?? DateInterval(start: day, end: dayEnd)
        func months(_ n: Int) -> DateInterval {
            DateInterval(start: calendar.date(byAdding: .month, value: -(n - 1), to: month.start) ?? month.start, end: month.end)
        }
        switch range {
        case .day: return DateInterval(start: day, end: dayEnd)
        case .week: return DateInterval(start: calendar.date(byAdding: .day, value: -6, to: day) ?? day, end: dayEnd)
        case .month: return month
        case .halfYear: return months(6)
        case .year: return months(12)
        }
    }

    /// The period before `period`, for "fewer than last month".
    static func previous(_ range: HealthRange, before period: DateInterval, calendar: Calendar = .current) -> DateInterval {
        self.period(range, containing: period.start.addingTimeInterval(-1), calendar: calendar)
    }

    /// `anchor` moved `by` whole periods, never past now.
    static func step(_ range: HealthRange, from anchor: Date, by n: Int, now: Date, calendar: Calendar = .current) -> Date {
        let moved: Date?
        switch range {
        case .day: moved = calendar.date(byAdding: .day, value: n, to: anchor)
        case .week: moved = calendar.date(byAdding: .day, value: 7 * n, to: anchor)
        case .month: moved = calendar.date(byAdding: .month, value: n, to: anchor)
        case .halfYear: moved = calendar.date(byAdding: .month, value: 6 * n, to: anchor)
        case .year: moved = calendar.date(byAdding: .month, value: 12 * n, to: anchor)
        }
        return min(moved ?? anchor, now)
    }

    /// The period holding `anchor` is the one under way.
    static func isCurrent(_ range: HealthRange, anchor: Date, now: Date, calendar: Calendar = .current) -> Bool {
        period(range, containing: anchor, calendar: calendar).end > now
    }

    // MARK: Bars

    struct Bucket: Identifiable, Equatable {
        let id: Int
        let start: Date
        let end: Date
        var count: Int
    }

    /// What one bar stands for: an hour, a day, a week or a month.
    static func unit(_ range: HealthRange) -> Calendar.Component {
        switch range {
        case .day: return .hour
        case .week, .month: return .day
        case .halfYear: return .weekOfYear
        case .year: return .month
        }
    }

    /// One bar per unit across the period (weeks clipped to its edges), each
    /// with the relapses inside it.
    static func buckets(_ relapses: [HabitRelapse], range: HealthRange, period: DateInterval,
                        calendar: Calendar = .current) -> [Bucket] {
        let unit = unit(range)
        var out: [Bucket] = []
        var cursor = period.start
        while cursor < period.end {
            let next = unit == .weekOfYear
                ? calendar.dateInterval(of: .weekOfYear, for: cursor)?.end
                : calendar.date(byAdding: unit, value: 1, to: cursor)
            guard let next, next > cursor else { break }
            let end = min(next, period.end)
            out.append(Bucket(id: out.count, start: cursor, end: end, count: 0))
            cursor = end
        }
        for relapse in relapses where relapse.at >= period.start && relapse.at < period.end {
            if let i = out.firstIndex(where: { relapse.at < $0.end }) { out[i].count += 1 }
        }
        return out
    }

    // MARK: Days and the goal

    enum DayStatus: Equatable {
        /// No relapse.
        case clean
        /// Some, but no more than the daily limit.
        case within
        /// More than the daily limit, or any at all without one.
        case over
        case beforeStart
        case future

        var metGoal: Bool { self == .clean || self == .within }
    }

    static func status(day: Date, count: Int, habit: Habit, start: Date, now: Date,
                       calendar: Calendar = .current) -> DayStatus {
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        if dayStart > now { return .future }
        if dayEnd <= start { return .beforeStart }
        if count == 0 { return .clean }
        if let limit = habit.goal.limit, limit.per == .day, count <= limit.count { return .within }
        return .over
    }

    /// "1 of 2 today" / "3 of 5 this month", and whether it is past the limit.
    static func limitLine(_ habit: Habit, _ relapses: [HabitRelapse], now: Date,
                          calendar: Calendar = .current) -> (text: String, over: Bool)? {
        guard let limit = habit.goal.limit,
              let span = calendar.dateInterval(of: limit.per == .day ? .day : .month, for: now) else { return nil }
        let used = count(relapses, in: span)
        return ("\(used) of \(limit.count) \(limit.per == .day ? "today" : "this month")", used > limit.count)
    }

    // MARK: Calendar

    struct GridCell: Identifiable, Equatable {
        let id: Int
        /// The day's bar, for selecting it; nil for the blanks before the 1st.
        let bucket: Int?
        let day: Date?
        let count: Int
        let status: DayStatus?
    }

    /// A month's day buckets laid out as a calendar: blanks until the 1st's
    /// weekday, then one cell per day.
    static func monthGrid(buckets: [Bucket], habit: Habit, start: Date, now: Date,
                          calendar: Calendar = .current) -> [GridCell] {
        guard let first = buckets.first else { return [] }
        let lead = (calendar.component(.weekday, from: first.start) - calendar.firstWeekday + 7) % 7
        var cells = (0..<lead).map { GridCell(id: $0, bucket: nil, day: nil, count: 0, status: nil) }
        for bucket in buckets {
            cells.append(GridCell(id: cells.count, bucket: bucket.id, day: bucket.start, count: bucket.count,
                                  status: status(day: bucket.start, count: bucket.count, habit: habit, start: start,
                                                 now: now, calendar: calendar)))
        }
        return cells
    }

    // MARK: Stats

    struct Stats: Equatable {
        var total: Int
        var dailyAverage: Double
        var cleanDays: Int
        /// Days of the period the habit was being tracked, up to today.
        var measuredDays: Int
        var longest: TimeInterval
        var mostInADay: Int
    }

    static func stats(_ relapses: [HabitRelapse], habit: Habit, period: DateInterval, now: Date,
                      calendar: Calendar = .current) -> Stats {
        let first = start(habit, relapses)
        let inside = relapses.filter { $0.at >= period.start && $0.at < period.end }
        var perDay: [Int] = []
        var cursor = max(period.start, calendar.startOfDay(for: first))
        let last = min(period.end, now)
        while cursor < last, let next = calendar.date(byAdding: .day, value: 1, to: cursor) {
            perDay.append(count(inside, in: DateInterval(start: cursor, end: next)))
            cursor = next
        }
        // The longest clean stretch inside the period.
        var longest: TimeInterval = 0
        let from = max(period.start, first), to = min(period.end, now)
        if from < to {
            let points = [from] + inside.map(\.at).filter { $0 > from && $0 < to }.sorted() + [to]
            longest = zip(points, points.dropFirst()).map { $1.timeIntervalSince($0) }.max() ?? 0
        }
        return Stats(total: inside.count,
                     dailyAverage: perDay.isEmpty ? 0 : Double(inside.count) / Double(perDay.count),
                     cleanDays: perDay.filter { $0 == 0 }.count, measuredDays: perDay.count,
                     longest: longest, mostInADay: perDay.max() ?? 0)
    }

    /// One sentence comparing the period with the one before it.
    static func highlight(range: HealthRange, period: DateInterval, count: Int, previous: Int, now: Date,
                          calendar: Calendar = .current) -> String {
        let current = period.end > now
        let this: String, before: String
        switch range {
        case .day:
            let format = DateFormatter()
            format.calendar = calendar
            format.timeZone = calendar.timeZone
            format.locale = calendar.locale
            format.setLocalizedDateFormatFromTemplate("MMMd")
            this = current ? "today" : "on " + format.string(from: period.start)
            before = "the day before"
        case .week:
            this = "in these 7 days"
            before = "the 7 days before"
        case .month:
            let month = { (date: Date) in calendar.standaloneMonthSymbols[calendar.component(.month, from: date) - 1] }
            this = "in \(month(period.start))" + (current ? " so far" : "")
            before = "in " + month(period.start.addingTimeInterval(-1))
        case .halfYear:
            this = "in these 6 months"
            before = "the 6 months before"
        case .year:
            this = "in these 12 months"
            before = "the 12 months before"
        }
        let head = count == 0 ? "No relapses \(this)" : "\(count) relapse\(count == 1 ? "" : "s") \(this)"
        if count == previous { return count == 0 ? "\(head)." : "\(head), the same as \(before)." }
        return "\(head), \(abs(count - previous)) \(count < previous ? "fewer" : "more") than \(before)."
    }
}

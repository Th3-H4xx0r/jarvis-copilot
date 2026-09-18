import SwiftUI

/// Under a day-by-day history chart: a ring per day filled to its share of
/// the goal — closed in green with a check when met, amber where it fell
/// short, faint where nothing was recorded — with how many were met and
/// the current streak. A week is one row; a month is a calendar.
struct HealthGoalRings: View {
    let buckets: [HealthHistory.Bucket]
    let goal: HealthHistory.Goal
    let range: HealthRange
    /// "nights" for sleep, "days" for steps.
    let noun: String
    /// Today's key, marked under its ring.
    var today: String = RingDates.dayKey(Date())
    /// Today is still under way (steps), so its ring reads as in progress,
    /// not missed; last night's sleep is already done.
    var todayInProgress = false
    var revealed = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            summary
            if range == .week {
                HStack(spacing: 0) {
                    ForEach(buckets) { bucket in
                        VStack(spacing: 6) {
                            GoalDayRing(progress: bucket.goalProgress, inProgress: todayInProgress && bucket.start == today,
                                        size: 30, revealed: revealed)
                            Text(bucket.startDate.formatted(.dateTime.weekday(.narrow)))
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(bucket.start == today ? AnyShapeStyle(JcTheme.accent) : AnyShapeStyle(.secondary))
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            } else {
                calendar
            }
        }
    }

    private var summary: some View {
        HStack(spacing: 6) {
            Text("Goal met \(goal.met) of \(goal.measured) \(noun)")
                .font(.subheadline.weight(.semibold))
            if streak > 1 {
                Text("· \(streak)-\(noun.dropLast()) streak")
                    .font(.subheadline)
                    .foregroundStyle(JcTheme.success)
            }
            Spacer(minLength: 0)
            Text("Goal " + HealthFormat.string(goal.value, kind: goal.kind))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .monospacedDigit()
    }

    /// Met days in a row, back from the last one recorded.
    private var streak: Int {
        var count = 0
        for bucket in buckets.reversed() {
            guard let progress = bucket.goalProgress else { continue }
            if progress >= 1 { count += 1 } else if !(todayInProgress && bucket.start == today) { break }
        }
        return count
    }

    /// A month as a calendar: weekday columns, one small ring per day.
    private var calendar: some View {
        let cal = Calendar.current
        let offset = buckets.first.map { (cal.component(.weekday, from: $0.startDate) - cal.firstWeekday + 7) % 7 } ?? 0
        let symbols = cal.veryShortStandaloneWeekdaySymbols
        let ordered = Array(symbols[(cal.firstWeekday - 1)...] + symbols[..<(cal.firstWeekday - 1)])
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 10) {
            ForEach(Array(ordered.enumerated()), id: \.offset) { _, symbol in
                Text(symbol).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            }
            ForEach(0..<offset, id: \.self) { _ in Color.clear.frame(height: 22) }
            ForEach(buckets) { bucket in
                VStack(spacing: 3) {
                    GoalDayRing(progress: bucket.goalProgress, inProgress: todayInProgress && bucket.start == today,
                                size: 22, revealed: revealed)
                    Text(bucket.startDate.formatted(.dateTime.day()))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// One day's ring toward its goal.
struct GoalDayRing: View {
    let progress: Double?
    var inProgress = false
    var size: CGFloat = 30
    var revealed = true

    private var met: Bool { (progress ?? 0) >= 1 }
    private var tint: Color { met ? JcTheme.success : (inProgress ? JcTheme.accent : JcTheme.amber) }
    private var line: CGFloat { max(3, size * 0.13) }

    var body: some View {
        ZStack {
            if let progress {
                Circle().stroke(tint.opacity(0.18), lineWidth: line)
                Circle()
                    .trim(from: 0, to: revealed ? min(1, max(0.02, progress)) : 0)
                    .stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if met {
                    Image(systemName: "checkmark")
                        .font(.system(size: size * 0.34, weight: .heavy))
                        .foregroundStyle(tint)
                        .opacity(revealed ? 1 : 0)
                }
            } else {
                Circle().stroke(Color.primary.opacity(0.14), style: StrokeStyle(lineWidth: 1.5, dash: [2, 3]))
            }
        }
        .frame(width: size, height: size)
        .geometryGroup()
        .accessibilityLabel(progress.map { $0 >= 1 ? "Goal met" : "\(Int(($0 * 100).rounded()))% of goal" } ?? "Not recorded")
    }
}

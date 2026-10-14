import Charts
import SwiftUI

/// A habit's relapses the way Apple Health shows a metric: D / W / M / 6M / Y
/// (the month first), a chart you can scrub, the goal, the month as a
/// calendar, the streak, and every relapse in the period.
struct HabitDetailView: View {
    let habitID: String
    @ObservedObject var store: HabitStore
    /// A fixed clock, for renders; nil is now.
    var now: Date?

    @State private var range: HealthRange
    /// Which period is on screen: the one holding this date.
    @State private var anchor: Date
    /// The bar (or calendar day) picked.
    @State private var selected: Int?
    @State private var editing = false
    @State private var loggingPast = false
    @State private var revealed = false
    @Environment(\.dismiss) private var dismiss

    init(habitID: String, store: HabitStore = .shared, now: Date? = nil, initialRange: HealthRange = .month) {
        self.habitID = habitID
        self.store = store
        self.now = now
        _range = State(initialValue: initialRange)
        _anchor = State(initialValue: now ?? Date())
    }

    private var clock: Date { now ?? Date() }
    private var calendar: Calendar { .current }
    private var habit: Habit? { store.habits.first { $0.id == habitID } }

    var body: some View {
        Group {
            if let habit { content(habit) } else { Color.clear }
        }
        .navigationTitle(habit?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                GlassIconButton(symbol: "pencil", size: 34, iconSize: 15) { editing = true }
                    .accessibilityLabel("Edit habit")
            }
        }
        .sheet(isPresented: $editing) {
            if let habit { HabitEditor(habit: habit, store: store) }
        }
        .sheet(isPresented: $loggingPast) {
            if let habit { HabitPastRelapse(habit: habit, store: store) }
        }
        // Deleted here or by chat: nothing left to show.
        .onChange(of: habit == nil) { _, gone in if gone { dismiss() } }
        .onChange(of: range) {
            selected = nil
            anchor = clock
        }
        .onAppear { store.want("habit-detail") }
        .onDisappear { store.drop("habit-detail") }
        .sensoryFeedback(.selection, trigger: selected)
    }

    // MARK: Page

    private func content(_ habit: Habit) -> some View {
        let relapses = store.relapses(of: habit.id)
        let period = HabitMath.period(range, containing: anchor, calendar: calendar)
        let buckets = HabitMath.buckets(relapses, range: range, period: period, calendar: calendar)
        let start = HabitMath.start(habit, relapses)
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Picker("Range", selection: $range) {
                    ForEach(HealthRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)

                headline(buckets: buckets, period: period)
                    .padding(.horizontal, 24)
                    .onScrolledIntoView {
                        guard !revealed else { return }
                        withAnimation(.odometer) { revealed = true }
                    }

                CardGroup {
                    chart(habit, buckets: buckets, period: period)
                        .padding(14)
                    if range != .day {
                        RowDivider()
                        goalRow(habit, relapses: relapses, period: period, start: start)
                            .padding(16)
                    }
                }

                if range == .month {
                    monthCalendar(habit, buckets: buckets, start: start)
                }

                streakCard(habit, relapses: relapses)

                CardGroup("Highlights") {
                    Row {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "sparkles")
                                .foregroundStyle(JcTheme.accent)
                                .padding(.top, 2)
                            Text(HabitMath.highlight(range: range, period: period,
                                                     count: HabitMath.count(relapses, in: period),
                                                     previous: HabitMath.count(relapses, in: HabitMath.previous(range, before: period, calendar: calendar)),
                                                     now: clock, calendar: calendar))
                                .font(.subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 4)
                    }
                }

                stats(HabitMath.stats(relapses, habit: habit, period: period, now: clock, calendar: calendar))

                relapseList(habit, relapses: relapses, period: period)
            }
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
    }

    // MARK: Headline

    private func headline(buckets: [HabitMath.Bucket], period: DateInterval) -> some View {
        let picked = selected.flatMap { id in buckets.first { $0.id == id } }
        let count = picked?.count ?? buckets.reduce(0) { $0 + $1.count }
        let value = "\(count)"
        let current = HabitMath.isCurrent(range, anchor: anchor, now: clock, calendar: calendar)
        return VStack(alignment: .leading, spacing: 2) {
            Text((picked.map(label) ?? "Relapses").uppercased())
                .font(.caption.weight(.semibold))
                .kerning(0.4)
                .foregroundStyle(picked == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(JcTheme.accent))
            Text(revealed ? value : value.odometerZero)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.2), value: value)
                .geometryGroup()
            HStack {
                Text(span(period))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                GlassIconButton(symbol: "chevron.left", size: 30, iconSize: 13) { move(-1) }
                    .accessibilityLabel("Earlier")
                GlassIconButton(symbol: "chevron.right", size: 30, iconSize: 13) { move(1) }
                    .accessibilityLabel("Later")
                    .opacity(current ? 0.3 : 1)
                    .disabled(current)
            }
        }
        .animation(nil, value: selected)
    }

    private func move(_ by: Int) {
        selected = nil
        anchor = HabitMath.step(range, from: anchor, by: by, now: clock, calendar: calendar)
    }

    /// What one bar covers.
    private func label(_ bucket: HabitMath.Bucket) -> String {
        switch range {
        case .day:
            return bucket.start.formatted(.dateTime.hour()) + " – " + bucket.end.formatted(.dateTime.hour())
        case .halfYear: return "Week of " + bucket.start.formatted(.dateTime.month(.abbreviated).day())
        case .year: return bucket.start.formatted(.dateTime.month(.wide).year())
        default: return bucket.start.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        }
    }

    private func span(_ period: DateInterval) -> String {
        let last = period.end.addingTimeInterval(-1)
        switch range {
        case .day: return period.start.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        case .month: return period.start.formatted(.dateTime.month(.wide).year())
        case .halfYear, .year:
            return period.start.formatted(.dateTime.month(.abbreviated).year()) + " – "
                + last.formatted(.dateTime.month(.abbreviated).year())
        case .week:
            let style = Date.FormatStyle.dateTime.month(.abbreviated).day()
            return period.start.formatted(style) + " – " + last.formatted(style)
        }
    }

    // MARK: Chart

    private func chart(_ habit: Habit, buckets: [HabitMath.Bucket], period: DateInterval) -> some View {
        let shown = buckets.filter { $0.start <= clock }
        let dailyLimit = habit.goal.limit.flatMap { $0.per == .day ? $0.count : nil }
        let top = max(3, shown.map(\.count).max() ?? 0, (range == .week || range == .month) ? (dailyLimit ?? 0) : 0)
        let step = max(1, Int((Double(top) / 3).rounded(.up)))
        let ticks = Array(stride(from: 0, through: top + step - 1, by: step))
        let unit = HabitMath.unit(range)
        let picked = selected.flatMap { id in buckets.first { $0.id == id } }
        return Chart {
            ForEach(shown) { bucket in
                BarMark(x: .value("When", bucket.start, unit: unit), y: .value("Relapses", bucket.count))
                    .foregroundStyle(tint(habit, bucket).gradient)
                    .cornerRadius(3)
                    .opacity(picked != nil && picked?.id != bucket.id ? 0.35 : 1)
            }
            if let dailyLimit, range == .week || range == .month {
                RuleMark(y: .value("Limit", dailyLimit))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .foregroundStyle(Color.orange.opacity(0.8))
                    .annotation(position: .top, alignment: .trailing, spacing: 2) {
                        Text("Limit \(dailyLimit)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.orange)
                    }
            }
            if let picked {
                RuleMark(x: .value("When", picked.start, unit: unit))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .chartXScale(domain: period.start...period.end)
        .chartYScale(domain: 0...(ticks.last ?? top))
        .chartYAxis {
            AxisMarks(position: .trailing, values: ticks) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                AxisValueLabel { Text("\(value.as(Int.self) ?? 0)") }
            }
        }
        .chartXAxis {
            AxisMarks(values: axisValues) { _ in
                if range != .week { AxisGridLine().foregroundStyle(Color.primary.opacity(0.06)) }
                AxisValueLabel(format: axisFormat, centered: range == .week || range == .year)
            }
        }
        .chartXSelection(value: Binding(get: { picked?.start }, set: { date in
            let id = date.flatMap { date in shown.first { date >= $0.start && date < $0.end }?.id }
            if id != selected { selected = id }
        }))
        .frame(height: 200)
    }

    /// Orange past the limit for its period; the accent otherwise.
    private func tint(_ habit: Habit, _ bucket: HabitMath.Bucket) -> Color {
        guard let limit = habit.goal.limit else { return JcTheme.accent }
        let over = (limit.per == .day && (range == .week || range == .month))
            || (limit.per == .month && range == .year)
        return over && bucket.count > limit.count ? Color.orange : JcTheme.accent
    }

    private var axisValues: AxisMarkValues {
        switch range {
        case .day: return .stride(by: .hour, count: 6)
        case .week: return .stride(by: .day)
        case .month: return .stride(by: .day, count: 7)
        case .halfYear, .year: return .stride(by: .month)
        }
    }

    private var axisFormat: Date.FormatStyle {
        switch range {
        case .day: return .dateTime.hour()
        case .week: return .dateTime.weekday(.narrow)
        case .month: return .dateTime.day()
        case .halfYear: return .dateTime.month(.abbreviated)
        case .year: return .dateTime.month(.narrow)
        }
    }

    // MARK: Goal

    @ViewBuilder
    private func goalRow(_ habit: Habit, relapses: [HabitRelapse], period: DateInterval, start: Date) -> some View {
        let days = HabitMath.buckets(relapses, range: .month, period: period, calendar: calendar)
        let statuses = days.map { HabitMath.status(day: $0.start, count: $0.count, habit: habit, start: start,
                                                   now: clock, calendar: calendar) }
        let counted = statuses.filter { $0 != .future && $0 != .beforeStart }
        let met = counted.filter(\.metGoal).count
        let daily = habit.goal.limit?.per == .day
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(counted.isEmpty ? "Not started yet" : "\(daily ? "Within limit" : "Clean") \(met) of \(counted.count) day\(counted.count == 1 ? "" : "s")")
                    .font(.headline)
                Spacer()
                if let limit = habit.goal.limit {
                    Text("Limit \(limit.count) a \(limit.per == .day ? "day" : "month")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if range == .week {
                HStack(spacing: 0) {
                    ForEach(Array(zip(days, statuses)), id: \.0.id) { day, status in
                        VStack(spacing: 6) {
                            HabitDayMark(status: status, today: calendar.isDate(day.start, inSameDayAs: clock))
                            Text(day.start.formatted(.dateTime.weekday(.narrow)))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(calendar.isDate(day.start, inSameDayAs: clock) ? JcTheme.accent : .secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            if let limit = habit.goal.limit, limit.per == .month, range == .month {
                let used = HabitMath.count(relapses, in: period)
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(used) of \(limit.count) relapses this month")
                        .font(.subheadline)
                        .foregroundStyle(used > limit.count ? Color.orange : .secondary)
                    ProgressView(value: Double(min(used, max(limit.count, 1))), total: Double(max(limit.count, 1)))
                        .tint(used > limit.count ? Color.orange : JcTheme.accent)
                }
            }
            if let limit = habit.goal.limit, limit.per == .month, range == .year {
                let months = HabitMath.buckets(relapses, range: .year, period: period, calendar: calendar)
                HStack(spacing: 0) {
                    ForEach(months) { month in
                        VStack(spacing: 6) {
                            HabitDayMark(status: month.start > clock ? .future
                                            : month.end <= start ? .beforeStart
                                            : month.count <= limit.count ? .clean : .over,
                                         today: month.start <= clock && clock < month.end)
                                .scaleEffect(0.8)
                            Text(month.start.formatted(.dateTime.month(.narrow)))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    // MARK: Calendar

    private func monthCalendar(_ habit: Habit, buckets: [HabitMath.Bucket], start: Date) -> some View {
        let cells = HabitMath.monthGrid(buckets: buckets, habit: habit, start: start, now: clock, calendar: calendar)
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        let weekdays = Array(symbols[first...] + symbols[..<first])
        return CardGroup {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    ForEach(Array(weekdays.enumerated()), id: \.offset) { _, symbol in
                        Text(symbol)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                    ForEach(cells) { cell in
                        HabitCalendarCell(cell: cell, selected: cell.bucket != nil && cell.bucket == selected,
                                          today: cell.day.map { calendar.isDate($0, inSameDayAs: clock) } ?? false) {
                            guard let bucket = cell.bucket, cell.status != .future else { return }
                            selected = selected == bucket ? nil : bucket
                        }
                    }
                }
            }
            .padding(14)
        }
    }

    // MARK: Streak, stats, relapses

    private func streakCard(_ habit: Habit, relapses: [HabitRelapse]) -> some View {
        CardGroup("Streak") {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let at = now ?? context.date
                let current = at.timeIntervalSince(HabitMath.since(habit, relapses))
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top) {
                        stat("Current", HabitMath.duration(current))
                        stat("Longest", HabitMath.duration(HabitMath.longestStreak(habit, relapses, now: at)))
                    }
                    if let days = habit.goal.streakDays {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Target")
                                    .font(.subheadline)
                                Spacer()
                                Text("\(min(days, Int(current / 86_400))) of \(days) days")
                                    .font(.subheadline.weight(.semibold))
                                    .monospacedDigit()
                            }
                            ProgressView(value: min(1, current / (Double(days) * 86_400)))
                                .tint(JcTheme.accent)
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stats(_ stats: HabitMath.Stats) -> some View {
        CardGroup("Stats") {
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading, spacing: 14) {
                stat("Total", "\(stats.total)")
                stat("Daily average", String(format: "%.1f", stats.dailyAverage))
                stat("Clean days", "\(stats.cleanDays) of \(stats.measuredDays)")
                stat("Longest streak", HabitMath.duration(stats.longest))
                stat("Most in a day", "\(stats.mostInADay)")
            }
            .padding(16)
        }
    }

    private func relapseList(_ habit: Habit, relapses: [HabitRelapse], period: DateInterval) -> some View {
        let inPeriod = relapses.filter { $0.at >= period.start && $0.at < period.end }.reversed().map { $0 }
        let shown = Array(inPeriod.prefix(60))
        return CardGroup("Relapses") {
            ForEach(Array(shown.enumerated()), id: \.element.uid) { index, relapse in
                if index > 0 { RowDivider() }
                Row {
                    HStack {
                        Text(relapse.at.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                        Spacer()
                        Text(relapse.at.formatted(.dateTime.hour().minute()))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .font(.subheadline)
                }
                .background(JcTheme.surface.opacity(0.001))
                .swipeToDelete { store.undo(relapse) }
            }
            if inPeriod.count > shown.count {
                RowDivider()
                Row {
                    Text("and \(inPeriod.count - shown.count) more")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if !shown.isEmpty { RowDivider() }
            Row {
                Button { loggingPast = true } label: {
                    Label("Log a past relapse", systemImage: "clock.arrow.circlepath")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(JcTheme.accent)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A day's (or month's) goal mark: a check when met, a cross when not, a
/// faint ring before the habit began or still to come.
struct HabitDayMark: View {
    let status: HabitMath.DayStatus
    var today = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(ring, lineWidth: 3)
            switch status {
            case .clean, .within:
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(JcTheme.success)
            case .over:
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.orange)
            case .beforeStart, .future:
                EmptyView()
            }
        }
        .frame(width: 28, height: 28)
    }

    private var ring: Color {
        switch status {
        case .clean, .within: return today ? JcTheme.accent : JcTheme.success.opacity(0.7)
        case .over: return Color.orange.opacity(0.8)
        case .beforeStart, .future: return Color.white.opacity(0.1)
        }
    }
}

/// One day of the month calendar.
struct HabitCalendarCell: View {
    let cell: HabitMath.GridCell
    let selected: Bool
    let today: Bool
    let tap: () -> Void

    var body: some View {
        if let day = cell.day {
            Button(action: tap) {
                VStack(spacing: 3) {
                    Text(day.formatted(.dateTime.day()))
                        .font(.subheadline.weight(today ? .bold : .semibold))
                        .monospacedDigit()
                        .foregroundStyle(faded ? JcTheme.muted.opacity(0.6) : JcTheme.text)
                    mark
                        .frame(height: 12)
                }
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? JcTheme.accent : (today ? JcTheme.accent.opacity(0.5) : .clear),
                                  lineWidth: selected ? 2 : 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibility(day))
        } else {
            Color.clear.frame(minHeight: 46)
        }
    }

    private var faded: Bool { cell.status == .future || cell.status == .beforeStart }

    @ViewBuilder private var mark: some View {
        switch cell.status {
        case .clean:
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(JcTheme.success)
        case .within:
            Text("\(cell.count)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(JcTheme.accent)
        case .over:
            Text("\(cell.count)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.orange)
        default:
            Color.clear
        }
    }

    private var fill: Color {
        switch cell.status {
        case .clean: return JcTheme.success.opacity(0.10)
        case .within: return JcTheme.accent.opacity(0.16)
        case .over: return Color.orange.opacity(min(0.45, 0.14 + 0.08 * Double(cell.count)))
        default: return Color.white.opacity(0.03)
        }
    }

    private func accessibility(_ day: Date) -> String {
        let date = day.formatted(.dateTime.month(.wide).day())
        switch cell.status {
        case .clean: return "\(date), clean"
        case .within, .over: return "\(date), \(cell.count) relapse\(cell.count == 1 ? "" : "s")"
        case .future: return "\(date), still to come"
        default: return "\(date), before you started"
        }
    }
}

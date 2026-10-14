import SwiftUI

/// The habits being quit, one card each: how long since the last relapse,
/// how the goal stands, and a button that logs a relapse when held for 3 s.
struct HabitsView: View {
    @ObservedObject var store: HabitStore
    /// A fixed clock, for renders; nil is now.
    var now: Date?

    @State private var editing: HabitEditorTarget?
    @State private var open: Habit?
    /// The relapse just logged, while its Undo is on screen.
    @State private var logged: HabitRelapse?
    @State private var undoTimer: Task<Void, Never>?

    init(store: HabitStore = .shared, now: Date? = nil) {
        self.store = store
        self.now = now
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if store.habits.isEmpty {
                    CardGroup {
                        CardEmptyBlock(symbol: "calendar.badge.checkmark",
                                       text: "Add a habit you're quitting with +. Whenever you relapse, hold its button for 3 seconds.")
                    }
                }
                ForEach(store.habits) { habit in
                    HabitCard(habit: habit, relapses: store.relapses(of: habit.id), now: now,
                              open: { open = habit },
                              log: { log(habit) })
                }
                if let error = store.error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 100)
        }
        .overlay(alignment: .bottom) { undoBar }
        .navigationTitle("Habits")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                GlassIconButton(symbol: "plus", size: 34, iconSize: 16) { editing = .new }
                    .accessibilityLabel("Add a habit")
            }
        }
        .sheet(item: $editing) { target in
            HabitEditor(habit: target.habit, store: store)
        }
        .navigationDestination(item: $open) { habit in
            HabitDetailView(habitID: habit.id, store: store, now: now)
        }
        .task { await store.refresh() }
        .onAppear { store.want("habits-list") }
        .onDisappear { store.drop("habits-list") }
    }

    private func log(_ habit: Habit) {
        logged = store.log(habit)
        undoTimer?.cancel()
        undoTimer = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { withAnimation(.snappy) { logged = nil } }
        }
    }

    @ViewBuilder private var undoBar: some View {
        if let relapse = logged {
            HStack(spacing: 14) {
                Text("Relapse logged")
                    .font(.subheadline.weight(.semibold))
                Button("Undo") {
                    store.undo(relapse)
                    undoTimer?.cancel()
                    withAnimation(.snappy) { logged = nil }
                }
                .font(.subheadline.weight(.bold))
                .foregroundStyle(JcTheme.accent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .jcLiquidGlass(in: Capsule())
            .padding(.bottom, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// Which habit the editor sheet is for.
enum HabitEditorTarget: Identifiable {
    case new
    case edit(Habit)

    var id: String {
        if case .edit(let habit) = self { return habit.id }
        return "new"
    }

    var habit: Habit? {
        if case .edit(let habit) = self { return habit }
        return nil
    }
}

/// One habit: its name, the time since the last relapse counting up, how the
/// goal stands, and the hold-to-log button.
struct HabitCard: View {
    let habit: Habit
    let relapses: [HabitRelapse]
    var now: Date?
    let open: () -> Void
    let log: () -> Void

    @State private var revealed = false

    var body: some View {
        let since = HabitMath.since(habit, relapses)
        HStack(alignment: .center, spacing: 12) {
            Button(action: open) {
                TimelineView(.periodic(from: .now, by: (now ?? Date()).timeIntervalSince(since) < 3600 ? 1 : 30)) { context in
                    let at = now ?? context.date
                    VStack(alignment: .leading, spacing: 4) {
                        Text(habit.name)
                            .font(.headline)
                            .foregroundStyle(JcTheme.text)
                            .lineLimit(1)
                        let counter = HabitMath.duration(at.timeIntervalSince(since))
                        Text(revealed ? counter : counter.odometerZero)
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(JcTheme.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .contentTransition(.numericText())
                            .geometryGroup()
                        secondary(at)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows the calendar and stats")
            HabitHoldButton(goalProgress: goalProgress, onComplete: log)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 18)
        .background(JcTheme.glassFill, in: RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous)
            .strokeBorder(JcTheme.glassBorder, lineWidth: 1))
        .padding(.horizontal, 20)
        .onScrolledIntoView {
            guard !revealed else { return }
            withAnimation(.odometer) { revealed = true }
        }
    }

    private var goalProgress: Double? {
        guard let days = habit.goal.streakDays, days > 0 else { return nil }
        return (now ?? Date()).timeIntervalSince(HabitMath.since(habit, relapses)) / (Double(days) * 86_400)
    }

    @ViewBuilder private func secondary(_ at: Date) -> some View {
        if let limit = HabitMath.limitLine(habit, relapses, now: at) {
            Text(limit.text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(limit.over ? Color.orange : JcTheme.muted)
        } else {
            let month = HabitMath.count(relapses, in: Calendar.current.dateInterval(of: .month, for: at)
                                        ?? DateInterval(start: at, duration: 0))
            Text("Best \(HabitMath.duration(HabitMath.longestStreak(habit, relapses, now: at)).components(separatedBy: " ").prefix(2).joined(separator: " ")) · \(month) this month")
                .font(.subheadline)
                .foregroundStyle(JcTheme.muted)
        }
    }
}

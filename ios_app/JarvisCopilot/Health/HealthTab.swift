import SwiftUI

/// Jarvis Health: the person's day from every linked wearable.
///
/// Today is the default view: from falling asleep last night to now, so the
/// night, what it charged and the waking day read as one stretch that does
/// not reset at midnight. Yesterday and the days before are calendar days.
/// Everything here comes from the shared integration on the server; wearable
/// screens keep only what belongs to the device.
struct HealthTab: View {
    @StateObject private var model: HealthTabModel
    /// Readings taken now, from the cards: the ring is the wearable that can.
    @ObservedObject private var measure: RingMeasureController
    @State private var selection: HealthSelection = .today
    @State private var showingSettings = false
    /// The metric whose history is open.
    @State private var historyMetric: HealthMetric?
    @State private var choosingWorkout = false
    private let workout = WearablesHub.shared.ring.workout

    init(model: HealthTabModel? = nil, ring: RingManager? = nil) {
        let ring = ring ?? WearablesHub.shared.ring
        _model = StateObject(wrappedValue: model ?? HealthTabModel(spots: { ring.store }))
        _measure = ObservedObject(wrappedValue: ring.measure)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // A workout under way comes first, above the days.
                    WorkoutInProgressCard(workout: workout)
                    VStack(alignment: .leading, spacing: 26) {
                        dayRow
                        if let window = model.window(for: selection) {
                            HealthDayHeader(window: window, isToday: selection == .today)
                                .padding(.horizontal, 24)
                                .transition(.opacity)
                        }
                    }
                    .padding(.bottom, 6)
                    .animation(.easeOut(duration: 0.2), value: selection)
                    BatteryCard(battery: model.battery(for: selection),
                                analysis: analysis,
                                lastRefreshed: model.loadedAt[selection.cacheKey],
                                isRefreshing: model.isRefreshing,
                                error: model.error,
                                onRefresh: { Task { await model.runNow(selection) } },
                                showAll: { historyMetric = .battery })
                    HealthWorkoutsCard(workouts: model.workouts[selection.cacheKey] ?? [],
                                       onStart: selection == .today ? { choosingWorkout = true } : nil,
                                       showAll: { historyMetric = .exercise })
                    RingStatsSections(store: model.cache, dayKey: selection.cacheKey,
                                      capabilities: RingCapabilities(),
                                      scores: scores,
                                      hourDomain: model.hourDomain(for: selection),
                                      sleepDebt: model.sleepDebt(for: selection),
                                      stepGoal: model.health.settings?.goals.steps ?? 10_000,
                                      showAll: { historyMetric = $0 },
                                      measure: { type in
                                          // A reading taken now belongs to today, not a day gone.
                                          selection == .today ? measure.card(type, from: .health) : nil
                                      })
                }
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
            .refreshable { await model.refresh(selection) }
            .task(id: selection) { await model.refresh(selection) }
            .jcScreen("Health")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    GlassIconButton(symbol: "figure.run", size: 34, iconSize: 16) {
                        // A workout under way reopens; otherwise pick one to start.
                        if workout.isActive { workout.showsLive = true } else { choosingWorkout = true }
                    }
                        .accessibilityLabel("Start a workout")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    GlassIconButton(symbol: "gearshape", size: 34, iconSize: 16) { showingSettings = true }
                        .accessibilityLabel("Health settings")
                }
            }
            .sheet(isPresented: $showingSettings) {
                HealthTabSettings(model: model)
                    .presentationDetents([.large])
            }
            .ringWearSheet(measure, on: .health)
            .sheet(isPresented: $choosingWorkout) {
                WorkoutPicker { sport in workout.start(sport) }
                    .presentationDetents([.large])
            }
            .navigationDestination(item: $historyMetric) { metric in
                HealthHistoryView(metric: metric, tab: model, selection: selection)
            }
            .onChange(of: measure.finished) {
                // The reading is in the ring's history now; put it on the card.
                model.mergeSpots(selection)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .jcWorkoutSaved)) { note in
            if let saved = note.object as? RingWorkout { model.noteSaved(saved) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .jcWorkoutsSynced)) { _ in
            Task { await model.refresh(selection) }
        }
        .onTabVisibilityChange(.health) { visible in
            if visible { Task { await model.refresh(selection) } }
        }
    }

    // MARK: Day row

    private var dayRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                pill("Today", for: .today)
                ForEach(1..<7, id: \.self) { offset in
                    pill(dayLabel(offset), for: .day(dayKey(offset)))
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private func pill(_ title: String, for choice: HealthSelection) -> some View {
        let selected = selection == choice
        return Button { selection = choice } label: {
            Text(title)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .monospacedDigit()
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(selected ? JcTheme.accent.opacity(0.28) : Color.white.opacity(0.07), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Days count back from Today's own date — the day last night ended on —
    /// so at 1 AM before bed, Yesterday is still the day before this one.
    private func dayDate(_ offset: Int) -> Date {
        let base = RingDates.date(forKey: model.todayDate) ?? Calendar.current.startOfDay(for: Date())
        return Calendar.current.date(byAdding: .day, value: -offset, to: base) ?? base
    }

    private func dayKey(_ offset: Int) -> String { RingDates.dayKey(dayDate(offset)) }

    private func dayLabel(_ offset: Int) -> String {
        offset == 1 ? "Yesterday" : dayDate(offset).formatted(.dateTime.weekday(.abbreviated).day())
    }

    // MARK: What the selection shows

    private var scores: HealthScores? {
        if case .day(let date) = selection { return model.health.scores(for: date) }
        return model.health.scores(for: model.todayDate)
    }

    private var analysis: String? { scores?.analysis }

}

/// The day at a glance, above the battery: how long you have been awake, a
/// big live number under its own label. The label sits above the number, so
/// no grey line runs into the section heading below.
struct HealthDayHeader: View {
    let window: HealthWindow
    let isToday: Bool
    /// Seen once: the digits have rolled up from zero.
    @State private var revealed = false

    var body: some View {
        TimelineView(.everyMinute) { context in
            let end = isToday ? max(window.end, context.date) : window.end
            stat(symbol: primarySymbol, label: primaryLabel, tint: JcTheme.accent,
                 minutes: max(0, Int(end.timeIntervalSince(primaryStart) / 60)), size: 40)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onScrolledIntoView {
                    guard !revealed else { return }
                    withAnimation(.odometer) { revealed = true }
                }
        }
    }

    /// Awake since the night ended; with no night recorded, the day since midnight.
    private var primaryStart: Date { window.noNight ? window.start : (window.wake ?? window.start) }
    private var primaryLabel: String { window.noNight ? "Since midnight" : "Awake" }
    private var primarySymbol: String { window.noNight ? "clock.fill" : "sun.max.fill" }

    private func stat(symbol: String, label: String, tint: Color, minutes: Int, size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label {
                Text(label)
            } icon: {
                Image(systemName: symbol).foregroundStyle(tint)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            Text(revealed ? Self.length(minutes) : Self.length(minutes).odometerZero)
                .font(.system(size: size, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.snappy, value: minutes)
                .geometryGroup()
        }
        .accessibilityElement(children: .combine)
    }

    static func length(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}

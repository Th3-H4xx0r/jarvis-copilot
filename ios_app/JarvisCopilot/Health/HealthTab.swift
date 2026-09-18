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

    init(model: HealthTabModel? = nil, ring: RingManager? = nil) {
        let ring = ring ?? WearablesHub.shared.ring
        _model = StateObject(wrappedValue: model ?? HealthTabModel(spots: { ring.store }))
        _measure = ObservedObject(wrappedValue: ring.measure)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 14) {
                        dayRow
                        if let window = model.window(for: selection) {
                            HealthDayHeader(window: window, isToday: selection == .today)
                                .padding(.horizontal, 24)
                                .transition(.opacity)
                        }
                    }
                    .animation(.easeOut(duration: 0.2), value: selection)
                    BatteryCard(battery: model.battery(for: selection),
                                analysis: analysis,
                                lastRefreshed: model.loadedAt[selection.cacheKey],
                                isRefreshing: model.isRefreshing,
                                error: model.error,
                                onRefresh: { Task { await model.runNow(selection) } })
                    RingStatsSections(store: model.cache, dayKey: selection.cacheKey,
                                      capabilities: RingCapabilities(),
                                      scores: scores,
                                      hourDomain: hourDomain,
                                      sleepDebt: model.sleepDebt(for: selection),
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
            .onChange(of: measure.finished) {
                // The reading is in the ring's history now; put it on the card.
                model.mergeSpots(selection)
            }
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

    /// The hours the charts span: from the bedtime hour, counted from that
    /// day's midnight, to the window's end — past 24 once it crosses midnight.
    private var hourDomain: ClosedRange<Double> {
        guard let window = model.window(for: selection) else { return 0...24 }
        let midnight = Calendar.current.startOfDay(for: window.start)
        let from = window.start.timeIntervalSince(midnight) / 3600
        let to = max(from + 1, window.end.timeIntervalSince(midnight) / 3600)
        return from.rounded(.down)...to.rounded(.up)
    }
}

/// What the selection covers, said big: how long the day has run and from when.
/// Today's length keeps counting while the tab is open.
struct HealthDayHeader: View {
    let window: HealthWindow
    let isToday: Bool

    var body: some View {
        TimelineView(.everyMinute) { context in
            let end = isToday ? max(window.end, context.date) : window.end
            let minutes = max(0, Int(end.timeIntervalSince(window.start) / 60))
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.length(minutes))
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(minutes)))
                    .animation(.snappy, value: minutes)
                Text(caption)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }

    /// "since 11:17 PM last night", or a finished day's span, bedtime to bedtime.
    private var caption: String {
        let time = { (date: Date) in date.formatted(date: .omitted, time: .shortened) }
        let day = { (date: Date) in date.formatted(.dateTime.weekday(.abbreviated)) }
        if isToday {
            if window.noNight { return "since midnight · no sleep recorded last night" }
            let lastNight = !Calendar.current.isDate(window.start, inSameDayAs: Date())
            return "since you fell asleep at \(time(window.start))\(lastNight ? " last night" : "")"
        }
        let from = window.noNight ? "\(day(window.start)) midnight" : "\(day(window.start)) \(time(window.start))"
        return "\(from) – \(day(window.end)) \(time(window.end))"
    }

    static func length(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}

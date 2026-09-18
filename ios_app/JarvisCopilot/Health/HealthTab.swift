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
                    VStack(alignment: .leading, spacing: 8) {
                        dayRow
                        if let windowCaption {
                            Text(windowCaption)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .padding(.horizontal, 24)
                                .transition(.opacity)
                        }
                    }
                    .animation(.easeOut(duration: 0.2), value: selection)
                    BatteryCard(battery: model.battery(for: selection),
                                window: selection == .today,
                                analysis: analysis,
                                lastRefreshed: model.loadedAt[selection.cacheKey],
                                isRefreshing: model.isRefreshing,
                                error: model.error,
                                onRefresh: { Task { await model.runNow(selection) } })
                    RingStatsSections(store: model.cache, dayKey: selection.cacheKey,
                                      capabilities: RingCapabilities(),
                                      scores: scores,
                                      hourDomain: hourDomain,
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
                    pill(dayLabel(offset), for: .day(RingDates.dayKey(RingDates.midnight(daysAgo: offset))))
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

    /// What "Today" covers, said once under the pills: since bedtime, or since
    /// midnight when the ring recorded no night.
    private var windowCaption: String? {
        guard selection == .today, let now = model.now else { return nil }
        let length = now.minutes >= 60 ? "\(now.minutes / 60)h \(now.minutes % 60)m" : "\(now.minutes)m"
        if now.noWake { return "Since midnight · no sleep recorded last night" }
        let bedtime = now.start.formatted(date: .omitted, time: .shortened)
        let evening = !Calendar.current.isDate(now.start, inSameDayAs: now.end)
        return "Since \(bedtime)\(evening ? " last night" : "") · \(length)"
    }

    private func dayLabel(_ offset: Int) -> String {
        switch offset {
        case 1: return "Yesterday"
        default: return RingDates.midnight(daysAgo: offset).formatted(.dateTime.weekday(.abbreviated).day())
        }
    }

    // MARK: What the selection shows

    private var scores: HealthScores? {
        if case .day(let date) = selection { return model.health.scores(for: date) }
        return model.health.scores(for: HealthTabModel.scoresDate(model.now))
    }

    private var analysis: String? { scores?.analysis }

    /// A calendar day spans 0–24. Today runs from the bedtime hour on its own
    /// day to now, which is past 24 once it has crossed midnight.
    private var hourDomain: ClosedRange<Double> {
        guard case .today = selection, let now = model.now else { return 0...24 }
        let midnight = Calendar.current.startOfDay(for: now.start)
        let from = now.start.timeIntervalSince(midnight) / 3600
        let to = max(from + 1, from + Double(now.minutes) / 60)
        return from.rounded(.down)...to.rounded(.up)
    }
}

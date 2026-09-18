import SwiftUI

/// Jarvis Health: the person's day from every linked wearable.
///
/// Since wake is the default view — the stretch that matters now, which does
/// not reset at midnight. Calendar days sit beside it. Everything here comes
/// from the shared integration on the server; wearable screens keep only what
/// belongs to the device.
struct HealthTab: View {
    @StateObject private var model: HealthTabModel
    @State private var selection: HealthSelection = .sinceWake
    @State private var showingSettings = false

    init(model: HealthTabModel? = nil) {
        _model = StateObject(wrappedValue: model ?? HealthTabModel())
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    dayRow
                    BatteryCard(battery: model.battery(for: selection),
                                analysis: analysis,
                                lastRefreshed: model.loadedAt[selection.cacheKey],
                                isRefreshing: model.isRefreshing,
                                error: model.error,
                                onRefresh: { Task { await model.runNow(selection) } })
                    RingStatsSections(store: model.cache, dayKey: selection.cacheKey,
                                      capabilities: RingCapabilities(),
                                      scores: scores,
                                      hourDomain: hourDomain)
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
        }
        .onTabVisibilityChange(.health) { visible in
            if visible { Task { await model.refresh(selection) } }
        }
    }

    // MARK: Day row

    private var dayRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                pill(sinceWakeLabel, for: .sinceWake)
                ForEach(0..<7, id: \.self) { offset in
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

    private var sinceWakeLabel: String {
        guard let now = model.now else { return "Since wake" }
        if now.noWake { return "Today so far" }
        let hours = now.minutes / 60, minutes = now.minutes % 60
        return hours > 0 ? "Since wake · \(hours)h \(minutes)m" : "Since wake · \(minutes)m"
    }

    private func dayLabel(_ offset: Int) -> String {
        switch offset {
        case 0: return "Today"
        case 1: return "Yesterday"
        default: return RingDates.midnight(daysAgo: offset).formatted(.dateTime.weekday(.abbreviated).day())
        }
    }

    // MARK: What the selection shows

    private var scores: HealthScores? {
        if case .day(let date) = selection { return model.health.scores(for: date) }
        return model.health.scores(for: RingDates.dayKey(Date()))
    }

    private var analysis: String? { scores?.analysis }

    /// A calendar day spans 0–24. The window runs from the wake hour on its own
    /// day to now, which is past 24 once it has crossed midnight.
    private var hourDomain: ClosedRange<Double> {
        guard case .sinceWake = selection, let now = model.now else { return 0...24 }
        let midnight = Calendar.current.startOfDay(for: now.start)
        let from = now.start.timeIntervalSince(midnight) / 3600
        let to = max(from + 1, from + Double(now.minutes) / 60)
        return from.rounded(.down)...to.rounded(.up)
    }
}

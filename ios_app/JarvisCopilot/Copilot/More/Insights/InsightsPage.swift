import SwiftUI

/// The "Insights" screen — full parity with the web "Usage Analytics" panel,
/// ported from `pages/more/insights_page.dart`.
///
/// Top→bottom: the quota card, a period selector, host system health, LLM Wiki
/// status, headline stats, the daily-token chart, when-you-work activity, the
/// per-message breakdown for the active conversation, a token breakdown and a
/// per-model table. Every section renders only when its own data arrived — the
/// four sub-fetches behind `InsightsStore` degrade independently, so a dead
/// health endpoint hides one card instead of the screen.
///
/// A Usage | Costs control sits on top: Usage is everything above, Costs is
/// `CostsView` (what each service costs). The period selector drives both.
struct InsightsPage: View {
    @State private var store: InsightsStore
    @State private var costs: CostsStore
    /// Usage | Costs, remembered between visits.
    @AppStorage(InsightsTab.storageKey) private var tabRaw = InsightsTab.usage.rawValue

    /// See `SettingsPage.init` — a view's `init` isn't main-actor-isolated, so
    /// the store can't be a default argument.
    init(store: InsightsStore? = nil, costs: CostsStore? = nil) {
        _store = State(initialValue: store ?? MainActor.assumeIsolated { InsightsStore() })
        _costs = State(initialValue: costs ?? MainActor.assumeIsolated { CostsStore() })
    }

    private var tab: InsightsTab { InsightsTab(rawValue: tabRaw) ?? .usage }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                InsightsSegmentedPill(options: InsightsTab.allCases.map { ($0, $0.label) },
                                      selection: tab) { tabRaw = $0.rawValue }
                    .padding(.bottom, 16)
                if tab == .usage {
                    QuotaCard().padding(.bottom, 22)
                }
                InsightsPeriodSelector(days: store.days) { setDays($0) }
                    .padding(.bottom, 16)
                switch tab {
                case .usage: content
                case .costs: CostsView(store: costs)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .refreshable {
            switch tab {
            case .usage: await store.refresh()
            case .costs: await costs.refresh()
            }
        }
        .loadErrorBanner(tab == .usage ? store.errorMessage : costs.errorMessage,
                         hasContent: tab == .usage ? !store.overview.isEmpty : costs.hasContent)
        .jcScreen("Insights")
        .task(id: tab) { loadIfNeeded(tab) }
    }

    /// One period drives both tabs. The hidden tab's store only refetches if
    /// it has loaded before.
    private func setDays(_ days: Int) {
        store.setDays(days)
        costs.setDays(days)
    }

    private func loadIfNeeded(_ tab: InsightsTab) {
        switch tab {
        case .usage: if !store.hasLoaded && !store.isLoading { store.load() }
        case .costs: if !costs.hasLoaded && !costs.isLoading { costs.load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !store.hasLoaded && store.isLoading {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
        } else if let message = store.errorMessage, store.overview.isEmpty {
            CenteredMessage(text: message, color: JcTheme.danger) { store.load() }
                .padding(.top, 60)
        } else if store.isEmpty {
            CenteredMessage(text: "No usage data yet.").padding(.top, 60)
        } else {
            sections
        }
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 20) {
            // A health fetch that FAILED is reported, not hidden: an
            // unreachable host used to look exactly like one with no metrics.
            if store.health.failed {
                section("System health") {
                    StatusPill("UNAVAILABLE", color: JcTheme.danger, dense: true)
                } body: {
                    CenteredMessage(text: "Couldn't reach the host's health endpoint.")
                }
            } else if InsightsUI.healthIsAvailable(store.health) {
                let badge = InsightsUI.healthBadge(store.health)
                section("System health") {
                    StatusPill(badge.label, color: Color(tone: badge.tone), live: true, dense: true)
                } body: {
                    InsightsHealthCard(health: store.health)
                }
            }

            section("LLM Wiki") { InsightsWikiCard(wiki: store.wiki) }
            section("Overview") { InsightsStatGrid(overview: store.overview) }
            section("Daily tokens") {
                InsightsDailyTokensCard(bars: InsightsUI.dailyBars(store.overview.dailyTokens))
            }

            let hours = InsightsUI.hourBars(store.overview.activityByHour)
            let days = InsightsUI.dayBars(store.overview.activityByDay)
            if !hours.isEmpty || !days.isEmpty {
                section("Activity") { InsightsActivityCard(hours: hours, days: days) }
            }

            if store.showsMessages {
                section("Messages (this conversation)") {
                    InsightsMessagesCard(messages: store.messages)
                }
            }

            section("Token breakdown") { InsightsTokenBreakdownCard(overview: store.overview) }
            section("By model") { InsightsModelsCard(models: store.overview.models) }

            Text("Local WebUI session data · last \(store.days) days")
                .font(.system(size: 10.5))
                .foregroundStyle(JcTheme.muted.opacity(0.6))
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
        }
    }

    /// A titled block: the uppercase header (with an optional trailing chip) and
    /// its card. Two flavours so the common case stays a one-liner.
    private func section<Body: View>(_ title: String,
                                     @ViewBuilder body: () -> Body) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title)
            body()
        }
    }

    private func section<Trailing: View, Body: View>(
        _ title: String,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder body: () -> Body
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title, trailing: trailing)
            body()
        }
    }
}

/// The Insights screen's two tabs.
enum InsightsTab: String, CaseIterable, Hashable {
    case usage, costs

    static let storageKey = "insights.tab"

    var label: String {
        switch self {
        case .usage: return "Usage"
        case .costs: return "Costs"
        }
    }
}

/// The 7d / 30d / 90d / 1y segmented control, wrapped in a glass pill so it
/// reads as one control. Options come from `Insights.periodOptions`, which is
/// what the store clamps against.
struct InsightsPeriodSelector: View {
    let days: Int
    let onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Insights.periodOptions, id: \.days) { option in
                let selected = option.days == days
                Button { onChange(option.days) } label: {
                    Text(option.label)
                        .font(.system(size: 13.5, weight: .semibold))
                        .kerning(0.3)
                        .foregroundStyle(selected ? JcTheme.text : JcTheme.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background {
                            if selected { Capsule().fill(.white.opacity(0.10)) }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(4)
        .background(JcTheme.glassFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(JcTheme.glassBorder, lineWidth: 1))
        .animation(.easeInOut(duration: 0.16), value: days)
    }
}



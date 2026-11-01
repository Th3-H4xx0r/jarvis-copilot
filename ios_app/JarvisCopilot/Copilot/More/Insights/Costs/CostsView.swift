import SwiftUI

/// Insights → Costs: what every service Jarvis uses is costing.
///
/// Top→bottom: the period total (with month-to-date, the month's projection
/// and the change on the previous period), the budget bar, daily spend stacked
/// by service, the services in use, the ones that could be connected, and
/// "Add a subscription". Every amount comes from the one overview payload, so
/// the headline, the chart's legend and the rows add up to the same total.
struct CostsView: View {
    let store: CostsStore

    @State private var openService: CostSheetTarget?
    @State private var editingBudget = false
    @State private var addingSubscription = false

    var body: some View {
        content
            .sheet(item: $openService) { target in
                CostServiceSheet(model: CostServiceModel(serviceID: target.id, store: store))
            }
            .sheet(isPresented: $editingBudget) {
                CostBudgetSheet(store: store, current: store.overview.budget.monthlyUSD)
            }
            .sheet(isPresented: $addingSubscription) {
                CostAddSubscriptionSheet(store: store)
            }
    }

    @ViewBuilder
    private var content: some View {
        if !store.hasLoaded && store.isLoading {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
        } else if let message = store.errorMessage, !store.hasContent {
            CenteredMessage(text: message, color: JcTheme.danger) { store.load() }
                .padding(.top, 60)
        } else if store.isEmpty {
            CenteredMessage(text: "No cost data yet.").padding(.top, 60)
        } else {
            sections
        }
    }

    private var overview: CostsOverview { store.overview }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                CostsHeadlineCard(totals: overview.totals, days: overview.days, delta: store.delta)
                if let budget = store.budgetState {
                    CostsBudgetCard(state: budget) { editingBudget = true }
                } else {
                    Button { editingBudget = true } label: {
                        HStack(spacing: 8) {
                            JcIcon("gauge.with.needle", size: 14)
                            Text("Set monthly budget")
                        }
                    }
                    .buttonStyle(.jcGlass(compact: true))
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                SectionHeader("Daily spend")
                CostsDailyChartCard(stack: store.stack, periodTotal: overview.totals.period)
            }

            if !overview.services.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader("Services") {
                        Text(CostsUI.money(overview.totals.period, estimated: CostsUI.periodIsEstimate(overview.totals)))
                            .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(JcTheme.muted)
                    }
                    GlassCard(padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(Array(overview.services.enumerated()), id: \.element.id) { index, service in
                                if index > 0 { rowDivider }
                                Button { openService = CostSheetTarget(id: service.id) } label: {
                                    CostServiceRow(service: service, color: CostsPalette.color(store.slot(for: service.id)))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }

            if !overview.available.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader("Available to connect")
                    GlassCard(padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(Array(overview.available.enumerated()), id: \.element.id) { index, service in
                                if index > 0 { rowDivider }
                                Button { openService = CostSheetTarget(id: service.id) } label: {
                                    CostAvailableRow(service: service)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }

            Button { addingSubscription = true } label: {
                HStack(spacing: 8) {
                    JcIcon("plus", size: 14, weight: .bold)
                    Text("Add a subscription")
                }
            }
            .buttonStyle(.jcGlass(full: true))

            Text(footer)
                .font(.system(size: 10.5))
                .foregroundStyle(JcTheme.muted.opacity(0.6))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
        }
    }

    private var rowDivider: some View {
        Rectangle().fill(JcTheme.glassBorder).frame(height: 1).padding(.leading, 36)
    }

    private var footer: String {
        var parts = [CostsUI.periodLabel(start: overview.start, end: overview.end)].filter { !$0.isEmpty }
        if store.isSyncing {
            parts.append("syncing…")
        } else if let run = overview.lastRun {
            parts.append("synced \(RelativeTime.format(run))")
        }
        parts.append("≈ means Jarvis's own count × list price")
        return parts.joined(separator: " · ")
    }
}

/// `.sheet(item:)` needs an Identifiable; a service id is enough, and the
/// sheet reads the live card from the store so it never shows a stale copy.
struct CostSheetTarget: Identifiable, Hashable {
    let id: String
}

// MARK: - Headline

/// The period total, big at the top left; month-to-date, the projection and
/// the previous period smaller beneath.
struct CostsHeadlineCard: View {
    let totals: CostsTotals
    let days: Int
    let delta: Double?

    var body: some View {
        GlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SPENT · LAST \(days) DAYS")
                        .font(.system(size: 10.5, weight: .semibold))
                        .kerning(0.6)
                        .foregroundStyle(JcTheme.muted)
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(CostsUI.money(totals.period, estimated: CostsUI.periodIsEstimate(totals)))
                            .font(.system(size: 36, weight: .bold).monospacedDigit())
                            .kerning(-0.6)
                            .foregroundStyle(JcTheme.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        if let delta {
                            let tint = Color(tone: CostsUI.deltaTone(delta))
                            Text(CostsUI.deltaText(delta))
                                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                                .foregroundStyle(tint)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(tint.opacity(0.14), in: Capsule())
                                .accessibilityLabel("\(CostsUI.deltaText(delta)) on the previous \(days) days")
                        }
                        Spacer(minLength: 0)
                    }
                    let split = CostsUI.sourceSplit(totals)
                    if !split.isEmpty {
                        Text(split.map { "\(CostsUI.money($0.amount, estimated: $0.estimated)) \($0.label.lowercased())" }
                            .joined(separator: " · "))
                            .font(.system(size: 12))
                            .foregroundStyle(JcTheme.muted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                Rectangle().fill(JcTheme.glassBorder).frame(height: 1)
                HStack(alignment: .top, spacing: 12) {
                    CostMiniStat(label: "Month to date", value: CostsUI.money(totals.monthToDate))
                    CostMiniStat(label: "Projected month", value: CostsUI.money(totals.projectedMonth))
                    CostMiniStat(label: "Previous \(days)d",
                                 value: totals.previousPeriod.map { CostsUI.money($0) } ?? "—")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Budget

/// Month-to-date against the monthly budget, with a tick where the month is
/// projected to land.
struct CostsBudgetCard: View {
    let state: CostsBudgetState
    let onEdit: () -> Void

    var body: some View {
        let tint = Color(tone: state.tone)
        GlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(CostsUI.money(state.spent))
                        .font(.system(size: 20, weight: .bold).monospacedDigit())
                        .foregroundStyle(JcTheme.text)
                    Text("of \(CostsUI.money(state.budget)) this month")
                        .font(.system(size: 12.5))
                        .foregroundStyle(JcTheme.muted)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button("Edit", action: onEdit)
                        .buttonStyle(.jcGlass(compact: true))
                }
                bar(tint: tint)
                HStack(spacing: 6) {
                    Text("\(Int(state.percentUsed.rounded()))% used")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(tint)
                    Text("·").foregroundStyle(JcTheme.muted)
                    Text(CostsUI.budgetProjection(state))
                        .font(.system(size: 12))
                        .foregroundStyle(state.projectedOver ? JcTheme.amber : JcTheme.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func bar(tint: Color) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(JcTheme.glassFill)
                Capsule().fill(tint)
                    .frame(width: max(state.spent > 0 ? 6 : 0, width * min(state.fraction, 1)))
                // Where the month is heading.
                Rectangle()
                    .fill(JcTheme.text.opacity(0.85))
                    .frame(width: 2, height: 14)
                    .offset(x: min(width * min(state.projectedFraction, 1), width - 2))
            }
        }
        .frame(height: 10)
        .accessibilityElement()
        .accessibilityLabel("\(Int(state.percentUsed.rounded())) percent of the monthly budget used")
    }
}

// MARK: - Rows

/// A service in use: colour dot (its chart colour), name, what it counted, a
/// sparkline, the period amount and its status.
struct CostServiceRow: View {
    let service: CostService
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(color).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 4) {
                Text(service.name)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(JcTheme.text)
                    .lineLimit(1)
                Text(CostsUI.serviceSubtitle(service))
                    .font(.system(size: 12))
                    .foregroundStyle(JcTheme.muted)
                    .lineLimit(1)
                if let balance = CostsUI.balanceText(service) {
                    CostChip(text: balance, tint: JcTheme.accent)
                }
            }
            Spacer(minLength: 6)
            CostSparkline(values: service.spark, color: color)
                .frame(width: 48, height: 22)
            VStack(alignment: .trailing, spacing: 5) {
                if service.status == .needsPrice {
                    Text("Set price")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(JcTheme.amber)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .jcLiquidGlass(in: Capsule())
                } else {
                    Text(CostsUI.money(service.periodTotal, estimated: service.isEstimate))
                        .font(.system(size: 14.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(JcTheme.text)
                        .lineLimit(1)
                }
                let badge = CostsUI.statusBadge(service.status)
                StatusPill(badge.label, color: Color(tone: badge.tone), dense: true)
            }
            .frame(minWidth: 78, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

/// A service Jarvis isn't using yet that the page can track once connected.
struct CostAvailableRow: View {
    let service: CostService

    private var action: String {
        if !service.fields.isEmpty { return "Connect" }
        if service.kind == .subscription { return "Add price" }
        return "Details"
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle().strokeBorder(JcTheme.muted.opacity(0.6), lineWidth: 1.5).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 3) {
                Text(service.name)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(JcTheme.text)
                    .lineLimit(1)
                Text(service.category)
                    .font(.system(size: 12))
                    .foregroundStyle(JcTheme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(action)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(JcTheme.accent)
            JcIcon("chevron.right", size: 11, weight: .semibold)
                .foregroundStyle(JcTheme.muted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

// MARK: - Budget sheet

struct CostBudgetSheet: View {
    let store: CostsStore
    let current: Double?

    @Environment(\.dismiss) private var dismiss
    @State private var amount = ""
    @State private var error: String?
    @State private var clearing = false

    var body: some View {
        FormSheet(title: "Monthly budget", onSave: save) {
            VStack(alignment: .leading, spacing: 10) {
                FormFieldLabel("Budget per month")
                CostAmountField(placeholder: "150", text: $amount)
                Text("The bar compares this month's spend (and where it's heading) against this.")
                    .font(JcText.small)
                    .foregroundStyle(JcTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                CostFormNote(error: error, note: nil)
                if current != nil {
                    Button(role: .destructive) {
                        Task { await clear() }
                    } label: {
                        if clearing { ProgressView().controlSize(.small) } else { Text("Remove budget") }
                    }
                    .buttonStyle(.jcGlass(tint: JcTheme.danger, compact: true))
                    .disabled(clearing)
                    .padding(.top, 6)
                }
            }
        }
        .onAppear { if amount.isEmpty, let current { amount = CostsUI.amountText(current) } }
    }

    private func save() async -> Bool {
        guard let value = CostsUI.parseAmount(amount), value > 0 else {
            error = "Enter the budget as a number, like 150."
            return false
        }
        do {
            try await store.setBudget(value)
            return true
        } catch {
            self.error = apiErrorMessage(error)
            return false
        }
    }

    private func clear() async {
        clearing = true
        defer { clearing = false }
        do {
            try await store.setBudget(nil)
            dismiss()
        } catch {
            self.error = apiErrorMessage(error)
        }
    }
}

// MARK: - Add a subscription

struct CostAddSubscriptionSheet: View {
    let store: CostsStore

    @State private var name = ""
    @State private var amount = ""
    @State private var interval = "month"
    @State private var error: String?

    var body: some View {
        FormSheet(title: "Add a subscription", saveLabel: "Add", onSave: save) {
            FormTextField(label: "Name", text: $name, hint: "Hetzner VPS, a domain…")
            VStack(alignment: .leading, spacing: 10) {
                FormFieldLabel("Price")
                CostAmountField(placeholder: "12.50", text: $amount)
                InsightsSegmentedPill(options: [("month", "Monthly"), ("year", "Yearly")],
                                      selection: interval, compact: true) { interval = $0 }
                Text("Spread over the days it covers, so it shows up in daily spend.")
                    .font(JcText.small)
                    .foregroundStyle(JcTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                CostFormNote(error: error, note: nil)
            }
        }
    }

    private func save() async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { error = "Give the subscription a name."; return false }
        guard let value = CostsUI.parseAmount(amount) else {
            error = "Enter the price as a number, like 20 or 9.99."
            return false
        }
        do {
            try await store.addSubscription(name: trimmed, amount: value, interval: interval)
            return true
        } catch {
            self.error = apiErrorMessage(error)
            return false
        }
    }
}

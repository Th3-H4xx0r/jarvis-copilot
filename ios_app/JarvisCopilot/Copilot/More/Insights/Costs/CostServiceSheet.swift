import SwiftUI

/// One service's sheet: its name as the title over a scrolling
/// `CostServiceDetailView`.
struct CostServiceSheet: View {
    @State var model: CostServiceModel

    var body: some View {
        DetailSheet(title: model.service?.name ?? "Service") {
            CostServiceDetailView(model: model)
        }
    }
}

/// One service's detail: what it cost (period and month), its daily chart, the
/// models or bill lines behind it, its balance, and the forms that set it up —
/// the billing-API keys, the plan price — plus Disconnect.
struct CostServiceDetailView: View {
    let model: CostServiceModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var drafts: [String: String] = [:]
    @State private var amount = ""
    @State private var interval = "month"
    @State private var planName = ""
    @State private var seededPlan = false
    @State private var confirmingDisconnect = false
    @State private var confirmingRemove = false

    var body: some View {
        Group {
            if let service = model.service {
                VStack(alignment: .leading, spacing: 18) {
                    header(service)
                    if model.isLoading {
                        JcLoader().frame(maxWidth: .infinity).padding(.vertical, 30)
                    } else if let error = model.loadError, model.detail == nil {
                        CenteredMessage(text: error, color: JcTheme.danger) { Task { await model.load() } }
                    } else {
                        detailSections(service)
                    }
                    if service.kind == .subscription || service.custom { planEditor(service) }
                    if !service.fields.isEmpty { connectForm(service) }
                    about(service)
                    footer(service)
                }
                .padding(.bottom, 12)
            } else {
                CenteredMessage(text: model.loadError ?? "This service is gone")
            }
        }
        .task { if model.detail == nil { await model.load() } }
        .onChange(of: model.service?.subscription) { old, new in
            // Cleared on the server: empty the editor too, or it keeps showing
            // (and offering to re-save) the price that was just removed.
            if new == nil, old != nil {
                amount = ""
                planName = ""
                interval = "month"
            } else {
                seedPlan(force: true)
            }
        }
        .onAppear { seedPlan(force: false) }
        .confirmationDialog("Disconnect billing for \(model.service?.name ?? "")?",
                            isPresented: $confirmingDisconnect, titleVisibility: .visible) {
            Button("Disconnect billing", role: .destructive) {
                Task { _ = await model.disconnect() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The billing key saved here is removed. History and plan price stay.")
        }
        .confirmationDialog("Remove \(model.service?.name ?? "this subscription")?",
                            isPresented: $confirmingRemove, titleVisibility: .visible) {
            // A custom subscription IS its price: clearing it removes the entry.
            Button("Remove subscription", role: .destructive) {
                Task { if await model.removeSubscription() { dismiss() } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It stops counting toward your spend.")
        }
    }

    // MARK: Header

    private func header(_ service: CostService) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                let badge = CostsUI.statusBadge(service.status)
                StatusPill(badge.label, color: Color(tone: badge.tone), dense: true)
                Text(service.category)
                    .font(.system(size: 12))
                    .foregroundStyle(JcTheme.muted)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(service.status == .needsPrice ? "No price yet"
                     : CostsUI.money(service.periodTotal, estimated: service.isEstimate))
                    .font(.system(size: 32, weight: .semibold).monospacedDigit())
                    .kerning(-0.5)
                    .foregroundStyle(service.status == .needsPrice ? JcTheme.amber : JcTheme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("last \(model.detail?.days ?? service.spark.count) days")
                    .font(.system(size: 12))
                    .foregroundStyle(JcTheme.muted)
            }
            HStack(alignment: .top, spacing: 12) {
                CostMiniStat(label: "This month",
                             value: CostsUI.money(service.monthToDate, estimated: service.isEstimate))
                if let sub = service.subscription {
                    CostMiniStat(label: sub.plan ?? "Plan", value: CostsUI.planPrice(sub.amountUSD, interval: sub.interval))
                }
                let units = CostsUI.unitsSummary(service.units, limit: 1)
                if !units.isEmpty {
                    CostMiniStat(label: "Usage", value: units)
                }
            }
            if let line = CostsUI.apiEquivalentLine(service) {
                Text(line)
                    .font(.system(size: 12.5))
                    .foregroundStyle(JcTheme.text.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let used = service.planUsageUSD {
                Text("Plan usage reported by the provider: \(CostsUI.money(used))")
                    .font(.system(size: 12.5))
                    .foregroundStyle(JcTheme.muted)
            }
            if let balance = CostsUI.balanceText(service) {
                HStack(spacing: 6) {
                    CostChip(text: balance, tint: JcTheme.accent)
                    if let at = service.balanceAt {
                        Text(RelativeTime.format(at)).font(.system(size: 11)).foregroundStyle(JcTheme.muted)
                    }
                }
            }
            if let error = service.error {
                HStack(alignment: .top, spacing: 8) {
                    JcIcon("exclamationmark.triangle.fill", size: 12).foregroundStyle(JcTheme.danger)
                    Text(error)
                        .font(JcText.small)
                        .foregroundStyle(JcTheme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(JcTheme.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    // MARK: Detail

    @ViewBuilder
    private func detailSections(_ service: CostService) -> some View {
        let bars = model.bars
        if service.kind != .free, bars.contains(where: { $0.effective > 0 || $0.estimate != nil }) {
            block(bars.contains { $0.day != $0.lastDay } ? "Weekly" : "Daily") {
                GlassCard(padding: 14) {
                    CostDetailChart(bars: bars, color: CostsPalette.color(model.slot ?? 0),
                                    compare: CostsUI.showsBillingVsEstimate(bars, kind: service.kind))
                }
            }
        }
        if let detail = model.detail, !detail.models.isEmpty {
            block(service.kind == .subscription ? "Covered usage by model" : "By model") {
                GlassCard(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(detail.models.enumerated()), id: \.element.id) { index, row in
                            if index > 0 { divider }
                            modelRow(row, estimated: service.kind == .usage)
                        }
                    }
                }
            }
        }
        if let detail = model.detail, !detail.billingItems.isEmpty {
            block("On the bill") {
                GlassCard(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(detail.billingItems.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { divider }
                            HStack {
                                Text(item.item)
                                    .font(.system(size: 13.5))
                                    .foregroundStyle(JcTheme.text)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Text(CostsUI.money(item.costUSD))
                                    .font(.system(size: 13.5, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(JcTheme.text)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
                        }
                    }
                }
            }
        }
    }

    private func modelRow(_ row: CostModelRow, estimated: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.model)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(JcTheme.text)
                    .lineLimit(1)
                Text("\(CostsUI.count(row.calls, "call")) · \(Insights.formatTokensCompact(row.tokens)) tokens")
                    .font(.system(size: 11.5))
                    .foregroundStyle(JcTheme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if row.unpriced {
                StatusPill("Unpriced", color: JcTheme.muted, dense: true)
            } else {
                // A subscription's rows are what the calls WOULD have cost.
                Text(CostsUI.money(row.costUSD, estimated: true))
                    .font(.system(size: 13.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(estimated ? JcTheme.text : JcTheme.muted)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Plan price

    private func planEditor(_ service: CostService) -> some View {
        block(service.custom ? "Subscription" : "Plan price") {
            GlassCard(padding: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    if !service.suggestedPlans.isEmpty {
                        JcWrap(spacing: 8, runSpacing: 8) {
                            ForEach(service.suggestedPlans) { plan in
                                planChip(plan)
                            }
                        }
                    }
                    CostAmountField(placeholder: "20", text: $amount)
                    InsightsSegmentedPill(options: [("month", "Monthly"), ("year", "Yearly")],
                                          selection: interval, compact: true) { interval = $0 }
                    if !service.custom {
                        TextField("Plan name (optional)", text: $planName)
                            .autocorrectionDisabled()
                            .jcFieldStyle()
                    }
                    HStack(spacing: 10) {
                        Button {
                            guard let value = CostsUI.parseAmount(amount) else { return }
                            Task { _ = await model.savePlan(amount: value, interval: interval, plan: planName) }
                        } label: {
                            busyLabel("plan", "Save price")
                        }
                        .buttonStyle(.jcGlass(full: true))
                        .disabled(CostsUI.parseAmount(amount) == nil || model.busy != nil)
                        if service.custom {
                            Button {
                                confirmingRemove = true
                            } label: {
                                busyLabel("clear", "Remove")
                            }
                            .buttonStyle(.jcGlass(tint: JcTheme.danger))
                            .disabled(model.busy != nil)
                        } else if service.subscription != nil {
                            Button {
                                Task { _ = await model.clearPlan() }
                            } label: {
                                busyLabel("clear", "Clear")
                            }
                            .buttonStyle(.jcGlass(tint: JcTheme.danger))
                            .disabled(model.busy != nil)
                        }
                    }
                    if ["plan", "clear"].contains(lastAction) {
                        CostFormNote(error: model.actionError, note: model.actionNote)
                    }
                    Text(service.kind == .subscription && !service.custom
                         ? "What you pay. It's spread over the days it covers, so daily spend includes it."
                         : "Spread over the days it covers, so daily spend includes it.")
                        .font(JcText.small)
                        .foregroundStyle(JcTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func planChip(_ plan: CostPlan) -> some View {
        let selected = CostsUI.parseAmount(amount) == plan.amountUSD && interval == plan.interval
            && planName == plan.label
        return Button {
            amount = CostsUI.amountText(plan.amountUSD)
            interval = plan.interval
            planName = plan.label
        } label: {
            HStack(spacing: 5) {
                Text(plan.label).font(.system(size: 12.5, weight: .medium))
                Text(CostsUI.planPrice(plan.amountUSD, interval: plan.interval))
                    .font(.system(size: 12.5).monospacedDigit())
                    .foregroundStyle(selected ? JcTheme.text : JcTheme.muted)
            }
            .foregroundStyle(JcButton.label)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .jcButtonSurface(in: RoundedRectangle(cornerRadius: JcButton.compactRadius, style: .continuous), selected: selected)
        }
        .buttonStyle(.plain)
    }

    /// Fill the editor from the saved plan (once on open, and again whenever
    /// the server's copy changes after a save).
    private func seedPlan(force: Bool) {
        guard force || !seededPlan, let service = model.service else { return }
        seededPlan = true
        if let sub = service.subscription {
            amount = CostsUI.amountText(sub.amountUSD)
            interval = sub.interval
            planName = sub.plan ?? ""
        }
    }

    // MARK: Connect

    private func connectForm(_ service: CostService) -> some View {
        block("Billing API") {
            GlassCard(padding: 14) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(service.fields) { field in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 8) {
                                FormFieldLabel(field.label)
                                if field.isSet { CostChip(text: "Saved", tint: JcTheme.success, symbol: "checkmark") }
                                Spacer(minLength: 0)
                            }
                            fieldInput(field)
                        }
                    }
                    Button {
                        let filled = drafts.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.value.isEmpty }
                        Task {
                            if await model.connect(filled) { drafts = [:] }
                        }
                    } label: {
                        busyLabel("connect", service.fields.contains(where: \.isSet) ? "Save & sync" : "Connect")
                    }
                    .buttonStyle(.jcGlass(full: true))
                    .disabled(!hasDrafts || model.busy != nil)
                    if lastAction == "connect" {
                        CostFormNote(error: model.actionError, note: model.actionNote)
                    }
                    Text("Keys are stored on your Jarvis server and never shown again.")
                        .font(JcText.small)
                        .foregroundStyle(JcTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func fieldInput(_ field: CostField) -> some View {
        let binding = Binding(get: { drafts[field.key] ?? "" }, set: { drafts[field.key] = $0 })
        let hint = field.isSet ? "Paste a new one to replace it" : (field.placeholder.isEmpty ? field.label : field.placeholder)
        Group {
            if field.isSecret {
                SecureField(hint, text: binding)
            } else {
                TextField(hint, text: binding)
            }
        }
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .jcFieldStyle()
    }

    private var hasDrafts: Bool {
        drafts.values.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    // MARK: About + footer

    @ViewBuilder
    private func about(_ service: CostService) -> some View {
        if !service.help.isEmpty || service.url != nil {
            block("About") {
                VStack(alignment: .leading, spacing: 12) {
                    if !service.help.isEmpty {
                        Text(service.help)
                            .font(.system(size: 13))
                            .foregroundStyle(JcTheme.text.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let url = service.url {
                        Button {
                            openURL(url)
                        } label: {
                            HStack(spacing: 6) {
                                Text("Open \(url.host() ?? "billing page")")
                                JcIcon("chevron.right", size: 10, weight: .semibold)
                            }
                        }
                        .buttonStyle(.jcGlass(compact: true))
                    }
                }
            }
        }
    }

    private func footer(_ service: CostService) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Only services with a billing API have a sync to talk about.
            if service.billingConnected || !service.fields.isEmpty || service.lastSynced != nil {
                HStack(spacing: 10) {
                    Text(service.lastSynced.map { "Billing synced \(RelativeTime.format($0))" }
                         ?? (service.billingConnected ? "Not synced yet" : "Billing API not connected"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(JcTheme.muted)
                    Spacer(minLength: 0)
                    if service.billingConnected {
                        Button {
                            Task { _ = await model.sync() }
                        } label: {
                            busyLabel("sync", "Sync now")
                        }
                        .buttonStyle(.jcGlass(compact: true))
                        .disabled(model.busy != nil)
                    }
                }
            }
            if ["sync", "disconnect"].contains(lastAction) {
                CostFormNote(error: model.actionError, note: model.actionNote)
            }
            if service.hasBillingKey {
                Button(role: .destructive) {
                    confirmingDisconnect = true
                } label: {
                    busyLabel("disconnect", "Disconnect billing")
                }
                .buttonStyle(.jcGlass(tint: JcTheme.danger, full: true))
                .disabled(model.busy != nil)
            }
        }
        .padding(.top, 4)
    }

    // MARK: Pieces

    /// Which form the outcome note belongs under.
    private var lastAction: String? { model.lastAction }

    @ViewBuilder
    private func busyLabel(_ action: String, _ title: String) -> some View {
        if model.busy == action {
            JcLoader(size: 16).foregroundStyle(JcTheme.accent)
        } else {
            Text(title)
        }
    }

    private func block<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title)
            content()
        }
    }

    private var divider: some View {
        Rectangle().fill(JcTheme.glassBorder).frame(height: 1)
    }
}

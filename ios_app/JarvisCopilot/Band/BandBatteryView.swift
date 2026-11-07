import Charts
import SwiftUI

/// The band's Battery page: the level now and how long it lasts, its curve, what it used each
/// day, where it went, the charges, and the settings that cost it most — all from
/// `BandBatteryLog`.
struct BandBatteryView: View {
    enum Span: String, CaseIterable, Identifiable {
        case day = "24 hours", week = "7 days", month = "30 days"
        var id: String { rawValue }
        var seconds: TimeInterval { self == .day ? 86_400 : self == .week ? 7 * 86_400 : 30 * 86_400 }
        var label: String { self == .day ? "last 24 hours" : self == .week ? "last 7 days" : "last 30 days" }
        var bars: Int { self == .month ? 30 : 7 }
    }

    /// What the page shows, worked out once per load rather than on each redraw.
    struct Figures {
        var report: BandBatteryReport
        var since: Date
        var uses: [BandBatteryReport.Use]
        var days: [BandBatteryReport.Day]
        var perDay: Double?
    }

    @ObservedObject var manager: BandManager
    @ObservedObject var log: BandBatteryLog
    @ObservedObject var session: BandSession
    @ObservedObject var scheduler: BandMeasureScheduler
    @State private var span: Span = .week
    @State private var figures: Figures?

    init(manager: BandManager) {
        self.manager = manager
        log = manager.battery
        session = manager.session
        scheduler = manager.measureScheduler
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if let figures, figures.report.samples.count >= 2 {
                    BandBatteryHeadline(report: figures.report, live: session.battery)
                    JcSegmented(items: Span.allCases, selection: $span, label: \.rawValue)
                    BandBatteryCurve(report: figures.report, domain: figures.since...figures.report.now)
                    BandBatteryDays(days: figures.days, average: figures.perDay)
                    uses(figures)
                    charging(figures.report)
                    activity(figures)
                } else {
                    BandBatteryHeadline(report: figures?.report, live: session.battery)
                    JcEmptyState(symbol: "battery.75percent", title: "Collecting",
                                 subtitle: "The level is read each time the band connects and every 10 minutes while it's linked. The curve and the drain fill in from there.")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 30)
                }
                settings
                Text("Measured from the level the band reports. Each drop between two readings off the "
                   + "charger is shared over what the band was doing then; what the phone can't see — "
                   + "its screen, its own notifications — falls under On its own.")
                    .font(JcText.small)
                    .foregroundStyle(JcTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 40)
        }
        .refreshable {
            if manager.isLinkReady { await session.refreshBattery() }
            load()
        }
        .onAppear(perform: load)
        .onChange(of: span) { _, _ in load() }
        // `$samples` fires before the new sample is in: read it on the next turn.
        .onReceive(log.$samples.dropFirst().receive(on: DispatchQueue.main)) { _ in load() }
        .jcPageChrome("Battery")
    }

    private func load() {
        let report = log.report()
        let since = report.now.addingTimeInterval(-span.seconds)
        figures = Figures(report: report, since: since, uses: report.uses(since: since),
                          days: report.days(span.bars), perDay: report.perDay(since: since))
    }

    // MARK: Where it went

    @ViewBuilder
    private func uses(_ f: Figures) -> some View {
        let total = f.uses.reduce(0) { $0 + $1.points }
        if total >= 1 {
            let top = f.uses.first?.points ?? 1
            VStack(alignment: .leading, spacing: 0) {
                GlassQuietLabel("What used the most")
                GlassGroup {
                    ForEach(Array(f.uses.enumerated()), id: \.element.id) { index, use in
                        BatteryRankRow(item: BatteryUsageSummary.Item(
                            id: use.id, title: BandBatteryReport.title(use.kind),
                            detail: Self.useDetail(use), symbol: BandBatteryReport.symbol(use.kind),
                            value: use.points, share: use.points / max(top, 0.01), ofTotal: use.points / total),
                                       value: String(format: "%.0f%%", use.points), tint: JcTheme.accent,
                                       last: index == f.uses.count - 1)
                    }
                }
                Text(Self.comparison(f.uses) ?? "Battery used, \(span.label), by what the band was doing.")
                    .font(JcText.small)
                    .foregroundStyle(JcTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                    .padding(.horizontal, 4)
            }
        }
    }

    static func useDetail(_ use: BandBatteryReport.Use) -> String {
        var parts = [BandBatteryReport.duration(use.seconds)]
        if let rate = use.perHour { parts.append(String(format: "%.1f%%/h", rate)) }
        return parts.joined(separator: " · ")
    }

    /// The costliest activity against the band on its own, when both have enough time.
    static func comparison(_ uses: [BandBatteryReport.Use]) -> String? {
        guard let alone = uses.first(where: { $0.kind == nil })?.perHour, alone > 0.05,
              let costly = uses.filter({ $0.kind != nil && $0.seconds >= 1800 })
                .max(by: { ($0.perHour ?? 0) < ($1.perHour ?? 0) }),
              let rate = costly.perHour, rate / alone >= 1.5 else { return nil }
        return "\(BandBatteryReport.title(costly.kind)) drain it \(String(format: "%.1f", rate / alone))× as fast as "
            + "the band on its own (\(String(format: "%.1f", rate))%/h against \(String(format: "%.1f", alone))%/h)."
    }

    // MARK: Charging

    @ViewBuilder
    private func charging(_ report: BandBatteryReport) -> some View {
        let done = report.charges.filter { !$0.ongoing }
        if let last = report.lastCharge {
            VStack(alignment: .leading, spacing: 0) {
                GlassQuietLabel("Charging")
                GlassGroup {
                    BatteryStatRow(symbol: "bolt.fill", title: "Last charged",
                                   value: last.end.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))
                    BatteryStatRow(symbol: "battery.100percent.bolt", title: "Charged to",
                                   value: "\(last.to)%, from \(last.from)%")
                    BatteryStatRow(symbol: "timer", title: "Took",
                                   value: last.observed && last.duration >= 60
                                       ? BandBatteryReport.duration(last.duration) : "away from the phone")
                    if let latest = report.latest, !latest.charging {
                        BatteryStatRow(symbol: "clock.arrow.circlepath", title: "Off the charger",
                                       value: "\(BandBatteryReport.duration(report.now.timeIntervalSince(last.end))) · used \(max(0, last.to - latest.percent))%")
                    }
                    BatteryStatRow(symbol: "calendar", title: "Charges, last 30 days", value: "\(done.count)")
                    BatteryStatRow(symbol: "repeat", title: "Charged about every",
                                   value: report.daysBetweenCharges.map { String(format: "%.1f days", $0) } ?? "after the next charge",
                                   last: true)
                }
                if done.count > 1 {
                    GlassQuietLabel("Recent charges").padding(.top, 26)
                    GlassGroup {
                        let recent = Array(done.suffix(6).reversed())
                        ForEach(Array(recent.enumerated()), id: \.offset) { index, charge in
                            GlassRow(symbol: "bolt.fill",
                                     title: charge.end.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()),
                                     last: index == recent.count - 1) {
                                Text("\(charge.from)% → \(charge.to)%"
                                     + (charge.observed && charge.duration >= 60 ? " · \(BandBatteryReport.duration(charge.duration))" : ""))
                                    .font(.system(size: 14, weight: .medium).monospacedDigit())
                                    .foregroundStyle(JcTheme.muted)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Activity

    private func activity(_ f: Figures) -> some View {
        let r = f.report
        let readings = r.spans(.reading, since: f.since)
        let ecgs = readings.filter { $0.detail == BandMeasure.ecg.name }.count
        let workouts = r.spans(.workout, since: f.since)
        return VStack(alignment: .leading, spacing: 0) {
            GlassQuietLabel("Activity, \(span.label)")
            GlassGroup {
                // Measured per way of managing (the drain while each was set), when followed long enough.
                ForEach([BandMeasureControl.phone, .band], id: \.self) { control in
                    if let rate = r.perDay(managedBy: control, since: f.since) {
                        BatteryStatRow(symbol: control == .phone ? "iphone" : "applewatch",
                                       title: control == .phone ? "Drain, managed by Phone" : "Drain, managed by Band",
                                       value: "\(Int(rate.rounded()))% a day")
                    }
                }
                BatteryStatRow(symbol: "waveform.path.ecg", title: "Spot readings",
                               value: ecgs > 0 ? "\(readings.count) (\(ecgs) ECG)" : "\(readings.count)")
                BatteryStatRow(symbol: "figure.run", title: "Workouts",
                               value: workouts.isEmpty ? "none"
                                   : "\(workouts.count) · \(BandBatteryReport.duration(r.seconds(.workout, since: f.since)))")
                BatteryStatRow(symbol: "heart.text.square", title: "All-day sensing on",
                               value: BatteryBreakdown.time(r.seconds(.sensing, since: f.since)))
                BatteryStatRow(symbol: "dot.radiowaves.left.and.right", title: "Linked to the phone",
                               value: BatteryBreakdown.time(r.seconds(.linked, since: f.since)))
                BatteryStatRow(symbol: "arrow.triangle.2.circlepath", title: "Syncs",
                               value: "\(r.count(.sync, since: f.since))")
                BatteryStatRow(symbol: "dot.radiowaves.left.and.right", title: "Found with Find band",
                               value: "\(r.count(.find, since: f.since)) times", last: true)
            }
        }
    }

    // MARK: Settings

    private var sensingNow: String {
        let plan = scheduler.plan
        if plan.control == .phone {
            guard plan.nightTracking else { return "Off" }
            let from = BandTimeOfDay.date(plan.nightStart).formatted(date: .omitted, time: .shortened)
            let to = BandTimeOfDay.date(plan.nightEnd).formatted(date: .omitted, time: .shortened)
            return "Overnight, \(from)–\(to)"
        }
        guard let on = session.settings?.isOn("auto_ppg") else { return "—" }
        return on ? "On all day" : "Off"
    }

    private var settings: some View {
        let alertsOn = session.alerts.map { a in BandAlertSwitches.allApps.filter { a.isOn($0) == true }.count }
        let raise = session.raiseToWake?.enabled ?? session.handshake?.raiseToWake
        return VStack(alignment: .leading, spacing: 0) {
            GlassQuietLabel("Settings that use battery")
            GlassGroup {
                BatteryStatRow(symbol: "heart.text.square", title: "All-day sensing", value: sensingNow)
                BatteryStatRow(symbol: "dot.radiowaves.left.and.right", title: "Keep Alive",
                               value: manager.keepAliveEnabled ? "On" : "Off")
                BatteryStatRow(symbol: "hand.raised.fill", title: "Raise to wake",
                               value: raise.map { $0 ? "On" : "Off" } ?? "—")
                BatteryStatRow(symbol: "bell.badge.fill", title: "Phone notifications",
                               value: alertsOn.map { $0 == 1 ? "1 app" : "\($0) apps" } ?? "—", last: true)
            }
            Text("The band's every-minute sensing costs it the most. Managed by Phone (Monitoring → "
               + "Measurements) keeps it to the night and asks for readings on your intervals instead.")
                .font(JcText.small)
                .foregroundStyle(JcTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
                .padding(.horizontal, 4)
        }
    }
}

// MARK: - Headline

/// The level now, big, how long it lasts at the recent rate, and the drain a day.
struct BandBatteryHeadline: View {
    let report: BandBatteryReport?
    let live: RingBattery?

    private var percent: Int? { live?.percent ?? report?.latest?.percent }
    private var charging: Bool { live?.charging ?? report?.charging ?? false }

    var body: some View {
        GlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 16) {
                    BandBatteryGauge(percent: percent, charging: charging)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(percent.map { "\($0)%" } ?? "—")
                                .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
                                .foregroundStyle(JcTheme.text)
                                .contentTransition(.numericText())
                            if charging {
                                Text("charging")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(JcTheme.success)
                            }
                        }
                        Text(subtitle)
                            .font(JcText.small)
                            .foregroundStyle(JcTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                if let report {
                    HStack(alignment: .top, spacing: 12) {
                        figure("A day", report.perDay(since: report.now.addingTimeInterval(-7 * 86_400))
                            .map { String(format: "−%.0f%%", $0) } ?? "—")
                        figure("An hour", report.recentPerHour.map { String(format: "−%.1f%%", $0) } ?? "—")
                        figure("Last charge", report.lastCharge.map { Self.ago(report.now.timeIntervalSince($0.end)) } ?? "—")
                        figure("Charged to", report.lastCharge.map { "\($0.to)%" } ?? "—")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var subtitle: String {
        if charging { return "On the charger" }
        if let left = report?.timeLeft { return "About \(BandBatteryReport.duration(left)) left at the recent rate" }
        return report?.latest.map { "Read \($0.date.formatted(.relative(presentation: .named)))" } ?? "Not read yet"
    }

    static func ago(_ seconds: TimeInterval) -> String {
        if seconds < 3600 { return "now" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) h ago" }
        return "\(Int(seconds / 86_400)) d ago"
    }

    private func figure(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(JcText.small)
                .foregroundStyle(JcTheme.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value)
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(JcTheme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A ring that fills to the level: the accent, amber when low, green on the charger.
struct BandBatteryGauge: View {
    let percent: Int?
    let charging: Bool

    private var tint: Color {
        if charging { return JcTheme.success }
        return (percent ?? 100) <= 20 ? JcTheme.amber : JcTheme.accent
    }

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.08), lineWidth: 7)
            Circle()
                .trim(from: 0, to: CGFloat(percent ?? 0) / 100)
                .stroke(tint, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.spring(duration: 0.8), value: percent)
            JcIcon(charging ? "bolt.fill" : "applewatch")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(tint)
                .symbolEffect(.pulse, options: .repeating, isActive: charging)
        }
        .frame(width: 64, height: 64)
        .accessibilityHidden(true)
    }
}

// MARK: - Curve

/// The level over the range, the charges shaded green and workouts in the accent.
struct BandBatteryCurve: View {
    let report: BandBatteryReport
    let domain: ClosedRange<Date>
    @State private var scrubbed: Date?

    private var samples: [BandBatteryReport.Sample] {
        // The reading just before the range too, so the line starts at its edge.
        let before = report.samples.last { $0.date < domain.lowerBound }
        return (before.map { [$0] } ?? []) + report.samples.filter { $0.date >= domain.lowerBound }
    }

    private var picked: BandBatteryReport.Sample? {
        guard let scrubbed else { return nil }
        return samples.min { abs($0.date.timeIntervalSince(scrubbed)) < abs($1.date.timeIntervalSince(scrubbed)) }
    }

    var body: some View {
        GlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Battery level").font(JcText.label).foregroundStyle(JcTheme.text)
                    Spacer()
                    Text(readout).font(JcText.small.monospacedDigit()).foregroundStyle(JcTheme.muted)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                if samples.count < 2 {
                    Text("The curve fills in as the level changes")
                        .font(JcText.small).foregroundStyle(JcTheme.muted)
                        .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
                } else {
                    chart
                }
                HStack(spacing: 14) {
                    legend(JcTheme.success, "Charging")
                    legend(JcTheme.accent.opacity(0.6), "Workout")
                }
            }
        }
    }

    private var readout: String {
        guard let picked else { return report.latest.map { "\($0.percent)% now" } ?? "" }
        let when = picked.date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        return "\(when) · \(picked.percent)%\(picked.charging ? " · charging" : "")"
    }

    private var chart: some View {
        let workouts = report.spans(.workout, since: domain.lowerBound)
        let charges = report.charges.filter { $0.observed && $0.end >= domain.lowerBound }
        return Chart {
            ForEach(Array(charges.enumerated()), id: \.offset) { _, c in
                RectangleMark(xStart: .value("From", max(c.start, domain.lowerBound)),
                              xEnd: .value("To", c.ongoing ? domain.upperBound : c.end))
                    .foregroundStyle(JcTheme.success.opacity(0.14))
            }
            ForEach(Array(workouts.enumerated()), id: \.offset) { _, w in
                RectangleMark(xStart: .value("From", max(w.start, domain.lowerBound)), xEnd: .value("To", w.end))
                    .foregroundStyle(JcTheme.accent.opacity(0.16))
            }
            ForEach(samples, id: \.date) { s in
                AreaMark(x: .value("Time", max(s.date, domain.lowerBound)), y: .value("Level", s.percent))
                    .foregroundStyle(LinearGradient(colors: [JcTheme.accent.opacity(0.3), JcTheme.accent.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", max(s.date, domain.lowerBound)), y: .value("Level", s.percent))
                    .foregroundStyle(JcTheme.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
            if let picked {
                RingScrubRule(x: picked.date)
                PointMark(x: .value("Time", picked.date), y: .value("Level", picked.percent))
                    .foregroundStyle(picked.charging ? JcTheme.success : JcTheme.accent)
                    .symbolSize(60)
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...100)
        .chartXSelection(value: $scrubbed)
        .chartYAxis {
            AxisMarks(position: .trailing, values: [0, 50, 100]) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                AxisValueLabel { if let v = value.as(Int.self) { Text("\(v)%") } }.foregroundStyle(JcTheme.muted)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                if domain.upperBound.timeIntervalSince(domain.lowerBound) <= 86_400 {
                    AxisValueLabel(format: .dateTime.hour()).foregroundStyle(JcTheme.muted)
                } else {
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day()).foregroundStyle(JcTheme.muted)
                }
            }
        }
        .frame(height: 160)
        .sensoryFeedback(.selection, trigger: picked?.date)
        .accessibilityLabel("Battery level over time")
        .accessibilityHint("Drag across the curve to read the level at each time")
    }
}

// MARK: - Days

/// The battery used each day, with the average a day as a line across.
struct BandBatteryDays: View {
    let days: [BandBatteryReport.Day]
    let average: Double?
    @State private var scrubbed: Date?

    private var picked: BandBatteryReport.Day? {
        guard let scrubbed else { return nil }
        return days.min { abs($0.start.addingTimeInterval(43_200).timeIntervalSince(scrubbed))
            < abs($1.start.addingTimeInterval(43_200).timeIntervalSince(scrubbed)) }
    }

    var body: some View {
        GlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Used each day").font(JcText.label).foregroundStyle(JcTheme.text)
                    Spacer()
                    Text(readout).font(JcText.small.monospacedDigit()).foregroundStyle(JcTheme.muted)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                Chart {
                    ForEach(days) { day in
                        BarMark(x: .value("Day", day.start, unit: .day), y: .value("Used", day.points))
                            .foregroundStyle(JcTheme.accent.gradient)
                            .cornerRadius(4)
                            .opacity(picked == nil || picked?.id == day.id ? (day.seconds < 12 * 3600 ? 0.55 : 1) : 0.35)
                    }
                    if let average {
                        RuleMark(y: .value("Average", average))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .foregroundStyle(Color.white.opacity(0.5))
                    }
                }
                .chartXSelection(value: $scrubbed)
                .chartYAxis {
                    AxisMarks(position: .trailing) { value in
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                        AxisValueLabel { if let v = value.as(Double.self) { Text("\(Int(v))%") } }
                            .foregroundStyle(JcTheme.muted)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: days.count > 7 ? 7 : 1)) { _ in
                        AxisValueLabel(format: days.count > 7 ? .dateTime.month(.abbreviated).day() : .dateTime.weekday(.narrow))
                            .foregroundStyle(JcTheme.muted)
                    }
                }
                .frame(height: 130)
                .sensoryFeedback(.selection, trigger: picked?.id)
                Text("A paler bar is a day the band was followed for under 12 hours")
                    .font(JcText.small)
                    .foregroundStyle(JcTheme.muted)
            }
        }
    }

    private var readout: String {
        if let picked {
            return "\(picked.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) · "
                + String(format: "%.0f%%", picked.points)
        }
        return average.map { String(format: "%.0f%% a day on average", $0) } ?? ""
    }
}

private func legend(_ color: Color, _ title: String) -> some View {
    HStack(spacing: 6) {
        Circle().fill(color).frame(width: 8, height: 8)
        Text(title).font(JcText.small).foregroundStyle(JcTheme.muted)
    }
}

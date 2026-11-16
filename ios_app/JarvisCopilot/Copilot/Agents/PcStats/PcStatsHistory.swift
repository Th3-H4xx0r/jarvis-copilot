import SwiftUI

/// Under the dashboard: game sessions (tap for the session's graphs), energy and cost by
/// day / week / month, marked moments from the last week, and 90-day temperatures and fans.
struct PcStatsHistorySections: View {
    let model: PcStatsModel
    @State private var showAllSessions = false
    @State private var openSession: PcSession?
    @State private var selectedBucket: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sessions
            energy
            moments
            health
        }
        .navigationDestination(item: $openSession) { s in
            PcSessionDetail(model: model, session: s)
        }
    }

    // MARK: Sessions

    @ViewBuilder
    private var sessions: some View {
        JcSectionLabel("Game sessions") {
            if model.sessions.count > 5 {
                Button(showAllSessions ? "Show less" : "Show all") { withAnimation { showAllSessions.toggle() } }
                    .foregroundStyle(JcTheme.accent)
            }
        }
        if model.sessions.isEmpty {
            emptyCard(model.historyLoaded ? "No game sessions yet. They're recorded while game mode is on."
                                          : "Loading…")
        } else {
            let list = showAllSessions ? model.sessions : Array(model.sessions.prefix(5))
            PcPanel(padding: 0) {
                ForEach(Array(list.enumerated()), id: \.element.id) { i, s in
                    JcRow(symbol: "gamecontroller", title: s.name, subtitle: PcHistoryCopy.sessionLine(s),
                          subtitleLines: 1, last: i == list.count - 1, action: { openSession = s })
                }
            }
        }
    }

    // MARK: Energy

    @ViewBuilder
    private var energy: some View {
        JcSectionLabel("Energy & cost") {
            if let e = model.energy, e.totalKwh > 0 {
                Text("\(PcFormat.kwh(e.totalKwh)) kWh · \(PcFormat.money(e.totalCost, currency: e.currency))")
                    .monospacedDigit()
            }
        }
        PcPanel(padding: 16) {
            JcSegmentedPicker(PcEnergyPeriod.allCases.map { ($0, $0.title) },
                              selection: Binding(get: { model.energyPeriod }, set: { model.energyPeriod = $0; selectedBucket = nil }))
            if let e = model.energy, !e.buckets.isEmpty {
                energyChart(e).padding(.top, 16)
            } else {
                Text(model.historyLoaded ? "No energy recorded yet" : "Loading…")
                    .font(.footnote)
                    .foregroundStyle(PcLook.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
    }

    private func energyChart(_ e: PcEnergy) -> some View {
        let peak = max(e.buckets.map(\.kwh).max() ?? 0, 0.001)
        let chosen = e.buckets.first { $0.id == selectedBucket } ?? e.buckets.last!
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(PcFormat.kwh(chosen.kwh))
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .tracking(-0.7)
                    .monospacedDigit()
                    .foregroundStyle(JcTheme.text)
                    .contentTransition(.numericText())
                Text("kWh").font(.system(size: 15, weight: .medium)).foregroundStyle(PcLook.secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(e.price > 0 ? PcFormat.money(chosen.cost, currency: e.currency) : "Set a price in PC Stats settings")
                        .font(.system(size: e.price > 0 ? 15 : 11, weight: .semibold))
                        .foregroundStyle(e.price > 0 ? JcTheme.text : PcLook.secondary)
                        .monospacedDigit()
                    Text(PcHistoryCopy.bucketTitle(chosen.start, period: model.energyPeriod))
                        .font(.system(size: 12))
                        .foregroundStyle(PcLook.secondary)
                }
            }
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(e.buckets) { b in
                    let on = b.id == chosen.id
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(PcLook.tint(.power).opacity(on ? 1 : 0.35))
                            .frame(height: max(3, 96 * b.kwh / peak))
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.snappy) { selectedBucket = b.id } }
                    .accessibilityElement()
                    .accessibilityLabel("\(PcHistoryCopy.bucketTitle(b.start, period: model.energyPeriod)): \(PcFormat.kwh(b.kwh)) kilowatt hours")
                    .accessibilityAddTraits(.isButton)
                }
            }
            .frame(height: 100)
            HStack {
                if let first = e.buckets.first { Text(PcHistoryCopy.axisLabel(first.start, period: model.energyPeriod)) }
                Spacer()
                Text(model.energyPeriod == .day ? "Today" : model.energyPeriod == .week ? "This week" : "This month")
            }
            .font(.system(size: 10.5))
            .foregroundStyle(PcLook.secondary)
        }
        .sensoryFeedback(.selection, trigger: selectedBucket)
    }

    // MARK: Moments

    @ViewBuilder
    private var moments: some View {
        JcSectionLabel("Marked moments") { Text("Last 7 days") }
        if model.moments.isEmpty {
            emptyCard(model.historyLoaded ? "Nothing marked in the last 7 days." : "Loading…")
        } else {
            let list = Array(model.moments.prefix(12))
            PcPanel(padding: 0) {
                ForEach(Array(list.enumerated()), id: \.element.id) { i, m in
                    HStack(alignment: .top, spacing: 12) {
                        JcIconSquare(symbol: PcHistoryCopy.momentSymbol(m), tint: PcMomentRow.color(m))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(PcMomentRow.title(m, catalog: model.catalog))
                                .font(.system(size: 15, weight: .medium)).foregroundStyle(JcTheme.text)
                            Text(PcMomentRow.detail(m, catalog: model.catalog))
                                .font(.system(size: 12)).foregroundStyle(JcTheme.muted).monospacedDigit()
                        }
                        Spacer(minLength: 8)
                        Text(m.t, format: .dateTime.weekday(.abbreviated).hour().minute())
                            .font(.system(size: 12)).foregroundStyle(JcTheme.muted)
                    }
                    .padding(.horizontal, JcUnified.cardPadding)
                    .padding(.vertical, 12)
                    .accessibilityElement(children: .combine)
                    if i < list.count - 1 { JcRowSeparator() }
                }
            }
        }
    }

    // MARK: Health

    @ViewBuilder
    private var health: some View {
        JcSectionLabel("Long-term health") { Text("90 days") }
        let temps = ["cpu.temp", "gpu.temp"].filter { model.health[$0] != nil }
        let fans = model.health.keys.filter { $0 == "gpu.fan" || $0.hasPrefix("fan.") }.sorted()
        if temps.isEmpty && fans.isEmpty {
            emptyCard(model.historyLoaded ? "Temperatures and fans build up here as the PC reports." : "Loading…")
        } else {
            VStack(spacing: 12) {
                if !temps.isEmpty { healthChart("Temperatures", keys: temps) }
                if !fans.isEmpty { healthChart("Fans", keys: fans) }
            }
        }
    }

    private func healthChart(_ title: String, keys: [String]) -> some View {
        let span = PcTimeSpan.last(90 * 86_400)
        let series = keys.enumerated().map { i, k in
            PcLineChart.Series(id: k, points: model.health[k] ?? [], color: PcLook.seriesColor(i, key: k, style: PcWidgetStyle(), keys: keys))
        }
        let all = series.flatMap { $0.points.flatMap { [$0.min, $0.max] } }
        let unit = model.catalog.info(keys[0])?.unit ?? ""
        return PcPanel(padding: 16) {
            PcCardHeader(title: title, symbol: title == "Fans" ? PcCategory.cooling.symbol : PcCategory.temps.symbol,
                         tint: PcLook.tint(title == "Fans" ? .cooling : .temps), context: "90 days")
            PcFlow(spacing: 14) {
                ForEach(series) { s in
                    let peak = s.points.map(\.max).max()
                    HStack(spacing: 6) {
                        Circle().fill(s.color).frame(width: 6, height: 6)
                        Text(PcFormat.shortLabel(s.id, catalog: model.catalog)).foregroundStyle(PcLook.secondary)
                        Text(peak.map { "peak \(PcFormat.compact($0, unit: unit))" } ?? "—")
                            .fontWeight(.semibold).foregroundStyle(JcTheme.text).monospacedDigit()
                    }
                    .font(.system(size: 13))
                    .lineLimit(1)
                }
            }
            .padding(.top, 8)
            PcLineChart(series: series, span: span, yRange: PcChartScale.range(all, unit: unit), area: false,
                        lineWidth: 2, band: true, gridlines: true, unit: unit)
                .frame(height: 110)
                .padding(.top, 12)
            HStack { Text("90 days ago"); Spacer(); Text("today") }
                .font(.system(size: 10.5))
                .foregroundStyle(PcLook.secondary)
                .padding(.top, 4)
        }
    }

    private func emptyCard(_ text: String) -> some View {
        PcPanel {
            Text(text).font(.system(size: 15)).foregroundStyle(PcLook.secondary)
        }
    }
}

enum PcHistoryCopy {
    /// "Yesterday 21:04 · 2 h 10 min · 141 fps".
    static func sessionLine(_ s: PcSession, now: Date = Date()) -> String {
        var parts = [s.start.formatted(.relative(presentation: .named)), PcFormat.duration(s.duration(now: now))]
        if s.end == nil { parts[0] = "Playing now" }
        if let fps = s.fpsAvg { parts.append("\(PcFormat.number(fps, unit: "fps")) fps") }
        return parts.joined(separator: " · ")
    }

    static func bucketTitle(_ d: Date, period: PcEnergyPeriod) -> String {
        switch period {
        case .day: return Calendar.current.isDateInToday(d) ? "Today" : d.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        case .week: return "Week of \(d.formatted(.dateTime.month(.abbreviated).day()))"
        case .month: return d.formatted(.dateTime.month(.wide).year())
        }
    }

    static func axisLabel(_ d: Date, period: PcEnergyPeriod) -> String {
        switch period {
        case .day, .week: return d.formatted(.dateTime.month(.abbreviated).day())
        case .month: return d.formatted(.dateTime.month(.abbreviated).year(.twoDigits))
        }
    }

    static func momentSymbol(_ m: PcMoment) -> String {
        switch m.kind {
        case "spike": return "bolt.fill"
        case "drop": return "arrow.down.right"
        case "throttle": return "tortoise.fill"
        default: return "thermometer.high"
        }
    }
}

// MARK: - Session detail

/// One game session: its numbers and its frames, temperatures and power over the session,
/// with marked moments as dashed lines.
struct PcSessionDetail: View {
    let model: PcStatsModel
    let session: PcSession

    @State private var series: [String: [PcPoint]] = [:]
    @State private var moments: [PcMoment] = []
    @State private var loaded = false

    private var span: PcTimeSpan {
        PcTimeSpan(from: session.start.timeIntervalSince1970, to: (session.end ?? Date()).timeIntervalSince1970)
    }

    var body: some View {
        ScrollView {
            JcPageColumn {
                PcPanel(padding: 18) {
                    PcWidgetLabel(text: session.start.formatted(.dateTime.weekday(.wide).month().day().hour().minute()))
                    Text(session.name)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(JcTheme.text)
                        .padding(.top, 6)
                    Text(PcFormat.duration(session.duration()) + (session.end == nil ? " · playing now" : ""))
                        .font(.system(size: 13)).foregroundStyle(PcLook.secondary).padding(.top, 2)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 4),
                              alignment: .leading, spacing: 14) {
                        stat(session.fpsAvg.map { PcFormat.number($0, unit: "fps") }, "avg fps")
                        stat(session.fpsLow1.map { PcFormat.number($0, unit: "fps") }, "1% low")
                        stat(session.cpuTempMax.map { PcFormat.compact($0, unit: "°C") }, "CPU peak")
                        stat(session.gpuTempMax.map { PcFormat.compact($0, unit: "°C") }, "GPU peak")
                        stat(session.energyWh.map { PcFormat.number($0, unit: "Wh") + " Wh" }, "energy")
                        stat(session.wattsAvg.map { PcFormat.compact($0, unit: "W") }, "avg (est.)")
                        stat(session.wattsMax.map { PcFormat.compact($0, unit: "W") }, "peak (est.)")
                        stat(session.throttleS.map { PcFormat.duration($0) }, "throttling")
                    }
                    .padding(.top, 16)
                }
                .padding(.top, 8)

                chart("Frames", keys: ["fps", "fps.low1"])
                chart("Temperatures", keys: ["gpu.temp", "cpu.temp"])
                chart("Power (est.)", keys: ["power.total", "power.gpu", "power.cpu"])

                if !moments.isEmpty {
                    JcSectionLabel("Marked in this session")
                    PcPanel(padding: 0) {
                        ForEach(Array(moments.enumerated()), id: \.element.id) { i, m in
                            JcRow(symbol: PcHistoryCopy.momentSymbol(m), title: PcMomentRow.title(m, catalog: model.catalog),
                                  subtitle: "\(m.t.formatted(.dateTime.hour().minute())) · \(PcMomentRow.detail(m, catalog: model.catalog))",
                                  subtitleLines: 1, last: i == moments.count - 1) { EmptyView() }
                        }
                    }
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .jcPageChrome(session.name, header: .inline)
        .task {
            let keys = ["fps", "fps.low1", "gpu.temp", "cpu.temp", "power.total", "power.gpu", "power.cpu"]
            var out: [String: [PcPoint]] = [:]
            for k in keys { out[k] = await model.sessionSeries(session, key: k) }
            series = out
            moments = await model.sessionMoments(session)
            loaded = true
        }
    }

    private func chart(_ title: String, keys: [String]) -> some View {
        let lines = keys.enumerated().compactMap { i, k -> PcLineChart.Series? in
            guard let pts = series[k], !pts.isEmpty else { return nil }
            return PcLineChart.Series(id: k, points: pts, color: PcLook.seriesColor(i, key: k, style: PcWidgetStyle(), keys: keys))
        }
        let unit = model.catalog.info(keys[0])?.unit ?? ""
        let all = lines.flatMap { $0.points.map(\.avg) }
        return VStack(alignment: .leading, spacing: 0) {
            JcSectionLabel(title)
            PcPanel(padding: 16) {
                if lines.isEmpty {
                    Group {
                        if loaded {
                            Text("Not recorded for this session").font(.footnote).foregroundStyle(PcLook.secondary)
                        } else {
                            JcLoader(size: 20)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    PcFlow(spacing: 14) {
                        ForEach(lines) { s in
                            HStack(spacing: 6) {
                                Circle().fill(s.color).frame(width: 6, height: 6)
                                Text(PcFormat.shortLabel(s.id, catalog: model.catalog)).foregroundStyle(PcLook.secondary)
                                Text(PcFormat.compact(s.points.map(\.avg).reduce(0, +) / Double(s.points.count),
                                                      unit: model.catalog.info(s.id)?.unit ?? unit) + " avg")
                                    .fontWeight(.semibold).foregroundStyle(JcTheme.text).monospacedDigit()
                            }
                            .font(.system(size: 13))
                            .lineLimit(1)
                        }
                    }
                    PcLineChart(series: lines, span: span, yRange: PcChartScale.range(all, unit: unit),
                                area: lines.count == 1, markers: moments.map { $0.t.timeIntervalSince1970 },
                                gridlines: true, unit: unit)
                        .frame(height: 140)
                        .padding(.top, 12)
                    HStack {
                        Text(session.start, format: .dateTime.hour().minute())
                        Spacer()
                        Text(session.end ?? Date(), format: .dateTime.hour().minute())
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(PcLook.secondary)
                    .padding(.top, 4)
                }
            }
        }
    }

    private func stat(_ value: String?, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value ?? "—").font(.system(size: 16, weight: .semibold)).foregroundStyle(JcTheme.text)
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.system(size: 11.5)).foregroundStyle(PcLook.secondary).lineLimit(1)
        }
    }
}

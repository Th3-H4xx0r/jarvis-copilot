import Charts
import SwiftUI

/// Settings → Battery usage: what the battery went on, from the phone's own hour-by-hour ledger
/// (`EnergyLedger`) and iOS's daily report.
///
/// iOS's Battery screen gives the app one percentage and two durations. This page answers the
/// next question — which part of the app — by screen, by kind of work, in a pocket, and by
/// feature talking to the server, with the battery's own curve above it all.
struct BatteryUsagePage: View {
    enum Span: String, CaseIterable, Identifiable {
        case day = "24 hours", threeDays = "3 days"
        var id: String { rawValue }
        var seconds: TimeInterval { self == .day ? 86_400 : 3 * 86_400 }
    }

    @State private var span: Span = .day
    @State private var hours: [EnergyLedger.Hour] = []
    @State private var samples: [EnergyLedger.Sample] = []
    @State private var screens: [EnergyLedger.Span] = []
    @State private var reports: [EnergyReport] = []
    @State private var now = Date()

    private var since: Date { now.addingTimeInterval(-span.seconds) }
    private var summary: BatteryUsageSummary {
        BatteryUsageSummary(hours: BatteryUsageSummary.within(hours, since: since))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Picker("Range", selection: $span) {
                    ForEach(Span.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                let summary = self.summary
                if summary.hours.isEmpty {
                    JcEmptyState(symbol: "battery.75percent", title: "Collecting",
                                 subtitle: "The first hour is written at the top of the hour.")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                } else {
                    BatteryHeadline(summary: summary, label: span == .day ? "last 24 hours" : "last 3 days")
                    BatteryLevelChart(samples: samples.filter { $0.at >= since }, screens: screens,
                                      domain: since...now)
                    BatteryCPUChart(bars: summary.bars)
                    BatteryBreakdown(summary: summary)
                    hourList(summary)
                }
                dailyReport
                Text("Measured on this phone. CPU is the app's own; the battery level and its drain "
                   + "per hour are the whole phone's, so an hour spent in other apps shows there too. "
                   + "iOS adds its screen and radio time on top of the CPU.")
                    .font(JcText.small)
                    .foregroundStyle(JcTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 40)
        }
        .refreshable { load() }
        .onAppear { load() }
        .jcScreen("Battery usage")
    }

    private func load() {
        now = Date()
        hours = EnergyLedger.shared.timeline()
        samples = EnergyLedger.shared.batterySamples()
        screens = EnergyLedger.shared.screenSpans()
        reports = EnergyReport.history()
    }

    // MARK: Hours

    private func hourList(_ summary: BatteryUsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            GlassQuietLabel("Hour by hour")
            GlassGroup {
                let rows = Array(summary.hours.reversed())
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, hour in
                    NavigationLink {
                        BatteryHourScreen(hour: hour)
                    } label: {
                        GlassRow(symbol: hour.seconds("foreground") > 60 ? "iphone" : "moon.fill",
                                 title: Self.hourTitle(hour),
                                 subtitle: Self.hourLine(hour),
                                 last: index == rows.count - 1)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    static func hourTitle(_ hour: EnergyLedger.Hour) -> String {
        let start = hour.start.formatted(date: .omitted, time: .shortened)
        let end = hour.end.formatted(date: .omitted, time: .shortened)
        let drained = hour.drained.map { String(format: " · −%.0f%%", $0) } ?? ""
        return "\(start)–\(end)\(drained)"
    }

    static func hourLine(_ hour: EnergyLedger.Hour) -> String {
        var parts = ["\(Int(hour.totalCPU.rounded())) s CPU"]
        let screen = hour.seconds("foreground")
        if screen >= 60 { parts.append("\(BatteryUsageSummary.duration(screen)) on screen") }
        if hour.seconds("charging") >= 60 { parts.append("charging") }
        if hour.seconds("bg.cellular") >= 600 { parts.append("cellular") }
        if hour.seconds("background") > 60, hour.seconds("bg.keepalive") < hour.seconds("background") * 0.5 {
            parts.append("suspended")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: iOS's daily report

    @ViewBuilder
    private var dailyReport: some View {
        if let day = reports.last {
            VStack(alignment: .leading, spacing: 0) {
                GlassQuietLabel("iOS's daily report")
                GlassGroup {
                    BatteryStatRow(symbol: "calendar", title: "Received",
                                   value: day.received.formatted(date: .abbreviated, time: .shortened))
                    BatteryStatRow(symbol: "cpu", title: "App CPU",
                                   value: day.cpuSecondsPerHour.map { String(format: "%.0f s an hour alive", $0) } ?? "—")
                    BatteryStatRow(symbol: "iphone", title: "On screen",
                                   value: BatteryUsageSummary.duration(day.foregroundSeconds))
                    BatteryStatRow(symbol: "moon.fill", title: "Background",
                                   value: BatteryUsageSummary.duration(day.backgroundSeconds))
                    BatteryStatRow(symbol: "speaker.slash.fill", title: "Of that, silent audio",
                                   value: BatteryUsageSummary.duration(day.backgroundAudioSeconds))
                    if let down = day.wifiDownBytes, let up = day.wifiUpBytes {
                        BatteryStatRow(symbol: "wifi", title: "Wi-Fi data",
                                       value: "\(Self.bytes(down)) in · \(Self.bytes(up)) out")
                    }
                    if let down = day.cellularDownBytes, let up = day.cellularUpBytes {
                        BatteryStatRow(symbol: "cellularbars", title: "Cellular data",
                                       value: "\(Self.bytes(down)) in · \(Self.bytes(up)) out")
                    }
                    BatteryStatRow(symbol: "exclamationmark.triangle.fill", title: "Ended by iOS in background",
                                   value: Self.exits(day.backgroundExits), last: true)
                }
            }
        }
    }

    static func bytes(_ value: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }

    static func exits(_ exits: [String: Int]?) -> String {
        guard let exits, !exits.isEmpty else { return "never" }
        return exits.sorted { $0.value > $1.value }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
    }
}

// MARK: - One hour

/// One hour, broken down the same way as the page.
struct BatteryHourScreen: View {
    let hour: EnergyLedger.Hour

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                let summary = BatteryUsageSummary(hours: [hour])
                BatteryHeadline(summary: summary, label: BatteryUsagePage.hourTitle(hour))
                BatteryBreakdown(summary: summary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 40)
        }
        .jcScreen(hour.start.formatted(date: .omitted, time: .shortened))
    }
}

// MARK: - Headline

/// The battery the phone lost, big, and where the time went, small.
struct BatteryHeadline: View {
    let summary: BatteryUsageSummary
    let label: String

    var body: some View {
        GlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(summary.drained.map { String(format: "−%.0f%%", $0) } ?? "—")
                            .font(.system(size: 44, weight: .bold).monospacedDigit())
                            .foregroundStyle(JcTheme.text)
                        Text("battery")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(JcTheme.muted)
                    }
                    Text("Lost by the phone, \(label), charging left out")
                        .font(JcText.small)
                        .foregroundStyle(JcTheme.muted)
                }
                HStack(alignment: .top, spacing: 12) {
                    figure("On screen", BatteryUsageSummary.duration(summary.onScreen))
                    figure("Background", BatteryUsageSummary.duration(summary.inPocket))
                    figure("Kept alive", BatteryUsageSummary.duration(summary.keptAlive))
                    figure("App CPU", BatteryUsageSummary.duration(summary.cpuTotal))
                }
                let rates = [("In a pocket", summary.pocketDrain), ("On screen", summary.screenDrain)]
                    .compactMap { name, rate in rate.map { "\(name) \(String(format: "%.1f", $0))%/h" } }
                if !rates.isEmpty {
                    Text("Phone drain: " + rates.joined(separator: " · "))
                        .font(JcText.small.weight(.semibold))
                        .foregroundStyle(JcTheme.accent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func figure(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
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

// MARK: - Charts

/// The battery's level over the range, with time on screen and on the charger shaded.
struct BatteryLevelChart: View {
    let samples: [EnergyLedger.Sample]
    let screens: [EnergyLedger.Span]
    let domain: ClosedRange<Date>
    @State private var scrubbed: Date?

    private var charging: [EnergyLedger.Span] {
        var out: [EnergyLedger.Span] = []
        var from: Date?
        for sample in samples {
            if sample.charging, from == nil { from = sample.at }
            if !sample.charging, let start = from { out.append(.init(start: start, end: sample.at)); from = nil }
        }
        if let from { out.append(.init(start: from, end: domain.upperBound)) }
        return out
    }

    private var picked: EnergyLedger.Sample? {
        guard let scrubbed else { return nil }
        return samples.last { $0.at <= scrubbed } ?? samples.first
    }

    var body: some View {
        GlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Battery level").font(JcText.label).foregroundStyle(JcTheme.text)
                    Spacer()
                    Text(readout).font(JcText.small.monospacedDigit()).foregroundStyle(JcTheme.muted)
                }
                if samples.count < 2 {
                    Text("The curve fills in as the level changes.")
                        .font(JcText.small).foregroundStyle(JcTheme.muted)
                        .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
                } else {
                    chart
                }
                HStack(spacing: 14) {
                    batteryLegend(JcTheme.accent, "On screen")
                    batteryLegend(JcTheme.success, "Charging")
                }
            }
        }
    }

    private var readout: String {
        guard let picked, let scrubbed else {
            return samples.last.map { "\(Int(($0.level * 100).rounded()))% now" } ?? ""
        }
        let onScreen = screens.contains { $0.start <= scrubbed && scrubbed <= $0.end }
        let state = picked.charging ? "charging" : onScreen ? "on screen" : "background"
        return "\(scrubbed.formatted(date: .omitted, time: .shortened)) · \(Int((picked.level * 100).rounded()))% · \(state)"
    }

    private var chart: some View {
        Chart {
            ForEach(Array(screens.filter { $0.end >= domain.lowerBound }.enumerated()), id: \.offset) { _, span in
                RectangleMark(xStart: .value("From", max(span.start, domain.lowerBound)), xEnd: .value("To", span.end))
                    .foregroundStyle(JcTheme.accent.opacity(0.16))
            }
            ForEach(Array(charging.enumerated()), id: \.offset) { _, span in
                RectangleMark(xStart: .value("From", max(span.start, domain.lowerBound)), xEnd: .value("To", span.end))
                    .foregroundStyle(JcTheme.success.opacity(0.14))
            }
            ForEach(samples, id: \.at) { sample in
                AreaMark(x: .value("Time", sample.at), y: .value("Level", sample.level * 100))
                    .foregroundStyle(LinearGradient(colors: [JcTheme.accent.opacity(0.28), JcTheme.accent.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.stepEnd)
                LineMark(x: .value("Time", sample.at), y: .value("Level", sample.level * 100))
                    .foregroundStyle(JcTheme.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .interpolationMethod(.stepEnd)
            }
            if let scrubbed, let picked {
                RingScrubRule(x: scrubbed)
                PointMark(x: .value("Time", scrubbed), y: .value("Level", picked.level * 100))
                    .foregroundStyle(JcTheme.accent)
                    .symbolSize(60)
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...100)
        .chartXSelection(value: $scrubbed)
        .chartYAxis {
            AxisMarks(position: .trailing, values: [0, 50, 100]) { _ in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                AxisValueLabel().foregroundStyle(Color.secondary)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: .dateTime.hour()).foregroundStyle(Color.secondary)
            }
        }
        .frame(height: 140)
        .sensoryFeedback(.selection, trigger: picked?.at)
        .accessibilityHint("Drag across the curve to read the level at each time")
    }
}

/// The app's CPU each hour: on screen and in the background, stacked.
struct BatteryCPUChart: View {
    let bars: [BatteryUsageSummary.HourBar]
    @State private var scrubbed: Date?

    private var picked: BatteryUsageSummary.HourBar? {
        guard let scrubbed else { return nil }
        return bars.min { abs($0.start.timeIntervalSince(scrubbed)) < abs($1.start.timeIntervalSince(scrubbed)) }
    }

    var body: some View {
        GlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("App CPU per hour").font(JcText.label).foregroundStyle(JcTheme.text)
                    Spacer()
                    Text(readout).font(JcText.small.monospacedDigit()).foregroundStyle(JcTheme.muted)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                Chart(bars) { bar in
                    BarMark(x: .value("Hour", bar.start, unit: .hour), y: .value("CPU", bar.onScreen))
                        .foregroundStyle(by: .value("Where", "On screen"))
                        .opacity(picked == nil || picked?.id == bar.id ? 1 : 0.4)
                    BarMark(x: .value("Hour", bar.start, unit: .hour), y: .value("CPU", bar.pocket))
                        .foregroundStyle(by: .value("Where", "Background"))
                        .opacity(picked == nil || picked?.id == bar.id ? 1 : 0.4)
                }
                .chartForegroundStyleScale(["On screen": JcTheme.accent, "Background": JcTheme.accentAlt])
                .chartLegend(.hidden)
                .chartXSelection(value: $scrubbed)
                .chartYAxis {
                    AxisMarks(position: .trailing) { value in
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                        AxisValueLabel { if let s = value.as(Double.self) { Text("\(Int(s)) s") } }
                            .foregroundStyle(Color.secondary)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisValueLabel(format: .dateTime.hour()).foregroundStyle(Color.secondary)
                    }
                }
                .frame(height: 140)
                .sensoryFeedback(.selection, trigger: picked?.id)
                HStack(spacing: 14) {
                    batteryLegend(JcTheme.accent, "On screen")
                    batteryLegend(JcTheme.accentAlt, "Background")
                }
            }
        }
    }

    private var readout: String {
        guard let picked else {
            let total = bars.reduce(0) { $0 + $1.onScreen + $1.pocket }
            return "\(BatteryUsageSummary.duration(total)) in all"
        }
        let drained = picked.drained.map { String(format: " · −%.0f%%", $0) } ?? ""
        return "\(picked.start.formatted(date: .omitted, time: .shortened)) · \(Int(picked.onScreen)) s on screen · "
            + "\(Int(picked.pocket)) s background\(drained)"
    }
}

private func batteryLegend(_ color: Color, _ title: String) -> some View {
    HStack(spacing: 6) {
        Circle().fill(color).frame(width: 8, height: 8)
        Text(title).font(JcText.small).foregroundStyle(JcTheme.muted)
    }
}

// MARK: - Breakdown

/// The rankings and the background's numbers, for a range or for one hour.
struct BatteryBreakdown: View {
    let summary: BatteryUsageSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            ranking("What used the most", note: "App CPU by where it was spent", items: summary.byPlace,
                    tint: JcTheme.accent) { "\(BatteryUsageSummary.duration($0)) CPU" }
            if !summary.byWork.isEmpty {
                ranking("Kind of work", note: "App CPU by the thread that did it", items: summary.byWork,
                        tint: JcTheme.accentAlt) { BatteryUsageSummary.duration($0) }
            }
            background
            if !summary.bluetooth.isEmpty {
                ranking("Bluetooth links", note: "Time each wearable stayed linked; a held link wakes the phone for its readings",
                        items: summary.bluetooth, tint: JcTheme.success) { BatteryUsageSummary.duration($0) }
            }
            if !summary.network.isEmpty {
                ranking("Talking to Jarvis", note: "Each one wakes the radio; on cellular that costs the most",
                        items: summary.network, tint: JcTheme.amber) { Int($0).formatted() }
            }
        }
    }

    private func ranking(_ title: String, note: String, items: [BatteryUsageSummary.Item], tint: Color,
                         value: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            GlassQuietLabel(title)
            GlassGroup {
                let shown = Array(items.prefix(10))
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                    BatteryRankRow(item: item, value: value(item.value), tint: tint, last: index == shown.count - 1)
                }
            }
            Text(note)
                .font(JcText.small)
                .foregroundStyle(JcTheme.muted)
                .padding(.top, 8)
                .padding(.horizontal, 4)
        }
    }

    private var background: some View {
        VStack(alignment: .leading, spacing: 0) {
            GlassQuietLabel("In the background")
            GlassGroup {
                BatteryStatRow(symbol: "dot.radiowaves.up.forward", title: "Kept alive",
                               value: "\(BatteryUsageSummary.duration(summary.keptAlive)) of \(BatteryUsageSummary.duration(summary.inPocket))")
                BatteryStatRow(symbol: "wifi", title: "On Wi-Fi",
                               value: Self.time(summary.seconds("bg.wifi")))
                BatteryStatRow(symbol: "cellularbars", title: "On cellular",
                               value: Self.time(summary.seconds("bg.cellular")))
                if summary.seconds("bg.offline") >= 60 {
                    BatteryStatRow(symbol: "wifi.slash", title: "Offline",
                                   value: BatteryUsageSummary.duration(summary.seconds("bg.offline")))
                }
                BatteryStatRow(symbol: "bolt.fill", title: "Charging",
                               value: Self.time(summary.seconds("charging")))
                BatteryStatRow(symbol: "battery.25percent", title: "Low Power Mode",
                               value: Self.time(summary.seconds("lowPower")))
                BatteryStatRow(symbol: "arrow.triangle.2.circlepath", title: "Live link dropped",
                               value: "\(summary.count("bridge.drop")) times")
                BatteryStatRow(symbol: "arrow.clockwise", title: "Keepalive restarted",
                               value: "\(summary.count("keepalive.restart")) times"
                                   + (summary.count("keepalive.restart_failed") > 0
                                      ? " (\(summary.count("keepalive.restart_failed")) failed)" : ""),
                               last: true)
            }
            GlassQuietLabel("Phone drain in the background")
                .padding(.top, 26)
            GlassGroup {
                drainRow("Kept alive", symbol: "dot.radiowaves.up.forward", summary.pocketDrainKeptAlive)
                drainRow("Suspended", symbol: "moon.zzz.fill", summary.pocketDrainSuspended)
                drainRow("On Wi-Fi", symbol: "wifi", summary.pocketDrainWifi)
                drainRow("On cellular", symbol: "cellularbars", summary.pocketDrainCellular, last: true)
            }
            Text("The whole phone's drain per hour, from hours spent almost all in the background that "
               + "way — the numbers that decide whether the keepalive is worth it. Each needs a few such hours.")
                .font(JcText.small)
                .foregroundStyle(JcTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
                .padding(.horizontal, 4)
        }
    }

    private func drainRow(_ title: String, symbol: String, _ rate: Double?, last: Bool = false) -> some View {
        BatteryStatRow(symbol: symbol, title: title,
                       value: rate.map { String(format: "%.1f%% an hour", $0) } ?? "not enough hours yet", last: last)
    }

    /// A duration, or "none" rather than "0 s".
    static func time(_ seconds: Double) -> String {
        seconds < 1 ? "none" : BatteryUsageSummary.duration(seconds)
    }
}

/// A ranked row: icon, title and value, a bar against the top row, and its share of the whole.
struct BatteryRankRow: View {
    let item: BatteryUsageSummary.Item
    let value: String
    let tint: Color
    var last = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                GlassCircleIcon(symbol: item.symbol)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.title)
                            .font(JcText.body.weight(.semibold))
                            .foregroundStyle(JcTheme.text)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text(value)
                            .font(.system(size: 14, weight: .semibold).monospacedDigit())
                            .foregroundStyle(JcTheme.text)
                    }
                    Capsule()
                        .fill(Color.white.opacity(0.06))
                        .frame(height: 5)
                        .overlay(alignment: .leading) {
                            GeometryReader { box in
                                Capsule().fill(tint).frame(width: max(5, box.size.width * item.share))
                            }
                        }
                    HStack(spacing: 8) {
                        if let detail = item.detail {
                            Text(detail).font(JcText.small).foregroundStyle(JcTheme.muted).lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        Text("\(Int((item.ofTotal * 100).rounded()))%")
                            .font(JcText.small.monospacedDigit())
                            .foregroundStyle(JcTheme.muted)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .accessibilityElement(children: .combine)
            if !last {
                Rectangle().fill(JcTheme.glassBorder).frame(height: 1).padding(.leading, 68)
            }
        }
    }
}

/// A row that reports one number.
struct BatteryStatRow: View {
    let symbol: String
    let title: String
    let value: String
    var last = false

    var body: some View {
        GlassRow(symbol: symbol, title: title, last: last) {
            Text(value)
                .font(.system(size: 14, weight: .medium).monospacedDigit())
                .foregroundStyle(JcTheme.muted)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
    }
}

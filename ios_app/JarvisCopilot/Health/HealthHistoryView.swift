import Charts
import SwiftUI

/// A metric's history the way Apple Health shows one: D / W / M / 6M / Y, a
/// chart you can scrub, what changed since the period before, and the
/// numbers under it.
struct HealthHistoryView: View {
    let metric: HealthMetric
    /// The Health tab, for the Day view: the card for the day it has open.
    @ObservedObject var tab: HealthTabModel
    let selection: HealthSelection

    @StateObject private var model: HealthHistoryModel
    @State private var range: HealthRange = .week
    @State private var scrubbed: Date?
    /// Seen once: the chart has drawn in and the headline has rolled up.
    @State private var revealed = false

    init(metric: HealthMetric, tab: HealthTabModel, selection: HealthSelection, model: HealthHistoryModel? = nil,
         initialRange: HealthRange = .week) {
        self.metric = metric
        self.tab = tab
        self.selection = selection
        _model = StateObject(wrappedValue: model ?? HealthHistoryModel(metric: metric))
        _range = State(initialValue: initialRange)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Picker("Range", selection: $range) {
                    ForEach(HealthRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)

                if range == .day {
                    dayView
                } else if let history = model.histories[range] {
                    content(history)
                } else if let error = model.error {
                    CardGroup {
                        Row { Text(error).font(.subheadline).foregroundStyle(.orange) }
                        RowDivider()
                        Row { Button("Try again") { Task { await model.load(range) } } }
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 240)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .navigationTitle(metric.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.isLoading {
                ToolbarItem(placement: .topBarTrailing) { ProgressView().controlSize(.small) }
            }
        }
        .task(id: range) {
            scrubbed = nil
            await model.load(range)
        }
        .sensoryFeedback(.selection, trigger: scrubbedBucket?.id)
    }

    // MARK: Day

    @ViewBuilder private var dayView: some View {
        switch metric {
        case .battery:
            BatteryCard(battery: tab.battery(for: selection), analysis: nil,
                        lastRefreshed: tab.loadedAt[selection.cacheKey], isRefreshing: tab.isRefreshing,
                        onRefresh: { Task { await tab.refresh(selection) } })
        case .sleepDebt:
            if let debt = tab.sleepDebt(for: selection) { SleepDebtCard(debt: debt) }
        default:
            RingStatsSections(store: tab.cache, dayKey: selection.cacheKey, capabilities: RingCapabilities(),
                              hourDomain: tab.hourDomain(for: selection), only: metric)
        }
    }

    // MARK: Range

    private func content(_ history: HealthHistory) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            headline(history)
                .padding(.horizontal, 24)
            CardGroup {
                if history.isEmpty {
                    Row(minHeight: 180) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("No \(metric.inSentence) recorded in this range")
                                .font(.subheadline)
                            Text("Jarvis Health has \(history.daysSoFar) day\(history.daysSoFar == 1 ? "" : "s") so far.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    chart(history)
                        .padding(14)
                }
            }
            CardGroup("Highlights") {
                Row {
                    HStack(alignment: .top, spacing: 12) {
                        RingMetricSymbol(name: metric.symbol, tint: metric.tint, size: 15)
                            .padding(.top, 2)
                        Text(history.highlight)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                }
            }
            stats(history)
        }
        .onScrolledIntoView { if !revealed { revealed = true } }
    }

    // MARK: Headline

    private var scrubbedBucket: HealthHistory.Bucket? {
        guard let scrubbed, let history = model.histories[range] else { return nil }
        return history.buckets.first { bucket in
            bucket.days > 0 && scrubbed >= bucket.startDate
                && scrubbed < Calendar.current.date(byAdding: .day, value: 1, to: bucket.endDate)!
        }
    }

    private func headline(_ history: HealthHistory) -> some View {
        let bucket = scrubbedBucket
        let label = bucket.map(span) ?? history.headline.label
        let value = bucket.map { value(of: $0, kind: history.kind) } ?? headlineValue(history)
        return VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption.weight(.semibold))
                .kerning(0.4)
                .foregroundStyle(bucket == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(JcTheme.accent))
            Text(revealed ? value : value.odometerZero)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.2), value: value)
                .animation(.odometer, value: revealed)
            Text(bucket.map { "\($0.days) day\($0.days == 1 ? "" : "s") measured" } ?? rangeSpan(history))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .animation(nil, value: bucket?.id)
    }

    private func headlineValue(_ history: HealthHistory) -> String {
        let h = history.headline
        if metric.style == .range, let text = HealthFormat.range(h.low, h.high ?? h.value, kind: h.kind) { return text }
        return HealthFormat.string(h.value, kind: h.kind)
    }

    private func value(of bucket: HealthHistory.Bucket, kind: String) -> String {
        if metric.style == .range, let text = HealthFormat.range(bucket.low, bucket.high ?? bucket.value, kind: kind) {
            return text
        }
        return HealthFormat.string(bucket.value, kind: kind)
    }

    /// What one bar covers: a day, a week, a month.
    private func span(_ bucket: HealthHistory.Bucket) -> String {
        switch range {
        case .halfYear: return "Week of " + bucket.startDate.formatted(.dateTime.month(.abbreviated).day())
        case .year: return bucket.startDate.formatted(.dateTime.month(.wide).year())
        default: return bucket.startDate.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        }
    }

    private func rangeSpan(_ history: HealthHistory) -> String {
        guard let first = RingDates.date(forKey: history.start), let last = RingDates.date(forKey: history.end) else {
            return ""
        }
        let style = Date.FormatStyle.dateTime.month(.abbreviated).day()
        return range == .year
            ? "\(first.formatted(.dateTime.month(.abbreviated).year())) – \(last.formatted(.dateTime.month(.abbreviated).year()))"
            : "\(first.formatted(style)) – \(last.formatted(style))"
    }

    // MARK: Chart

    private func chart(_ history: HealthHistory) -> some View {
        let picked = scrubbedBucket
        return Chart {
            ForEach(history.buckets.filter { $0.days > 0 }) { bucket in
                marks(bucket, dimmed: picked != nil && picked?.id != bucket.id)
            }
            if let picked {
                RuleMark(x: .value("When", picked.startDate, unit: range.unit))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .chartXScale(domain: xDomain(history))
        .chartForegroundStyleScale(["Deep": JcTheme.primaryBlue, "Light": JcTheme.accent,
                                    "REM": JcTheme.accentAlt, "Awake": Color.orange])
        .chartLegend(metric == .sleep ? .visible : .hidden)
        .chartXAxis { xAxis }
        .chartYAxis {
            AxisMarks(position: .trailing) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                AxisValueLabel { Text(yLabel(value.as(Double.self) ?? 0)) }
            }
        }
        .chartYScale(domain: .automatic(includesZero: metric.style != .line && metric.style != .range))
        .chartXSelection(value: $scrubbed)
        .frame(height: 220)
        // Room around the plot so the axis labels at its edges are not cut.
        .mask(alignment: .leading) {
            Rectangle().padding(-16).scaleEffect(x: revealed ? 1 : 0.001, anchor: .leading)
        }
        .animation(.easeOut(duration: 0.8), value: revealed)
        .animation(.snappy(duration: 0.3), value: range)
    }

    @ChartContentBuilder
    private func marks(_ bucket: HealthHistory.Bucket, dimmed: Bool) -> some ChartContent {
        let x = PlottableValue.value("When", bucket.startDate, unit: range.unit)
        let fade = dimmed ? 0.35 : 1.0
        switch metric.style {
        case .bars:
            BarMark(x: x, y: .value(metric.title, plotted(bucket.value)))
                .foregroundStyle(metric.tint.gradient)
                .cornerRadius(3)
                .opacity(fade)
        case .range:
            let low = plotted(bucket.low ?? bucket.value), high = plotted(bucket.high ?? bucket.value)
            BarMark(x: x, yStart: .value("Low", low), yEnd: .value("High", max(high, low + 0.6)),
                    width: .ratio(range == .halfYear ? 0.7 : 0.42))
                .foregroundStyle(rangeTint(bucket).gradient)
                .cornerRadius(5)
                .opacity(fade)
            if metric == .heartRate, let average = bucket.value {
                PointMark(x: x, y: .value("Average", average))
                    .foregroundStyle(.white)
                    .symbolSize(14)
                    .opacity(fade)
            }
        case .stacked:
            ForEach(stages(bucket), id: \.name) { stage in
                BarMark(x: x, y: .value("Hours", stage.hours))
                    .foregroundStyle(by: .value("Stage", stage.name))
                    .opacity(fade)
            }
        case .line:
            LineMark(x: x, y: .value(metric.title, plotted(bucket.value)))
                .foregroundStyle(metric.tint)
                .interpolationMethod(.catmullRom)
            PointMark(x: x, y: .value(metric.title, plotted(bucket.value)))
                .foregroundStyle(metric.tint)
                .symbolSize(24)
                .opacity(fade)
        case .bandBars:
            BarMark(x: x, y: .value(metric.title, plotted(bucket.value)))
                .foregroundStyle(bandTint(bucket).gradient)
                .cornerRadius(3)
                .opacity(fade)
        }
    }

    /// Minutes are drawn in hours; temperatures in the chosen unit.
    private func plotted(_ value: Double?) -> Double {
        guard let value else { return 0 }
        switch metric {
        case .sleep, .sleepDebt: return value / 60
        case .temperature: return TemperatureUnit.current.value(value)
        default: return value
        }
    }

    private func stages(_ bucket: HealthHistory.Bucket) -> [(name: String, hours: Double)] {
        guard let s = bucket.stages else { return [("Light", plotted(bucket.value))] }
        return [("Deep", s.deep / 60), ("Light", s.light / 60), ("REM", s.rem / 60), ("Awake", s.awake / 60)]
    }

    private func rangeTint(_ bucket: HealthHistory.Bucket) -> Color {
        metric == .battery ? BatteryCard.tint(BatteryCard.band(for: bucket.high ?? bucket.value ?? 0)) : metric.tint
    }

    private func bandTint(_ bucket: HealthHistory.Bucket) -> Color {
        let value = bucket.value ?? 0
        if metric == .stress { return StressBand.of(value).color }
        let band = value >= 600 ? "High" : value >= 300 ? "Medium" : value >= 60 ? "Low" : "None"
        return SleepDebtCard.tint(band)
    }

    private func yLabel(_ value: Double) -> String {
        switch metric {
        case .sleep, .sleepDebt: return "\(Int(value.rounded()))h"
        case .steps: return value >= 1000 ? "\(Int((value / 1000).rounded()))k" : "\(Int(value))"
        case .temperature: return String(format: "%.1f", value)
        default: return "\(Int(value.rounded()))"
        }
    }

    private func xDomain(_ history: HealthHistory) -> ClosedRange<Date> {
        let first = history.buckets.first?.startDate ?? Date()
        let last = history.buckets.last?.endDate ?? Date()
        return first...(Calendar.current.date(byAdding: .day, value: 1, to: last) ?? last)
    }

    private var xAxis: some AxisContent {
        AxisMarks(values: axisValues) { _ in
            if range != .week { AxisGridLine().foregroundStyle(Color.primary.opacity(0.06)) }
            AxisValueLabel(format: axisFormat, centered: range == .week || range == .year)
        }
    }

    private var axisValues: AxisMarkValues {
        switch range {
        case .week: return .stride(by: .day)
        case .month: return .stride(by: .day, count: 7)
        default: return .stride(by: .month)
        }
    }

    private var axisFormat: Date.FormatStyle {
        switch range {
        case .week: return .dateTime.weekday(.narrow)
        case .month: return .dateTime.day()
        case .halfYear: return .dateTime.month(.abbreviated)
        default: return .dateTime.month(.narrow)
        }
    }

    // MARK: Stats

    private func stats(_ history: HealthHistory) -> some View {
        CardGroup("Stats") {
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading, spacing: 14) {
                ForEach(Array(history.stats.enumerated()), id: \.offset) { _, stat in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stat.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(HealthFormat.string(stat.value, kind: stat.kind))
                            .font(.system(.body, design: .rounded).weight(.semibold))
                            .monospacedDigit()
                    }
                }
            }
            .padding(16)
        }
    }
}

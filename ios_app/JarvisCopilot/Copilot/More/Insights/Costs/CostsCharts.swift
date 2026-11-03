import Charts
import SwiftUI

// MARK: - Daily spend (stacked)

/// Daily spend stacked by service: the top five in their own colours, the rest
/// as "Other". Drag across it to read a day; the legend then shows that day's
/// split, and otherwise each series' period total (which add up to the
/// headline).
struct CostsDailyChartCard: View {
    let stack: CostsStack
    let periodTotal: Double

    @State private var selected: Date?

    /// The bar under the finger: the one whose span holds it, else the nearest.
    private var picked: CostStackDay? {
        guard let selected else { return nil }
        if let hit = stack.days.first(where: { $0.date <= selected && selected < $0.end }) { return hit }
        return stack.days.min {
            abs($0.center.timeIntervalSince(selected)) < abs($1.center.timeIntervalSince(selected))
        }
    }

    /// A sliver of air either side of each bar.
    private var inset: TimeInterval { Double(stack.bucketDays) * 86_400 * 0.12 }

    private var xDomain: ClosedRange<Date> {
        let start = stack.days.first?.date ?? Date()
        return start...max(stack.days.last?.end ?? start, start.addingTimeInterval(86_400))
    }

    private var domain: [String] { stack.series.map(\.id) }
    private var range: [Color] { stack.series.map { CostsPalette.color($0.slot) } }
    private var names: [String: String] {
        Dictionary(stack.series.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        GlassCard {
            if !stack.hasSpend {
                CardEmptyBlock(symbol: "chart.bar", text: "No spend recorded in this period")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    readout
                    chart
                    legend
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var readout: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let picked {
                Text(CostsUI.money(picked.total))
                    .font(.system(size: 20, weight: .semibold).monospacedDigit())
                    .foregroundStyle(JcTheme.text)
                Text(CostsUI.barLabel(picked))
                    .font(.system(size: 12))
                    .foregroundStyle(JcTheme.muted)
            } else {
                Text(CostsUI.money(stack.averagePerBar(total: periodTotal)))
                    .font(.system(size: 20, weight: .semibold).monospacedDigit())
                    .foregroundStyle(JcTheme.text)
                Text(stack.bucketDays == 7 ? "a week on average" : "a day on average")
                    .font(.system(size: 12))
                    .foregroundStyle(JcTheme.muted)
            }
            Spacer(minLength: 0)
        }
        .animation(nil, value: picked?.day)
    }

    private var chart: some View {
        let seriesNames = names
        let pickedDay = picked?.day
        let barInset = inset
        return Chart {
            ForEach(stack.segments) { segment in
                Self.mark(segment, inset: barInset,
                          dimmed: pickedDay != nil && pickedDay != segment.day,
                          name: seriesNames[segment.seriesID] ?? segment.seriesID)
            }
            if let picked {
                CostScrubRule(date: picked.center)
            }
        }
        .chartForegroundStyleScale(domain: domain, range: range)
        .chartLegend(.hidden)
        .chartXScale(domain: xDomain)
        .chartXSelection(value: $selected)
        .chartXAxis { CostsChartStyle.dateAxis() }
        .chartYAxis { CostsChartStyle.moneyAxis() }
        .frame(height: 180)
        .sensoryFeedback(.selection, trigger: picked?.day)
        .accessibilityHint("Drag across the chart to read each day's spend")
    }

    private static func mark(_ segment: CostStackSegment, inset: TimeInterval, dimmed: Bool,
                             name: String) -> some ChartContent {
        let start: Date = segment.date.addingTimeInterval(inset)
        let end: Date = segment.end.addingTimeInterval(-inset)
        let label: String = CostsUI.barLabel(day: segment.day, lastDay: segment.lastDay)
        let value: String = name + ", " + CostsUI.money(segment.amount)
        return RectangleMark(xStart: .value("Day", start), xEnd: .value("Day", end),
                       yStart: .value("USD", segment.low), yEnd: .value("USD", segment.high))
            .foregroundStyle(by: .value("Service", segment.seriesID))
            .opacity(dimmed ? 0.35 : 1)
            .accessibilityLabel(label)
            .accessibilityValue(value)
    }

    private var legend: some View {
        JcWrap(spacing: 14, runSpacing: 8) {
            ForEach(stack.series) { series in
                let amount = picked.map { $0.parts[series.id] ?? 0 } ?? series.total
                CostLegendItem(color: CostsPalette.color(series.slot), label: series.name,
                               value: CostsUI.money(amount))
            }
        }
    }
}

// MARK: - One service's days

/// A service's effective spend per day (per week on long windows). For a
/// pay-as-you-go service that has both a provider bill and Jarvis's own
/// estimate, the estimate rides on top as a line so the two can be compared.
struct CostDetailChart: View {
    let bars: [CostDetailBar]
    let color: Color
    let compare: Bool

    @State private var selected: Date?

    private var weekly: Bool { bars.contains { $0.day != $0.lastDay } }

    /// The bar under the finger: the one whose span holds it, else the nearest.
    private var picked: CostDetailBar? {
        guard let selected else { return nil }
        if let hit = bars.first(where: { $0.date <= selected && selected < $0.end }) { return hit }
        return bars.min {
            abs($0.center.timeIntervalSince(selected)) < abs($1.center.timeIntervalSince(selected))
        }
    }

    private var inset: TimeInterval { (weekly ? 7.0 : 1.0) * 86_400 * 0.12 }

    private var xDomain: ClosedRange<Date> {
        let start = bars.first?.date ?? Date()
        return start...max(bars.last?.end ?? start, start.addingTimeInterval(86_400))
    }

    private static let estimateColor = JcTheme.text.opacity(0.75)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(readout)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(picked == nil ? JcTheme.muted : JcTheme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 0)
            }
            let pickedID = picked?.id
            let barInset = inset
            Chart {
                ForEach(bars) { bar in
                    Self.mark(bar, inset: barInset, color: color,
                              dimmed: pickedID != nil && pickedID != bar.id)
                }
                if compare {
                    ForEach(bars.filter { $0.estimate != nil }) { bar in
                        LineMark(x: .value("Day", bar.center),
                                 y: .value("Estimate", bar.estimate ?? 0),
                                 series: .value("Series", "estimate"))
                            .foregroundStyle(Self.estimateColor)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                            .accessibilityHidden(true)
                        PointMark(x: .value("Day", bar.center),
                                  y: .value("Estimate", bar.estimate ?? 0))
                            .foregroundStyle(Self.estimateColor)
                            .symbolSize(14)
                            .accessibilityHidden(true)
                    }
                }
                if let picked {
                    CostScrubRule(date: picked.center)
                }
            }
            .chartXScale(domain: xDomain)
            .chartXSelection(value: $selected)
            .chartXAxis { CostsChartStyle.dateAxis() }
            .chartYAxis { CostsChartStyle.moneyAxis() }
            .frame(height: 150)
            .sensoryFeedback(.selection, trigger: picked?.id)
            .accessibilityHint(weekly ? "Drag across the chart to read each week" : "Drag across the chart to read each day")
            if compare {
                HStack(spacing: 16) {
                    CostLegendItem(color: color, label: "Billed", value: nil)
                    CostLegendItem(color: Self.estimateColor, label: "Jarvis estimate", value: nil)
                }
            }
        }
    }

    private static func mark(_ bar: CostDetailBar, inset: TimeInterval, color: Color,
                             dimmed: Bool) -> some ChartContent {
        let start: Date = bar.date.addingTimeInterval(inset)
        let end: Date = bar.end.addingTimeInterval(-inset)
        let zero: Double = 0
        return RectangleMark(xStart: .value("Day", start), xEnd: .value("Day", end),
                       yStart: .value("USD", zero), yEnd: .value("USD", bar.effective))
            .foregroundStyle(color)
            .opacity(dimmed ? 0.35 : 1)
            .cornerRadius(2)
            .accessibilityLabel(CostsUI.barLabel(day: bar.day, lastDay: bar.lastDay))
            .accessibilityValue(CostsUI.detailAccessibilityValue(bar))
    }

    private var readout: String {
        if let picked { return CostsUI.detailReadout(picked) }
        let total = bars.reduce(0) { $0 + $1.effective }
        let estimated = !bars.isEmpty && bars.allSatisfy { $0.onlyEstimated || $0.effective == 0 }
            && bars.contains(where: \.onlyEstimated)
        let first = bars.first?.day ?? ""
        let last = bars.last?.lastDay ?? ""
        let span = CostsUI.periodLabel(start: first, end: last)
        return "\(CostsUI.money(total, estimated: estimated)) · \(span)" + (weekly ? " · by week" : "")
    }
}

/// The dashed line under the finger, centred on the touched bar.
struct CostScrubRule: ChartContent {
    let date: Date

    var body: some ChartContent {
        RuleMark(x: .value("Selected", date))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            .foregroundStyle(.white.opacity(0.55))
            .accessibilityHidden(true)
    }
}

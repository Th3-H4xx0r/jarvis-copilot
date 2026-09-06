import Charts
import SwiftUI

// MARK: - Daily tokens

/// Daily input/output tokens as a stacked bar chart.
///
/// The Flutter page hand-rolled proportional bars because Flutter has no chart
/// in the box; Swift Charts is a system framework, so this is the real thing —
/// same data, same colours (input blue, output violet), with an axis.
struct InsightsDailyTokensCard: View {
    let bars: [InsightsDailyBar]

    var body: some View {
        GlassCard {
            if !InsightsUI.hasUsage(bars) {
                InsightsEmptyBlock(symbol: "chart.bar", text: "No token usage recorded.")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Chart {
                        ForEach(bars) { bar in
                            BarMark(x: .value("Day", bar.label),
                                    y: .value("Tokens", bar.input))
                                .foregroundStyle(by: .value("Kind", "Input"))
                            BarMark(x: .value("Day", bar.label),
                                    y: .value("Tokens", bar.output))
                                .foregroundStyle(by: .value("Kind", "Output"))
                        }
                    }
                    .chartForegroundStyleScale(["Input": JcTheme.primaryBlue,
                                                "Output": JcTheme.accent])
                    .chartLegend(.hidden)
                    .chartXAxis { InsightsChartStyle.categoryAxis(bars.map(\.label)) }
                    .chartYAxis { InsightsChartStyle.compactValueAxis() }
                    .frame(height: 170)
                    InsightsChartLegend(items: [("Input", JcTheme.primaryBlue),
                                                ("Output", JcTheme.accent)])
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Activity

/// When the assistant actually gets used: sessions by hour of day (a filled
/// line, because the hours are a continuum) and by weekday (bars).
struct InsightsActivityCard: View {
    let hours: [InsightsHourBar]
    let days: [InsightsDayBar]

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 18) {
                if !hours.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("BY HOUR")
                            .font(.system(size: 9.5, weight: .semibold)).kerning(0.5)
                            .foregroundStyle(JcTheme.muted)
                        Chart(hours) { bar in
                            AreaMark(x: .value("Hour", bar.hour),
                                     y: .value("Sessions", bar.sessions))
                                .foregroundStyle(LinearGradient(
                                    colors: [JcTheme.cyan.opacity(0.35), JcTheme.cyan.opacity(0.02)],
                                    startPoint: .top, endPoint: .bottom))
                                .interpolationMethod(.monotone)
                            LineMark(x: .value("Hour", bar.hour),
                                     y: .value("Sessions", bar.sessions))
                                .foregroundStyle(JcTheme.cyan)
                                .interpolationMethod(.monotone)
                        }
                        .chartXAxis {
                            AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                                AxisValueLabel {
                                    Text(String(format: "%02d", value.as(Int.self) ?? 0))
                                        .font(.system(size: 10))
                                        .foregroundStyle(JcTheme.muted)
                                }
                                AxisGridLine().foregroundStyle(JcTheme.glassBorder)
                            }
                        }
                        .chartYAxis { InsightsChartStyle.compactValueAxis() }
                        .frame(height: 120)
                    }
                }
                if !days.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("BY WEEKDAY")
                            .font(.system(size: 9.5, weight: .semibold)).kerning(0.5)
                            .foregroundStyle(JcTheme.muted)
                        Chart(days) { bar in
                            BarMark(x: .value("Day", bar.day),
                                    y: .value("Sessions", bar.sessions))
                                .foregroundStyle(JcTheme.accentAlt)
                                .cornerRadius(4)
                        }
                        .chartXAxis { InsightsChartStyle.categoryAxis(days.map(\.day)) }
                        .chartYAxis { InsightsChartStyle.compactValueAxis() }
                        .frame(height: 110)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Axis styling shared by the Insights charts — dark chrome, muted labels, and
/// a stride that keeps a 30-bucket axis from turning into a smear.
enum InsightsChartStyle {
    /// Label only every ceil(n/6)-th category, so 7 days and 30 days both read.
    static func thinnedLabels(_ labels: [String]) -> [String] {
        let step = max(1, Int((Double(labels.count) / 6).rounded(.up)))
        return labels.enumerated().compactMap { $0.offset % step == 0 ? $0.element : nil }
    }

    static func categoryAxis(_ labels: [String]) -> some AxisContent {
        AxisMarks(preset: .aligned, values: thinnedLabels(labels)) { _ in
            AxisValueLabel()
                .font(.system(size: 9.5))
                .foregroundStyle(JcTheme.muted)
        }
    }

    static func compactValueAxis() -> some AxisContent {
        AxisMarks(position: .leading) { value in
            AxisGridLine().foregroundStyle(JcTheme.glassBorder)
            AxisValueLabel {
                Text(Insights.formatTokensCompact(value.as(Double.self) ?? 0))
                    .font(.system(size: 9.5))
                    .foregroundStyle(JcTheme.muted)
            }
        }
    }
}

/// A row of colour-chip captions under a chart.
struct InsightsChartLegend: View {
    let items: [(label: String, color: Color)]

    var body: some View {
        HStack(spacing: 16) {
            ForEach(items, id: \.label) { item in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(item.color)
                        .frame(width: 10, height: 10)
                    Text(item.label).font(.system(size: 11)).foregroundStyle(JcTheme.muted)
                }
            }
        }
    }
}

// MARK: - Messages (this conversation)

/// Per-message rows for the active conversation: # / Input / Output / Total,
/// each with the input-composition colour bar. Tapping a row opens the same
/// breakdown the web panel's `showMsgComposition` modal shows.
struct InsightsMessagesCard: View {
    let messages: [MessageUsage]

    @State private var selected: MessageUsage?

    var body: some View {
        GlassCard {
            if messages.isEmpty {
                InsightsEmptyBlock(symbol: "bubble.left", text: "No messages recorded yet.")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    Rectangle().fill(JcTheme.glassBorder).frame(height: 1)
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        if index > 0 {
                            Rectangle().fill(JcTheme.glassBorder).frame(height: 1)
                        }
                        Button { selected = message } label: {
                            InsightsMessageRow(message: message)
                        }
                        .buttonStyle(.plain)
                    }
                    Text("Input composition is estimated (~chars ÷ 4); in/out totals are exact.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(JcTheme.muted.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                }
            }
        }
        .sheet(item: $selected) { InsightsCompositionSheet(message: $0) }
    }

    private var header: some View {
        HStack(spacing: 0) {
            caption("#").frame(width: 34, alignment: .leading)
            caption("INPUT").frame(maxWidth: .infinity, alignment: .trailing)
            caption("OUTPUT").frame(maxWidth: .infinity, alignment: .trailing)
            caption("TOTAL").frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .bold))
            .kerning(0.4)
            .foregroundStyle(JcTheme.muted)
    }
}

struct InsightsMessageRow: View {
    let message: MessageUsage

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 0) {
                Text("#\(message.turn)")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(JcTheme.text)
                    .frame(width: 34, alignment: .leading)
                HStack(spacing: 2) {
                    Spacer(minLength: 0)
                    // A cache hit is why an "expensive" turn was cheap — worth a
                    // glyph, as the web panel does.
                    if message.cacheReadTokens > 0 {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(JcTheme.cyan)
                    }
                    Text(Insights.formatTokensCompact(message.inputTokens))
                        .font(.system(size: 12.5))
                        .foregroundStyle(JcTheme.text)
                }
                .frame(maxWidth: .infinity)
                Text(Insights.formatTokensCompact(message.outputTokens))
                    .font(.system(size: 12.5))
                    .foregroundStyle(JcTheme.text)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Text(Insights.formatTokensCompact(message.inputTokens + message.outputTokens))
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(JcTheme.text)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            let slices = InsightsUI.compositionSlices(message.composition)
            if !slices.isEmpty {
                InsightsCompositionBar(slices: slices)
            }
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}

/// A 6pt stacked bar of the input-composition sections, largest first.
struct InsightsCompositionBar: View {
    let slices: [InsightsCompositionSlice]

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(slices) { slice in
                    Color(jcHex: slice.colorHex)
                        .frame(width: max(1, geo.size.width * slice.percent / 100))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 6)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

/// The tap-through composition sheet: totals, then per-section tokens and share.
struct InsightsCompositionSheet: View {
    let message: MessageUsage

    private var slices: [InsightsCompositionSlice] {
        InsightsUI.compositionSlices(message.composition)
    }

    var body: some View {
        DetailSheet(title: "Composition — #\(message.turn)") {
            VStack(alignment: .leading, spacing: 14) {
                JcWrap(spacing: 16, runSpacing: 6) {
                    total("Input", message.inputTokens)
                    total("Output", message.outputTokens)
                    if message.cacheReadTokens > 0 { total("Cache hit", message.cacheReadTokens) }
                    if message.reasoningTokens > 0 { total("Reasoning", message.reasoningTokens) }
                    if message.latencySeconds > 0 {
                        Text(String(format: "%.1fs", message.latencySeconds))
                            .font(.system(size: 12.5)).foregroundStyle(JcTheme.muted)
                    }
                    if !message.model.isEmpty {
                        Text(message.model)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(JcTheme.cyan)
                    }
                }
                Text("Input composition is estimated (~chars ÷ 4); the in/out totals "
                   + "are exact from the API.")
                    .font(.system(size: 11))
                    .foregroundStyle(JcTheme.muted.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                if slices.isEmpty {
                    Text("No composition data for this message.")
                        .font(JcText.body)
                        .foregroundStyle(JcTheme.muted)
                        .padding(.vertical, 24)
                } else {
                    ForEach(slices) { slice in
                        InsightsCompositionRow(slice: slice)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func total(_ label: String, _ value: Int) -> some View {
        (Text("\(label): ").font(.system(size: 12.5)).foregroundColor(JcTheme.muted)
         + Text(Insights.formatTokenCount(value))
            .font(.system(size: 12.5, weight: .bold)).foregroundColor(JcTheme.text))
    }
}

/// One section row in the composition sheet: dot + label + tokens/% + bar.
struct InsightsCompositionRow: View {
    let slice: InsightsCompositionSlice

    var body: some View {
        let tint = Color(jcHex: slice.colorHex)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(tint)
                    .frame(width: 9, height: 9)
                Text(slice.label)
                    .font(.system(size: 13.5))
                    .foregroundStyle(JcTheme.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("\(Insights.formatTokenCount(slice.tokens))  (\(String(format: "%.1f", slice.percent))%)")
                    .font(.system(size: 12))
                    .foregroundStyle(JcTheme.muted)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(JcTheme.glassFill)
                    Rectangle().fill(tint)
                        .frame(width: max(1, geo.size.width * slice.percent / 100))
                }
            }
            .frame(height: 6)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        }
        .padding(.vertical, 7)
    }
}

import Charts
import SwiftUI
import UIKit

// MARK: - Palette

/// Series colours for the Costs tab, all derived from `JcAccent`: the accent
/// itself, then the accent's hue rotated to well-separated angles at the same
/// strength, so neighbouring bars never match and a new accent re-colours the
/// chart with everything else. "Other" is a neutral grey.
enum CostsPalette {
    /// Degrees around the colour wheel from the accent's hue, in rank order:
    /// each neighbour sits far from the one before it (and red, which means
    /// "error" on this screen, is avoided for the default accent, as is the
    /// amber that means "waiting on you").
    static let hueOffsets: [Double] = [0, 150, 75, 205, 290]

    static let colors: [Color] = hueOffsets.map(rotated)
    static let other = JcTheme.muted.opacity(0.6)

    /// A slot from `CostsStack`; nil or `CostsUI.otherSlot` → Other's grey.
    static func color(_ slot: Int?) -> Color {
        guard let slot, slot >= 0 else { return other }
        return colors[slot % colors.count]
    }

    private static func rotated(_ degrees: Double) -> Color {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(JcAccent.color).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        var hue = (Double(h) + degrees / 360).truncatingRemainder(dividingBy: 1)
        if hue < 0 { hue += 1 }
        return Color(hue: hue, saturation: max(Double(s), 0.5), brightness: max(Double(b), 0.85))
    }
}

// MARK: - Segmented pill

/// A segmented control for any set of options (the Usage | Costs tabs, the
/// period, Monthly | Yearly).
struct InsightsSegmentedPill<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    let selection: Value
    var compact = false
    let onChange: (Value) -> Void

    private struct Option: Hashable, Identifiable {
        let value: Value
        let label: String
        var id: Value { value }
    }

    /// The app's one in-page filter, `JcSegmented`; this only adapts the
    /// value + callback shape the Insights screens use.
    var body: some View {
        let items = options.map { Option(value: $0.value, label: $0.label) }
        if let current = items.first(where: { $0.value == selection }) ?? items.first {
            JcSegmented(items: items,
                        selection: Binding(get: { current }, set: { onChange($0.value) }),
                        label: \.label,
                        scrolls: false)
        }
    }
}

// MARK: - Small pieces

/// A tiny trend line for a service row. Draws nothing for an all-zero series.
struct CostSparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        if values.contains(where: { $0 > 0 }) {
            Chart(Array(values.enumerated()), id: \.offset) { point in
                AreaMark(x: .value("Day", point.offset), y: .value("USD", point.element))
                    .foregroundStyle(LinearGradient(colors: [color.opacity(0.18), color.opacity(0.0)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Day", point.offset), y: .value("USD", point.element))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .chartYScale(domain: 0...max(values.max() ?? 1, 0.0001))
            .accessibilityHidden(true)
        } else {
            Color.clear
        }
    }
}

/// A key/value stat beneath a headline number: small caption over a value.
struct CostMiniStat: View {
    let label: String
    let value: String
    var tint: Color = JcTheme.text

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(JcText.small)
                .foregroundStyle(JcTheme.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value)
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A soft capsule label — balance, "Saved", plan chips.
struct CostChip: View {
    let text: String
    var tint: Color = JcTheme.text
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { JcIcon(symbol, size: 10) }
            Text(text).font(.system(size: 11, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(0.12), in: Capsule())
    }
}

/// One colour-chip legend entry that can carry an amount.
struct CostLegendItem: View {
    let color: Color
    let label: String
    let value: String?

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(color)
                .frame(width: 10, height: 10)
            Text(label).font(.system(size: 11.5)).foregroundStyle(JcTheme.muted).lineLimit(1)
            if let value {
                Text(value)
                    .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(JcTheme.text)
                    .lineLimit(1)
            }
        }
    }
}

/// An inline error or confirmation under a form.
struct CostFormNote: View {
    let error: String?
    let note: String?

    var body: some View {
        if let error {
            HStack(alignment: .top, spacing: 6) {
                JcIcon("exclamationmark.triangle.fill", size: 11).foregroundStyle(JcTheme.danger)
                Text(error).font(JcText.small).foregroundStyle(JcTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if let note {
            HStack(spacing: 6) {
                JcIcon("checkmark", size: 11).foregroundStyle(JcTheme.success)
                Text(note).font(JcText.small).foregroundStyle(JcTheme.muted)
            }
        }
    }
}

/// A "$ 20.00" amount field.
struct CostAmountField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Text("$").font(JcText.body.weight(.semibold)).foregroundStyle(JcTheme.muted)
            TextField(placeholder, text: $text)
                .keyboardType(.decimalPad)
                .textFieldStyle(.plain)
                .font(JcText.body.monospacedDigit())
                .foregroundStyle(JcTheme.text)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(JcTheme.glassFill, in: RoundedRectangle(cornerRadius: JcTheme.fieldRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: JcTheme.fieldRadius, style: .continuous)
            .strokeBorder(JcTheme.glassBorder, lineWidth: 1))
    }
}

enum CostsChartStyle {
    /// A time axis labelled "Oct 3", about five times across.
    static func dateAxis() -> some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 5)) { _ in
            AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                .font(.system(size: 9.5))
                .foregroundStyle(JcTheme.muted)
        }
    }

    static func moneyAxis() -> some AxisContent {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
            AxisGridLine().foregroundStyle(JcTheme.glassBorder)
            AxisValueLabel {
                Text(CostsUI.axisMoney(value.as(Double.self) ?? 0))
                    .font(.system(size: 9.5))
                    .foregroundStyle(JcTheme.muted)
            }
        }
    }
}

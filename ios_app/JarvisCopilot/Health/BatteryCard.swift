import Charts
import SwiftUI

/// The Body Battery: where it stands, how it moved, and what moved it.
///
/// A reservoir, not a grade: sleep charged it, the waking day drained it. The
/// curve is the point of the card — the steepest stretch is shaded so "what
/// took it" is visible before anything is read.
struct BatteryCard: View {
    let battery: HealthBattery?
    let analysis: String?
    let lastRefreshed: Date?
    let isRefreshing: Bool
    var error: String? = nil
    let onRefresh: () -> Void

    var body: some View {
        CardGroup(HealthScores.batteryName) {
            if let battery, let level = battery.level {
                Row(minHeight: 108) {
                    VStack(alignment: .leading, spacing: 18) {
                        headline(level: level, battery: battery)
                        if battery.curve.count > 1 { curve(battery) }
                        parts(battery)
                    }
                    .padding(.vertical, 6)
                }
                if let analysis, !analysis.isEmpty {
                    RowDivider()
                    Row {
                        Text(analysis)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 6)
                    }
                }
                RowDivider()
                footer(note: note(battery))
            } else {
                Row(minHeight: 84) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(isRefreshing ? "Charting your battery…" : "No battery yet")
                                .foregroundStyle(.secondary)
                            Text("It starts from a night of sleep on a linked wearable.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 12)
                        refreshButton
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    // MARK: Pieces

    private func headline(level: Double, battery: HealthBattery) -> some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.12), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: CGFloat(level / 100))
                    .stroke(Self.tint(battery.band), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 54, height: 54)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Int(level.rounded()))")
                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(battery.band)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Body battery \(Int(level.rounded())), \(battery.band)")
    }

    private func curve(_ battery: HealthBattery) -> some View {
        let tint = Self.tint(battery.band)
        return Chart {
            if let drain = battery.biggestDrain {
                RectangleMark(xStart: .value("From", drain.start), xEnd: .value("To", drain.end))
                    .foregroundStyle(JcTheme.danger.opacity(0.16))
            }
            ForEach(battery.curve, id: \.at) { point in
                AreaMark(x: .value("Time", point.at), y: .value("Level", point.level))
                    .foregroundStyle(LinearGradient(colors: [tint.opacity(0.32), tint.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", point.at), y: .value("Level", point.level))
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
        }
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(position: .trailing, values: [0, 50, 100]) { _ in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                AxisValueLabel().foregroundStyle(Color.secondary)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: .dateTime.hour())
                    .foregroundStyle(Color.secondary)
            }
        }
        .frame(height: 118)
        .accessibilityHidden(true)
    }

    /// Four figures, whichever this battery has: a day's charge and drains, or
    /// the window's level at wake and what it has lost since.
    private func parts(_ battery: HealthBattery) -> some View {
        var items: [(String, String, Color?)] = []
        if let charged = battery.charged { items.append(("Charged", "+\(Int(charged.rounded()))", Self.tint("High"))) }
        if let factor = battery.recoveryFactor { items.append(("Recovery", "\(Int((factor * 100).rounded()))%", nil)) }
        if let stress = battery.drains?["stress"] { items.append(("Stress", "−\(Int(stress.rounded()))", nil)) }
        if let activity = battery.drains?["activity"] { items.append(("Activity", "−\(Int(activity.rounded()))", nil)) }
        if battery.charged == nil {
            if let wake = battery.wakeLevel { items.append(("At wake", "\(Int(wake.rounded()))", nil)) }
            if let drained = battery.drained { items.append(("Drained", "−\(Int(drained.rounded()))", nil)) }
            if let steepest = battery.biggestDrain {
                items.append(("Steepest", "−\(String(format: "%.1f", steepest.points))", JcTheme.danger))
            }
        }
        return HStack(alignment: .top, spacing: 12) {
            ForEach(Array(items.prefix(4).enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.0.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(item.1)
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(item.2 ?? .primary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func footer(note: String?) -> some View {
        Row {
            HStack {
                Text(error ?? note ?? updatedText)
                    .font(.caption)
                    .foregroundStyle(error == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.orange))
                    .lineLimit(2)
                Spacer(minLength: 12)
                refreshButton
            }
        }
    }

    /// The one caveat worth saying, when there is one.
    private func note(_ battery: HealthBattery) -> String? {
        if battery.noSleep == true { return "No sleep recorded, so nothing charged." }
        if let calibrating = battery.calibrating {
            return "Calibrating · \(calibrating.nights) of \(calibrating.needed) nights"
        }
        if battery.partial == true { return "Part of the day wasn't measured." }
        return nil
    }

    private var refreshButton: some View {
        Button(action: onRefresh) {
            if isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .semibold))
            }
        }
        .buttonStyle(.bordered)
        .tint(JcTheme.accent)
        .controlSize(.small)
        .disabled(isRefreshing)
        .accessibilityLabel("Chart the battery again")
        .sensoryFeedback(.success, trigger: lastRefreshed)
    }

    private var updatedText: String {
        if isRefreshing { return "Reading your wearables…" }
        guard let lastRefreshed else { return "Not read yet" }
        let seconds = Date().timeIntervalSince(lastRefreshed)
        if seconds < 90 { return "Updated just now" }
        if seconds < 3600 { return "Updated \(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "Updated \(Int(seconds / 3600))h ago" }
        return "Updated \(Int(seconds / 86_400))d ago"
    }

    /// Band colours from the app's own tokens — never a per-file literal.
    static func tint(_ band: String) -> Color {
        switch band {
        case "High": return JcTheme.accent
        case "Medium": return JcTheme.blue
        case "Low": return JcTheme.amber
        case "Very low": return JcTheme.danger
        default: return .secondary
        }
    }
}

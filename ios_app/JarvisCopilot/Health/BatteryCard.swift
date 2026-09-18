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

    /// Where a finger is on the curve: the card reads the level there.
    @State private var scrubbed: Date?
    /// Seen at least once: the ring has filled and the curve has drawn in.
    @State private var revealed = false

    var body: some View {
        CardGroup(HealthScores.batteryName) {
            if let battery, let level = battery.level {
                Row(minHeight: 108) {
                    let picked = scrubbed.flatMap { Self.point(near: $0, in: battery.curve) }
                    VStack(alignment: .leading, spacing: 18) {
                        headline(level: level, battery: battery, picked: picked)
                        if battery.curve.count > 1 { curve(battery, picked: picked) }
                        parts(battery)
                    }
                    .sensoryFeedback(.selection, trigger: picked?.at)
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
        .onScrolledIntoView { if !revealed { revealed = true } }
        .scrollReveal()
    }

    // MARK: Pieces

    /// The level and its ring — now, or wherever a finger is on the curve.
    private func headline(level: Double, battery: HealthBattery, picked: HealthCurvePoint?) -> some View {
        BatteryGauge(level: revealed ? (picked?.level ?? level) : 0,
                     band: picked.map { Self.band(for: $0.level) } ?? battery.band,
                     caption: picked.map { caption($0, battery) } ?? battery.band,
                     highlighted: picked != nil)
    }

    /// "3:30 AM · asleep", or the time and that level's band.
    private func caption(_ point: HealthCurvePoint, _ battery: HealthBattery) -> String {
        let time = point.at.formatted(date: .omitted, time: .shortened)
        if let bed = battery.bedAt, let wake = battery.wakeAt, point.at > bed, point.at <= wake.addingTimeInterval(1800) {
            return "\(time) · asleep"
        }
        return "\(time) · \(Self.band(for: point.level))"
    }

    static func point(near date: Date, in curve: [HealthCurvePoint]) -> HealthCurvePoint? {
        curve.min { abs($0.at.timeIntervalSince(date)) < abs($1.at.timeIntervalSince(date)) }
    }

    /// The server's bands (High 76+, Medium 51–75, Low 26–50, Very low), for a
    /// level read off the curve.
    static func band(for level: Double) -> String {
        switch level {
        case 76...: return "High"
        case 51..<76: return "Medium"
        case 26..<51: return "Low"
        default: return "Very low"
        }
    }

    private func curve(_ battery: HealthBattery, picked: HealthCurvePoint?) -> some View {
        let tint = Self.tint(battery.band)
        return Chart {
            // The night, shaded: the climb is sleep, not a number going up.
            if let bed = battery.bedAt, let wake = battery.wakeAt, let first = battery.curve.first?.at, wake > first {
                RectangleMark(xStart: .value("Asleep", max(bed, first)), xEnd: .value("Woke", wake))
                    .foregroundStyle(Color.primary.opacity(0.06))
                    .annotation(position: .overlay, alignment: .topLeading, spacing: 0) {
                        Image(systemName: "moon.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(5)
                    }
            }
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
            if let picked {
                RingScrubRule(x: picked.at)
                PointMark(x: .value("Time", picked.at), y: .value("Level", picked.level))
                    .foregroundStyle(Self.tint(Self.band(for: picked.level)))
                    .symbolSize(70)
            }
        }
        .chartXSelection(value: $scrubbed)
        // Drawn in from the left the first time the card is seen.
        .mask(alignment: .leading) {
            Rectangle().scaleEffect(x: revealed ? 1 : 0.001, anchor: .leading)
        }
        .animation(.easeOut(duration: 0.9), value: revealed)
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
        .accessibilityHint("Drag across the curve to see the level at each time")
    }

    /// Four figures, whichever this battery has: a day's charge and drains, or
    /// today's charge overnight, the level at wake and what has gone since.
    private func parts(_ battery: HealthBattery) -> some View {
        partsRow(windowParts(battery))
    }

    private func windowParts(_ battery: HealthBattery) -> [(String, String, Color?)] {
        var items: [(String, String, Color?)] = []
        if let charged = battery.charged { items.append(("Charged", "+\(Int(charged.rounded()))", Self.tint("High"))) }
        if let wake = battery.wakeLevel { items.append(("At wake", "\(Int(wake.rounded()))", nil)) }
        if let drained = battery.drained {
            items.append((battery.noSleep == true ? "Since midnight" : "Drained", "−\(Int(drained.rounded()))", nil))
        }
        if let steepest = battery.biggestDrain {
            items.append(("Steepest", "−\(String(format: "%.1f", steepest.points))", JcTheme.danger))
        }
        return items
    }

    private func partsRow(_ items: [(String, String, Color?)]) -> some View {
        HStack(alignment: .top, spacing: 12) {
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
        if battery.noSleep == true {
            return "No sleep was recorded, so nothing charged."
        }
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

/// The battery's level beside its ring. When the level moves — a finger on
/// the curve — the digits roll and the ring sweeps to it in that level's colour.
struct BatteryGauge: View {
    let level: Double
    let band: String
    let caption: String
    var highlighted = false

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.12), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: CGFloat(level / 100))
                    .stroke(BatteryCard.tint(band), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 54, height: 54)
            .animation(.snappy(duration: 0.3), value: level)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Int(level.rounded()))")
                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: level))
                    .animation(.snappy(duration: 0.25), value: Int(level.rounded()))
                Text(caption)
                    .font(.subheadline.weight(highlighted ? .medium : .regular))
                    .foregroundStyle(highlighted ? AnyShapeStyle(JcTheme.accent) : AnyShapeStyle(.secondary))
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Body battery \(Int(level.rounded())), \(band)")
    }
}

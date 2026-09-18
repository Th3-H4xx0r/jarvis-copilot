import Charts
import SwiftUI

/// Sleep debt across the week: what each night added against the goal, or
/// paid back, built up night by night and coloured by how much is owed.
struct SleepDebtCard: View {
    let debt: HealthSleepDebt

    /// The bands, lowest first, with the hours each covers — the legend reads
    /// the same thresholds the server bands by.
    static let bands: [(name: String, range: String)] = [
        ("None", "under 1h"), ("Low", "1–5h"), ("Medium", "5–10h"), ("High", "10h+"),
    ]

    private struct Bar: Identifiable {
        let date: Date
        let hours: Double
        let night: HealthSleepDebt.Night
        var id: Date { date }
    }

    private var bars: [Bar] {
        debt.nights.compactMap { night in
            guard let date = RingDates.date(forKey: night.date) else { return nil }
            // A measured night with nothing owed still gets a sliver, so the
            // week reads as seven nights rather than gaps.
            let hours = night.asleep == nil ? 0 : max(Double(night.debt) / 60, 0.12)
            return Bar(date: date, hours: hours, night: night)
        }
    }

    var body: some View {
        RingMetricCard(
            title: "Sleep debt",
            symbol: RingSymbol(name: "moon.zzz.fill", tint: Self.tint(debt.band)),
            headline: RingStat(label: "Owed this week", value: Self.duration(debt.debt)),
            details: [
                RingStat(label: "Goal", value: Self.duration(debt.goal)),
                RingStat(label: "Average night", value: debt.average.map(Self.duration)),
                RingStat(label: "Short nights", value: debt.measured > 0 ? "\(debt.shortNights) of \(debt.measured)" : nil),
            ],
            badge: RingBadge(label: "Level", value: debt.band, caption: nil, tint: Self.tint(debt.band)),
            emptyText: debt.measured == 0 ? "No nights recorded this week" : nil,
            readout: { (date: Date) -> RingScrubReadout? in
                guard let bar = bars.first(where: { Calendar.current.isDate($0.date, inSameDayAs: date) }) else { return nil }
                let slept = bar.night.asleep.map { "slept \(Self.duration($0))" } ?? "not recorded"
                return RingScrubReadout(value: Self.duration(bar.night.debt),
                                        caption: "\(bar.date.formatted(.dateTime.weekday(.wide))) · \(slept)")
            }
        ) { selected, selection in
            VStack(alignment: .leading, spacing: 12) {
                Chart {
                    ForEach(bars) { bar in
                        BarMark(x: .value("Night", bar.date, unit: .day), y: .value("Owed", bar.hours), width: .ratio(0.55))
                            .foregroundStyle(Self.tint(bar.night.band).gradient)
                            .cornerRadius(5)
                            .opacity(selected == nil || Calendar.current.isDate(bar.date, inSameDayAs: selected!) ? 1 : 0.35)
                    }
                }
                .chartYScale(domain: 0...yTop)
                .chartYAxis {
                    AxisMarks(position: .trailing, values: yMarks) { value in
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                        AxisValueLabel { Text("\(value.as(Int.self) ?? 0)h") }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { _ in
                        AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
                    }
                }
                .chartXSelection(value: selection)
                .frame(height: 140)
                .animation(.snappy(duration: 0.18), value: selected)

                legend
            }
        }
    }

    /// Room for the band edges (5h, 10h) whatever the week holds.
    private var yTop: Double { max(10.5, (bars.map(\.hours).max() ?? 0) + 1) }
    private var yMarks: [Int] { yTop > 15 ? [0, 5, 10, 15, 20] : [0, 5, 10] }

    private var legend: some View {
        HStack(spacing: 0) {
            ForEach(Self.bands, id: \.name) { band in
                HStack(spacing: 5) {
                    Circle().fill(Self.tint(band.name)).frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(band.name).font(.caption2.weight(.semibold))
                        Text(band.range).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Bands: none under 1 hour, low 1 to 5, medium 5 to 10, high 10 or more")
    }

    /// Band colours from the app's own tokens, as a traffic light: green when
    /// nothing is owed, through the accent and amber to red.
    static func tint(_ band: String) -> Color {
        switch band {
        case "None": return JcTheme.success
        case "Low": return JcTheme.accent
        case "Medium": return JcTheme.amber
        case "High": return JcTheme.danger
        default: return .secondary
        }
    }

    static func duration(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    }
}

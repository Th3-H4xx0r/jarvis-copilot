import Charts
import SwiftUI

/// Weight from the scales linked to Jarvis Health: the latest weigh-in big,
/// how it moved over a week and a month, body fat and BMI, and five weeks of
/// weigh-ins to scrub.
struct WeightCard: View {
    let weight: HealthWeight?
    var showAll: (() -> Void)? = nil

    private struct Point: Identifiable {
        let day: Date
        let kg: Double
        var id: Date { day }
    }

    private var unit: TrainingUnit { TrainingUnit.current }

    /// One point a day: the day's weigh-ins averaged.
    private var points: [Point] {
        let calendar = Calendar.current
        let byDay = Dictionary(grouping: weight?.recent ?? []) { calendar.startOfDay(for: $0.at) }
        return byDay.map { day, readings in Point(day: day, kg: readings.map(\.weightKg).reduce(0, +) / Double(readings.count)) }
            .sorted { $0.day < $1.day }
    }

    /// The latest against the weigh-in nearest `days` before it (within three days).
    private func change(_ days: Int) -> String? {
        guard let latest = weight?.latest else { return nil }
        let target = latest.at.addingTimeInterval(-Double(days) * 86_400)
        let near = (weight?.recent ?? []).filter { abs($0.at.timeIntervalSince(target)) <= 3 * 86_400 }
        guard let then = near.min(by: { abs($0.at.timeIntervalSince(target)) < abs($1.at.timeIntervalSince(target)) })
        else { return nil }
        return HealthFormat.string(latest.weightKg - then.weightKg, kind: "kg_change")
    }

    /// "Today 7:12 AM", "Yesterday", "Tue", "Sep 3".
    static func when(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today, \(date.formatted(date: .omitted, time: .shortened))" }
        if calendar.isDateInYesterday(date) { return "Yesterday, \(date.formatted(date: .omitted, time: .shortened))" }
        if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    var body: some View {
        let latest = weight?.latest
        let points = points
        RingMetricCard(
            title: "Weight",
            symbol: RingSymbol(name: HealthMetric.weight.symbol, tint: HealthMetric.weight.tint),
            headline: RingStat(label: latest.map { Self.when($0.at) } ?? "Latest weigh-in",
                               value: latest.map { HealthFormat.weight($0.weightKg) }),
            details: [
                RingStat(label: "Past week", value: change(7)),
                RingStat(label: "Past month", value: change(30)),
                RingStat(label: "Body fat", value: latest?.bodyFat.map { String(format: "%.1f%%", $0) }),
                RingStat(label: "BMI", value: latest?.bmi.map { String(format: "%.1f", $0) }),
            ],
            showAll: showAll,
            emptyText: latest == nil ? "No weigh-ins yet — step on your scale and it lands here." : nil,
            readout: { (date: Date) -> RingScrubReadout? in
                guard let point = points.first(where: { Calendar.current.isDate($0.day, inSameDayAs: date) }) else { return nil }
                return RingScrubReadout(value: HealthFormat.weight(point.kg),
                                        caption: point.day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
            }
        ) { selected, selection in
            if points.count > 1 {
                Chart {
                    ForEach(points) { point in
                        LineMark(x: .value("Day", point.day, unit: .day), y: .value("Weight", unit.show(point.kg)))
                            .foregroundStyle(HealthMetric.weight.tint)
                            .interpolationMethod(.catmullRom)
                        PointMark(x: .value("Day", point.day, unit: .day), y: .value("Weight", unit.show(point.kg)))
                            .foregroundStyle(HealthMetric.weight.tint)
                            .symbolSize(selected.map { Calendar.current.isDate($0, inSameDayAs: point.day) } == true ? 70 : 22)
                    }
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                        AxisValueLabel().foregroundStyle(Color.secondary)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .weekOfYear)) { _ in
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.05))
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    }
                }
                .chartXSelection(value: selection)
                .frame(height: 140)
            }
        }
    }
}

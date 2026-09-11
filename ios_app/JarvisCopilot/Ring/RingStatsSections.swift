import Charts
import SwiftUI

/// Every metric the ring collects for one day, as numbers and charts.
struct RingStatsSections: View {
    @ObservedObject var store: RingHistoryStore
    let dayKey: String
    let capabilities: RingCapabilities

    var body: some View {
        let day = store.day(dayKey)
        let summary = day.summary
        VStack(spacing: 22) {
            activity(day, summary)
            sleep(day, summary)
            heartRate(day, summary)
            if capabilities.supports(.spo2) || day.spo2 != nil || !day.manualSpO2.isEmpty {
                spo2(day, summary)
            }
            if capabilities.hrv || day.hrv != nil {
                series("HRV", unit: "ms", color: .indigo, values: day.hrv, extra: [],
                       stats: [("Average", summary.hrvAvg.map { "\($0) ms" }), ("Latest", summary.hrvLatest.map { "\($0) ms" })])
            }
            if capabilities.stress || day.stress != nil {
                series("Stress", unit: "", color: .purple, values: day.stress, extra: [],
                       stats: [("Average", summary.stressAvg.map(String.init)), ("Latest", summary.stressLatest.map(String.init))])
            }
            if capabilities.anyTemperature || day.temperature != nil || !day.instantTemperature.isEmpty {
                series("Temperature", unit: "°C", color: .orange, values: day.temperature, extra: day.instantTemperature,
                       stats: [("Average", summary.temperatureAvg.map { String(format: "%.1f °C", $0) }),
                               ("Latest", summary.temperatureLatest.map { String(format: "%.1f °C", $0) })])
            }
            if capabilities.bloodPressure || !day.bloodPressure.isEmpty { bloodPressure(day) }
            if capabilities.bloodSugar || day.bloodSugar != nil { bloodSugar(day) }
            if !day.measurements.isEmpty { measurements(day) }
        }
    }

    // MARK: Sections

    private func activity(_ day: RingDay, _ s: RingDaySummary) -> some View {
        CardGroup("Activity") {
            statGrid([
                ("Steps", s.steps.map(String.init)),
                ("Calories", s.kilocalories.map { String(format: "%.0f kcal", $0) }),
                ("Distance", s.distanceMeters.map { String(format: "%.2f km", Double($0) / 1000) }),
                ("Active", s.activeMinutes.map { "\($0) min" }),
                ("Running steps", day.activity.map { String($0.runningSteps) }),
                ("15-min slots", day.stepSlots.isEmpty ? nil : String(day.stepSlots.count)),
            ])
            if !day.stepSlots.isEmpty {
                RowDivider()
                Chart(day.stepSlots, id: \.slot) { slot in
                    BarMark(x: .value("Hour", Double(slot.slot) / 4), y: .value("Steps", slot.steps), width: 3)
                        .foregroundStyle(Color.blue.gradient)
                }
                .chartXScale(domain: 0.0...24.0)
                .chartXAxis { hourAxis }
                .frame(height: 120)
                .padding(14)
            }
        }
    }

    private func sleep(_ day: RingDay, _ s: RingDaySummary) -> some View {
        CardGroup("Sleep") {
            statGrid([
                ("Asleep", s.sleepMinutes.map(duration)),
                ("Deep", s.deepMinutes.map(duration)),
                ("Light", s.lightMinutes.map(duration)),
                ("REM", s.remMinutes.map(duration)),
                ("Awake", s.awakeMinutes.map(duration)),
                ("Naps", day.naps.isEmpty ? nil : day.naps.map { "\(time($0.start))–\(time($0.end))" }.joined(separator: ", ")),
            ])
            if let night = day.sleep.max(by: { $0.asleepMinutes < $1.asleepMinutes }) {
                RowDivider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(time(night.start)) – \(time(night.end))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Chart(stageSegments(night)) { segment in
                        BarMark(xStart: .value("Start", segment.start), xEnd: .value("End", segment.end),
                                y: .value("Stage", segment.name))
                            .foregroundStyle(by: .value("Stage", segment.name))
                    }
                    .chartForegroundStyleScale(["Awake": Color.orange, "REM": Color.cyan,
                                                "Light": Color.blue, "Deep": Color.indigo])
                    .chartLegend(.hidden)
                    .frame(height: 130)
                }
                .padding(14)
            } else if !day.legacySleepSlots.isEmpty {
                RowDivider()
                empty("\(day.legacySleepSlots.count) legacy sleep slots recorded")
            } else {
                RowDivider()
                empty("No sleep recorded for this day")
            }
        }
    }

    private func heartRate(_ day: RingDay, _ s: RingDaySummary) -> some View {
        let line = timed(day.heartRate)
        let points = day.manualHeartRate + day.instantHeartRate
        return CardGroup("Heart rate") {
            statGrid([
                ("Latest", s.heartRateLatest.map { "\($0) bpm" }),
                ("Average", s.heartRateAvg.map { "\($0) bpm" }),
                ("Lowest", s.heartRateMin.map { "\($0) bpm" }),
                ("Highest", s.heartRateMax.map { "\($0) bpm" }),
                ("Sample interval", day.heartRate.map { "\($0.intervalMinutes) min" }),
                ("Spot readings", points.isEmpty ? nil : String(points.count)),
            ])
            RowDivider()
            if line.isEmpty && points.isEmpty {
                empty("No heart-rate readings for this day")
            } else {
                Chart {
                    ForEach(line, id: \.minute) { reading in
                        LineMark(x: .value("Hour", Double(reading.minute) / 60), y: .value("bpm", reading.value))
                            .foregroundStyle(Color.red)
                            .interpolationMethod(.catmullRom)
                    }
                    ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                        PointMark(x: .value("Hour", Double(point.minute) / 60), y: .value("bpm", point.value))
                            .foregroundStyle(Color.pink)
                    }
                }
                .chartXScale(domain: 0.0...24.0)
                .chartXAxis { hourAxis }
                .frame(height: 150)
                .padding(14)
            }
        }
    }

    private func spo2(_ day: RingDay, _ s: RingDaySummary) -> some View {
        let hours = hourlyRanges(day.spo2)
        let points = day.manualSpO2 + day.instantSpO2
        return CardGroup("Blood oxygen") {
            statGrid([
                ("Latest", s.spo2Latest.map { "\($0)%" }),
                ("Average", s.spo2Avg.map { "\($0)%" }),
                ("Lowest", s.spo2Min.map { "\($0)%" }),
                ("Spot readings", points.isEmpty ? nil : String(points.count)),
            ])
            RowDivider()
            if hours.isEmpty && points.isEmpty {
                empty("No SpO₂ readings for this day")
            } else {
                Chart {
                    ForEach(hours, id: \.hour) { range in
                        RuleMark(x: .value("Hour", Double(range.hour) + 0.5),
                                 yStart: .value("Low", range.low), yEnd: .value("High", range.high))
                            .lineStyle(StrokeStyle(lineWidth: 6, lineCap: .round))
                            .foregroundStyle(Color.cyan.opacity(0.8))
                    }
                    ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                        PointMark(x: .value("Hour", Double(point.minute) / 60), y: .value("%", point.value))
                            .foregroundStyle(Color.white)
                    }
                }
                .chartXScale(domain: 0.0...24.0)
                .chartYScale(domain: 80...100)
                .chartXAxis { hourAxis }
                .frame(height: 140)
                .padding(14)
            }
        }
    }

    private func series(_ title: String, unit: String, color: Color, values: RingSeries?, extra: [RingTimedValue],
                        stats: [(String, String?)]) -> some View {
        let line = timed(values)
        return CardGroup(title) {
            statGrid(stats + [("Sample interval", values.map { "\($0.intervalMinutes) min" })])
            RowDivider()
            if line.isEmpty && extra.isEmpty {
                empty("No \(title.lowercased()) readings for this day")
            } else {
                Chart {
                    ForEach(line, id: \.minute) { reading in
                        LineMark(x: .value("Hour", Double(reading.minute) / 60), y: .value(unit, reading.value))
                            .foregroundStyle(color)
                            .interpolationMethod(.catmullRom)
                        PointMark(x: .value("Hour", Double(reading.minute) / 60), y: .value(unit, reading.value))
                            .foregroundStyle(color)
                            .symbolSize(14)
                    }
                    ForEach(Array(extra.enumerated()), id: \.offset) { _, point in
                        PointMark(x: .value("Hour", Double(point.minute) / 60), y: .value(unit, point.value))
                            .foregroundStyle(Color.white)
                    }
                }
                .chartXScale(domain: 0.0...24.0)
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXAxis { hourAxis }
                .frame(height: 140)
                .padding(14)
            }
        }
    }

    private func bloodPressure(_ day: RingDay) -> some View {
        CardGroup("Blood pressure") {
            if day.bloodPressure.isEmpty {
                empty("No blood-pressure readings for this day")
            } else {
                ForEach(Array(day.bloodPressure.enumerated()), id: \.offset) { index, reading in
                    if index > 0 { RowDivider() }
                    Row { LabeledContent(time(reading.time), value: "\(reading.systolic)/\(reading.diastolic) mmHg") }
                }
            }
        }
    }

    private func bloodSugar(_ day: RingDay) -> some View {
        let hours = hourlyRanges(day.bloodSugar)
        return CardGroup("Blood sugar") {
            if hours.isEmpty {
                empty("No blood-sugar readings for this day")
            } else {
                ForEach(Array(hours.enumerated()), id: \.offset) { index, range in
                    if index > 0 { RowDivider() }
                    Row { LabeledContent(String(format: "%02d:00", range.hour), value: "\(range.low)–\(range.high)") }
                }
            }
        }
    }

    private func measurements(_ day: RingDay) -> some View {
        CardGroup("On-demand readings") {
            ForEach(Array(day.measurements.enumerated().reversed()), id: \.offset) { index, record in
                if index != day.measurements.count - 1 { RowDivider() }
                Row {
                    LabeledContent("\(time(record.time)) · \(record.type.replacingOccurrences(of: "_", with: " "))",
                                   value: measurementValue(record))
                }
            }
        }
    }

    // MARK: Helpers

    private var hourAxis: some AxisContent {
        AxisMarks(values: [0.0, 6, 12, 18, 24]) { value in
            AxisGridLine()
            AxisValueLabel { Text("\(Int(value.as(Double.self) ?? 0))h") }
        }
    }

    private func statGrid(_ items: [(String, String?)]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                  alignment: .leading, spacing: 12) {
            ForEach(items.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 2) {
                    Text(items[index].0).font(.caption).foregroundStyle(.secondary)
                    Text(items[index].1 ?? "—")
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                }
            }
        }
        .padding(16)
    }

    private func empty(_ text: String) -> some View {
        Row { Text(text).font(.subheadline).foregroundStyle(.secondary) }
    }

    private func timed(_ series: RingSeries?) -> [RingTimedValue] {
        (series?.readings ?? []).map { RingTimedValue(minute: $0.minute, value: $0.value) }
    }

    private struct HourRange {
        let hour: Int
        let low: Int
        let high: Int
    }

    private func hourlyRanges(_ values: RingMinMax?) -> [HourRange] {
        guard let values else { return [] }
        return zip(values.min, values.max).enumerated().compactMap { hour, pair in
            pair.0 > 0 && pair.1 > 0 ? HourRange(hour: hour, low: min(pair.0, pair.1), high: max(pair.0, pair.1)) : nil
        }
    }

    private struct StageSegment: Identifiable {
        let id = UUID()
        let name: String
        let start: Date
        let end: Date
    }

    private func stageSegments(_ night: RingSleepSession) -> [StageSegment] {
        var cursor = night.start
        var out: [StageSegment] = []
        for stage in night.stages {
            let end = cursor.addingTimeInterval(TimeInterval(stage.minutes * 60))
            out.append(StageSegment(name: stageName(stage.stage), start: cursor, end: end))
            cursor = end
        }
        return out
    }

    private func stageName(_ code: Int) -> String {
        switch code {
        case RingSleepStage.deep: return "Deep"
        case RingSleepStage.light: return "Light"
        case RingSleepStage.rem: return "REM"
        case RingSleepStage.awake: return "Awake"
        default: return "Stage \(code)"
        }
    }

    private func duration(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    private func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    private func measurementValue(_ record: RingMeasurementRecord) -> String {
        guard record.outcome == "done" else { return record.outcome.replacingOccurrences(of: "_", with: " ") }
        if let celsius = record.celsius { return String(format: "%.1f °C", celsius) }
        if let sys = record.systolic, let dia = record.diastolic, record.type == "blood_pressure" { return "\(sys)/\(dia)" }
        return record.value.map(String.init) ?? "—"
    }
}

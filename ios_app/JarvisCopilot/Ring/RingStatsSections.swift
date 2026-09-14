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
                series("HRV", unit: "ms", color: JcTheme.blue, values: day.hrv, extra: [],
                       stats: [("Latest", summary.hrvLatest.map { "\($0) ms" }), ("Average", summary.hrvAvg.map { "\($0) ms" })],
                       format: { "\(Int($0.rounded())) ms" })
            }
            if capabilities.stress || day.stress != nil {
                series("Stress", unit: "", color: JcTheme.amber, values: day.stress, extra: [],
                       stats: [("Latest", summary.stressLatest.map(String.init)), ("Average", summary.stressAvg.map(String.init))],
                       format: { "\(Int($0.rounded()))" })
            }
            if capabilities.anyTemperature || day.temperature != nil || !day.instantTemperature.isEmpty {
                series("Temperature", unit: "°C", color: .orange, values: day.temperature, extra: day.instantTemperature,
                       stats: [("Latest", summary.temperatureLatest.map { String(format: "%.1f °C", $0) }),
                               ("Average", summary.temperatureAvg.map { String(format: "%.1f °C", $0) })],
                       format: { String(format: "%.1f °C", $0) })
            }
            if capabilities.bloodPressure || !day.bloodPressure.isEmpty { bloodPressure(day) }
            if capabilities.bloodSugar || day.bloodSugar != nil { bloodSugar(day) }
            if !day.measurements.isEmpty { measurements(day) }
        }
    }

    // MARK: Sections
    //
    // Each chart card leads with its headline stat and scrubs: see `RingMetricCard`.

    private func activity(_ day: RingDay, _ s: RingDaySummary) -> some View {
        RingMetricCard(
            title: "Activity",
            headline: RingStat(label: "Steps", value: s.steps.map { $0.formatted() }),
            details: [
                RingStat(label: "Calories", value: s.kilocalories.map { String(format: "%.0f kcal", $0) }),
                RingStat(label: "Distance", value: s.distanceMeters.map { String(format: "%.2f km", Double($0) / 1000) }),
                RingStat(label: "Active", value: s.activeMinutes.map { "\($0) min" }),
                RingStat(label: "Running steps", value: day.activity.map { $0.runningSteps.formatted() }),
            ],
            emptyText: day.stepSlots.isEmpty ? "No step timeline for this day" : nil,
            readout: { (hour: Double) -> RingScrubReadout? in
                let at = RingChartScrub.steps(day.stepSlots, hour: hour)
                return RingScrubReadout(value: "\(at.steps.formatted()) steps",
                                        caption: "\(RingChartScrub.clock(minute: at.slot * 15)) · \(at.soFar.formatted()) so far")
            }
        ) { selected, selection in
            Chart {
                ForEach(day.stepSlots, id: \.slot) { slot in
                    BarMark(x: .value("Hour", Double(slot.slot) / 4), y: .value("Steps", slot.steps), width: 3)
                        .foregroundStyle(JcTheme.accent.gradient)
                }
                if let selected { RingScrubRule(x: selected) }
            }
            .chartXScale(domain: 0.0...24.0)
            .chartXAxis { hourAxis }
            .chartXSelection(value: selection)
            .frame(height: 120)
        }
    }

    private func sleep(_ day: RingDay, _ s: RingDaySummary) -> some View {
        let night = day.sleep.max(by: { $0.asleepMinutes < $1.asleepMinutes })
        let noNight = day.legacySleepSlots.isEmpty
            ? "No sleep recorded for this day"
            : "\(day.legacySleepSlots.count) legacy sleep slots recorded"
        return RingMetricCard(
            title: "Sleep",
            headline: RingStat(label: "Asleep", value: s.sleepMinutes.map(duration)),
            details: [
                RingStat(label: "Deep", value: s.deepMinutes.map(duration)),
                RingStat(label: "Light", value: s.lightMinutes.map(duration)),
                RingStat(label: "REM", value: s.remMinutes.map(duration)),
                RingStat(label: "Awake", value: s.awakeMinutes.map(duration)),
                RingStat(label: "Naps", value: day.naps.isEmpty ? nil : String(day.naps.count)),
            ],
            emptyText: night == nil ? noNight : nil,
            readout: { (date: Date) -> RingScrubReadout? in
                guard let night, let at = RingChartScrub.stage(in: night, at: date) else { return nil }
                let name = stageName(at.stage)
                let length = duration(Int(at.end.timeIntervalSince(at.start) / 60))
                return RingScrubReadout(value: name, caption: "\(time(date)) · \(length) of \(name.lowercased())")
            }
        ) { selected, selection in
            if let night {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(time(night.start)) – \(time(night.end))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Chart {
                        ForEach(stageSegments(night)) { segment in
                            BarMark(xStart: .value("Start", segment.start), xEnd: .value("End", segment.end),
                                    y: .value("Stage", segment.name))
                                .foregroundStyle(by: .value("Stage", segment.name))
                        }
                        if let selected { RingScrubRule(x: selected) }
                    }
                    .chartForegroundStyleScale(["Awake": Color.orange, "REM": JcTheme.accentAlt,
                                                "Light": JcTheme.accent, "Deep": JcTheme.primaryBlue])
                    .chartLegend(.hidden)
                    .chartXSelection(value: selection)
                    .frame(height: 130)
                }
            }
        }
    }

    private func heartRate(_ day: RingDay, _ s: RingDaySummary) -> some View {
        let line = timed(day.heartRate)
        let points = day.manualHeartRate + day.instantHeartRate
        let tolerance = max(15, day.heartRate?.intervalMinutes ?? 0)
        return RingMetricCard(
            title: "Heart rate",
            headline: RingStat(label: "Latest", value: s.heartRateLatest.map { "\($0) bpm" }),
            details: [
                RingStat(label: "Average", value: s.heartRateAvg.map { "\($0) bpm" }),
                RingStat(label: "Lowest", value: s.heartRateMin.map { "\($0) bpm" }),
                RingStat(label: "Highest", value: s.heartRateMax.map { "\($0) bpm" }),
                RingStat(label: "Sample interval", value: day.heartRate.map { "\($0.intervalMinutes) min" }),
                RingStat(label: "Spot readings", value: points.isEmpty ? nil : String(points.count)),
            ],
            emptyText: line.isEmpty && points.isEmpty ? "No heart-rate readings for this day" : nil,
            readout: { (hour: Double) -> RingScrubReadout? in
                guard let reading = RingChartScrub.nearest(line + points, hour: hour, toleranceMinutes: tolerance)
                else { return nil }
                let spot = !line.contains(reading)
                return RingScrubReadout(value: "\(Int(reading.value.rounded())) bpm",
                                        caption: RingChartScrub.clock(minute: reading.minute) + (spot ? " · spot reading" : ""))
            }
        ) { selected, selection in
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
                if let selected { RingScrubRule(x: selected) }
            }
            .chartXScale(domain: 0.0...24.0)
            .chartXAxis { hourAxis }
            .chartXSelection(value: selection)
            .frame(height: 150)
        }
    }

    private func spo2(_ day: RingDay, _ s: RingDaySummary) -> some View {
        let hours = hourlyRanges(day.spo2)
        let points = day.manualSpO2 + day.instantSpO2
        return RingMetricCard(
            title: "Blood oxygen",
            headline: RingStat(label: "Latest", value: s.spo2Latest.map { "\($0)%" }),
            details: [
                RingStat(label: "Average", value: s.spo2Avg.map { "\($0)%" }),
                RingStat(label: "Lowest", value: s.spo2Min.map { "\($0)%" }),
                RingStat(label: "Spot readings", value: points.isEmpty ? nil : String(points.count)),
            ],
            emptyText: hours.isEmpty && points.isEmpty ? "No SpO₂ readings for this day" : nil,
            readout: { (hour: Double) -> RingScrubReadout? in
                if let spot = RingChartScrub.nearest(points, hour: hour, toleranceMinutes: 15) {
                    return RingScrubReadout(value: "\(Int(spot.value.rounded()))%",
                                            caption: RingChartScrub.clock(minute: spot.minute) + " · spot reading")
                }
                guard let range = RingChartScrub.hourRange(day.spo2, hour: hour) else { return nil }
                let from = Int(hour) * 60
                return RingScrubReadout(value: range.low == range.high ? "\(range.low)%" : "\(range.low)–\(range.high)%",
                                        caption: "\(RingChartScrub.clock(minute: from))–\(RingChartScrub.clock(minute: from + 60))")
            }
        ) { selected, selection in
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
                if let selected { RingScrubRule(x: selected) }
            }
            .chartXScale(domain: 0.0...24.0)
            .chartYScale(domain: 80...100)
            .chartXAxis { hourAxis }
            .chartXSelection(value: selection)
            .frame(height: 140)
        }
    }

    /// A single time series (HRV, stress, temperature). The first of `stats` is the
    /// headline; `format` renders a scrubbed reading.
    private func series(_ title: String, unit: String, color: Color, values: RingSeries?, extra: [RingTimedValue],
                        stats: [(String, String?)], format: @escaping (Double) -> String) -> some View {
        let line = timed(values)
        let tolerance = max(15, values?.intervalMinutes ?? 0)
        let all = stats.map { RingStat(label: $0.0, value: $0.1) }
            + [RingStat(label: "Sample interval", value: values.map { "\($0.intervalMinutes) min" })]
        return RingMetricCard(
            title: title,
            headline: all[0],
            details: Array(all.dropFirst()),
            emptyText: line.isEmpty && extra.isEmpty ? "No \(title.lowercased()) readings for this day" : nil,
            readout: { (hour: Double) -> RingScrubReadout? in
                guard let reading = RingChartScrub.nearest(line + extra, hour: hour, toleranceMinutes: tolerance)
                else { return nil }
                return RingScrubReadout(value: format(reading.value), caption: RingChartScrub.clock(minute: reading.minute))
            }
        ) { selected, selection in
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
                if let selected { RingScrubRule(x: selected) }
            }
            .chartXScale(domain: 0.0...24.0)
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxis { hourAxis }
            .chartXSelection(value: selection)
            .frame(height: 140)
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

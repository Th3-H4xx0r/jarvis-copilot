import SwiftUI

// The band's spot readings in Jarvis Health: blood pressure, glucose, blood components, body
// composition, ECG. The server keeps them (`/health/vitals`, `/health/history`) and says where
// each sits against a reference range for this person; these draw it.

/// A Low / Normal / Elevated / High bar, in canonical units (`kind` says how to show them).
struct HealthReferenceBar: Codable, Equatable {
    struct Segment: Codable, Equatable {
        var status: String
        var from: Double
        var to: Double
    }

    var label: String
    var kind: String
    /// The history bucket's number the marker follows: `value`, or `low` (diastolic).
    var field: String
    var segments: [Segment]

    var lower: Double { segments.first?.from ?? 0 }
    var upper: Double { segments.last?.to ?? 1 }

    /// The segment a value falls in (the ends hold anything past them).
    func status(of value: Double) -> String? {
        guard let first = segments.first, let last = segments.last else { return nil }
        if value < first.from { return first.status }
        return segments.first { value >= $0.from && value < $0.to }?.status ?? last.status
    }

    /// Where a value sits along the bar, 0…1.
    func position(of value: Double) -> Double {
        guard upper > lower else { return 0 }
        return min(1, max(0, (value - lower) / (upper - lower)))
    }

    static func color(_ status: String) -> Color {
        switch status {
        case "low": return JcTheme.blue
        case "normal": return JcTheme.success
        case "elevated": return JcTheme.amber
        case "high": return .orange
        default: return JcTheme.muted
        }
    }

    static func word(_ status: String) -> String {
        switch status {
        case "low": return "Low"
        case "normal": return "Normal"
        case "elevated": return "Elevated"
        case "high": return "High"
        default: return status.capitalized
        }
    }
}

/// One spot reading, as the server lists it.
struct HealthVitalReading: Codable, Equatable, Identifiable {
    var metric: String
    var at: String
    var value: Double
    var diastolic: Double?

    var id: String { metric + at }
    var date: Date { ISO8601DateFormatter.health.date(from: at) ?? ISO8601DateFormatter().date(from: at) ?? .distantPast }
}

extension ISO8601DateFormatter {
    /// The server's instants, with or without fractions of a second.
    static let health: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

/// `/health/vitals`: per metric its latest, average, trend and bars, and Jarvis's sentences.
struct HealthVitals: Codable, Equatable {
    struct Latest: Codable, Equatable {
        var at: String
        var value: Double
        var diastolic: Double?
        var text: String?
    }

    struct Metric: Codable, Equatable {
        var title: String
        var kind: String
        var count: Int
        var latest: Latest
        var average: Double?
        var lowest: Double?
        var highest: Double?
        var trend: String?
        var status: String?
        var reference: String?
        var bars: [HealthReferenceBar]?
    }

    var metrics: [String: Metric]
    var insights: [String]
    var disclaimer: String
}

// MARK: The range bar

/// The official app's reference bar: coloured segments with their thresholds under them, and a
/// marker for the value (it slides as the chart is scrubbed).
struct HealthRangeBar: View {
    let bar: HealthReferenceBar
    let value: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    HStack(spacing: 2) {
                        ForEach(Array(bar.segments.enumerated()), id: \.offset) { _, segment in
                            Capsule()
                                .fill(HealthReferenceBar.color(segment.status))
                                .frame(width: max(2, width * (segment.to - segment.from) / max(0.001, bar.upper - bar.lower) - 2))
                        }
                    }
                    .frame(height: 6)
                    if let value {
                        Circle()
                            .fill(.white)
                            .overlay(Circle().stroke(HealthReferenceBar.color(bar.status(of: value) ?? ""), lineWidth: 3))
                            .frame(width: 14, height: 14)
                            .offset(x: width * bar.position(of: value) - 7)
                            .animation(.snappy(duration: 0.25), value: value)
                    }
                }
                .frame(height: 14)
            }
            .frame(height: 14)
            // The thresholds, under where they fall.
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    ForEach(Array(thresholds.enumerated()), id: \.offset) { index, mark in
                        Text(HealthFormat.number(mark, kind: bar.kind))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .alignmentGuide(.leading) { d in
                                let x = geo.size.width * bar.position(of: mark)
                                let anchor = index == 0 ? 0 : index == thresholds.count - 1 ? d.width : d.width / 2
                                return -(x - anchor)
                            }
                    }
                }
            }
            .frame(height: 14)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var thresholds: [Double] { bar.segments.map(\.from) + [bar.upper] }

    private var accessibilityText: String {
        guard let value, let status = bar.status(of: value) else { return bar.label }
        return "\(bar.label): \(HealthFormat.string(value, kind: bar.kind)), \(HealthReferenceBar.word(status))"
    }
}

/// "Low · Normal · High": the bar's colours, once per card.
struct HealthRangeLegend: View {
    let statuses: [String]

    var body: some View {
        HStack(spacing: 14) {
            ForEach(statuses, id: \.self) { status in
                HStack(spacing: 5) {
                    Circle().fill(HealthReferenceBar.color(status)).frame(width: 7, height: 7)
                    Text(HealthReferenceBar.word(status)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// A Low / Normal / High chip.
struct HealthStatusChip: View {
    let status: String

    var body: some View {
        Text(HealthReferenceBar.word(status))
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(HealthReferenceBar.color(status).opacity(0.18), in: Capsule())
            .foregroundStyle(HealthReferenceBar.color(status))
    }
}

/// The reference card under a vital's chart: each bar with its marker on `value(bar)`.
struct HealthReferenceCard: View {
    let bars: [HealthReferenceBar]
    let value: (HealthReferenceBar) -> Double?
    /// "Latest · Oct 5, 9:14 PM" or the scrubbed span.
    let caption: String

    var body: some View {
        CardGroup("Reference", footer: "Ranges for your age and sex where they differ. Wrist-band readings are wellness estimates, not a diagnosis.") {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    HealthRangeLegend(statuses: legend)
                    Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                ForEach(Array(bars.enumerated()), id: \.offset) { _, bar in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(bar.label).font(.subheadline.weight(.medium))
                            Spacer()
                            if let v = value(bar) {
                                Text(HealthFormat.string(v, kind: bar.kind)).font(.subheadline.monospacedDigit())
                                if let status = bar.status(of: v) { HealthStatusChip(status: status) }
                            }
                        }
                        HealthRangeBar(bar: bar, value: value(bar))
                    }
                }
            }
            .padding(16)
        }
    }

    private var legend: [String] {
        var seen: [String] = []
        for bar in bars { for s in bar.segments where !s.status.isEmpty && !seen.contains(s.status) { seen.append(s.status) } }
        let order = ["low", "normal", "elevated", "high"]
        return order.filter(seen.contains)
    }
}

/// Every reading in the range, newest first, each with its chip.
struct HealthReadingsCard: View {
    let readings: [HealthVitalReading]
    let kind: String
    let bars: [HealthReferenceBar]

    var body: some View {
        CardGroup("Readings") {
            ForEach(Array(readings.prefix(30).enumerated()), id: \.offset) { index, reading in
                if index > 0 { RowDivider() }
                Row {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(text(reading)).font(.body.monospacedDigit())
                            Text(reading.date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let status = status(reading) { HealthStatusChip(status: status) }
                    }
                }
            }
        }
    }

    private func text(_ r: HealthVitalReading) -> String {
        if kind == "mmhg", let d = r.diastolic { return "\(Int(r.value.rounded()))/\(Int(d.rounded())) mmHg" }
        return HealthFormat.string(r.value, kind: kind)
    }

    /// The worst of its bars: a pressure is as high as its higher half.
    private func status(_ r: HealthVitalReading) -> String? {
        let order = ["low": 1, "normal": 0, "elevated": 2, "high": 3]
        let found = bars.compactMap { bar -> String? in
            let v = bar.field == "low" ? r.diastolic : r.value
            return v.flatMap(bar.status(of:))
        }
        return found.max { (order[$0] ?? 0) < (order[$1] ?? 0) }
    }
}

// MARK: The Health tab card

@MainActor
final class HealthVitalsModel: ObservableObject {
    @Published private(set) var vitals: HealthVitals?
    private let client: HealthClient

    init(client: HealthClient = HealthClient(spaceID: HealthSpace.shared)) { self.client = client }

    func load() async {
        if let fresh = try? await client.vitals(days: 90) { vitals = fresh }
    }

    /// The groups with a reading, in their order.
    var groups: [HealthMetricGroup] {
        guard let vitals else { return [] }
        return HealthMetricGroup.allCases.filter { group in group.metrics.contains { vitals.metrics[$0.rawValue] != nil } }
    }
}

/// The band's readings on the Health tab: each group's latest with its bar; a tap opens its page.
struct HealthVitalsCard: View {
    @ObservedObject var model: HealthVitalsModel
    let open: (HealthMetricGroup) -> Void

    var body: some View {
        if let vitals = model.vitals, !model.groups.isEmpty {
            CardGroup("Band readings", footer: vitals.insights.first) {
                ForEach(Array(model.groups.enumerated()), id: \.offset) { index, group in
                    if index > 0 { RowDivider() }
                    Button { open(group) } label: { row(group, vitals) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private func row(_ group: HealthMetricGroup, _ vitals: HealthVitals) -> some View {
        let metric = group.metrics.first { vitals.metrics[$0.rawValue] != nil } ?? group.metrics[0]
        let entry = vitals.metrics[metric.rawValue]
        return Row(minHeight: 64) {
            HStack(spacing: 12) {
                RingMetricSymbol(name: group.symbol, tint: group.tint).frame(width: 26)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(group.title).font(.body.weight(.medium))
                        Spacer()
                        if let entry { Text(latestText(entry, metric)).font(.subheadline.monospacedDigit()) }
                        if let status = entry?.status { HealthStatusChip(status: status) }
                    }
                    if let entry, let bar = entry.bars?.first {
                        HealthRangeBar(bar: bar, value: entry.latest.value)
                    }
                    if let entry, let at = ISO8601DateFormatter.health.date(from: entry.latest.at)
                        ?? ISO8601DateFormatter().date(from: entry.latest.at) {
                        Text("\(metric.title) · \(at.formatted(.relative(presentation: .named)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                JcIcon("chevron.right", size: 12).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
    }

    private func latestText(_ entry: HealthVitals.Metric, _ metric: HealthMetric) -> String {
        if metric == .bloodPressure, let d = entry.latest.diastolic {
            return "\(Int(entry.latest.value.rounded()))/\(Int(d.rounded())) mmHg"
        }
        return HealthFormat.string(entry.latest.value, kind: entry.kind)
    }
}

// MARK: A group's page

/// A group's metrics behind one switch (Uric acid · Cholesterol · TG · HDL · LDL…), each its
/// own history page.
struct HealthMetricGroupView: View {
    let group: HealthMetricGroup
    @ObservedObject var tab: HealthTabModel
    let selection: HealthSelection
    @State private var metric: HealthMetric

    init(group: HealthMetricGroup, tab: HealthTabModel, selection: HealthSelection) {
        self.group = group
        self.tab = tab
        self.selection = selection
        _metric = State(initialValue: group.metrics[0])
    }

    var body: some View {
        VStack(spacing: 0) {
            if group.metrics.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(group.metrics) { m in
                            Button(m.shortTitle) { metric = m }
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(metric == m ? AnyShapeStyle(group.tint) : AnyShapeStyle(Color.white.opacity(0.08)),
                                            in: Capsule())
                                .foregroundStyle(metric == m ? Color.black : Color.primary)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                }
            }
            if group == .ecg, let id = WearablesHub.shared.band.deviceID {
                NavigationLink { BandEcgHistoryView(deviceID: id) } label: {
                    Label("ECG reports: rhythm, HRV, QTc, risk analysis", systemImage: BandMeasure.ecg.icon)
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                }
            }
            HealthHistoryView(metric: metric, tab: tab, selection: selection)
                .id(metric)
        }
        .navigationTitle(group.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

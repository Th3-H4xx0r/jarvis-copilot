import Charts
import SwiftUI

// A vital's day, the way the band's own app draws one (G Band, a reading's page on its day):
// every reading on a midnight-to-midnight line, the half hour under the finger, the day's
// average, its lowest and highest, and the reference bars following the scrub.

/// A chart's y axis: a vital's padded range, or the automatic one.
struct HealthChartScale: ViewModifier {
    let padded: ClosedRange<Double>?
    var includesZero = false

    func body(content: Content) -> some View {
        if let padded {
            content.chartYScale(domain: padded)
        } else {
            content.chartYScale(domain: .automatic(includesZero: includesZero))
        }
    }

    /// Room around the values — a quarter of their spread, at least a tenth of their size — so
    /// one reading sits mid-chart rather than on a 102–103 axis.
    static func padded(_ values: [Double]) -> ClosedRange<Double>? {
        guard let lo = values.min(), let hi = values.max() else { return nil }
        let pad = max((hi - lo) * 0.25, abs(hi) * 0.1, 0.5)
        return max(0, lo - pad)...(hi + pad)
    }
}

/// One vital's day from the server (`/health/history?range=D&end=`), each day kept once
/// loaded so stepping back and forth doesn't wait.
@MainActor
final class HealthVitalDayModel: ObservableObject {
    let metric: HealthMetric
    @Published private(set) var day: Date
    @Published private(set) var history: HealthHistory?
    @Published private(set) var error: String?
    private var loaded: [String: HealthHistory] = [:]
    private let client: HealthClient

    init(metric: HealthMetric, day: Date, client: HealthClient = HealthClient(spaceID: HealthSpace.shared)) {
        self.metric = metric
        self.day = Calendar.current.startOfDay(for: day)
        self.client = client
    }

    var key: String { RingDates.dayKey(day) }
    var isToday: Bool { Calendar.current.isDateInToday(day) }

    func step(_ days: Int) {
        guard let next = Calendar.current.date(byAdding: .day, value: days, to: day),
              next <= Calendar.current.startOfDay(for: Date()) else { return }
        day = next
        history = loaded[key]
        error = nil
    }

    func load() async {
        let key = self.key
        do {
            let fresh = try await client.history(metric: metric.rawValue, range: HealthRange.day.rawValue, end: key,
                                                 unit: TrainingUnit.current.rawValue)
            loaded[key] = fresh
            guard key == self.key else { return }
            history = fresh
            error = nil
        } catch {
            guard key == self.key, history == nil else { return }
            self.error = error.localizedDescription
        }
    }

    /// Put a day on screen without a server: tests and previews.
    func seed(_ history: HealthHistory) {
        loaded[key] = history
        self.history = history
    }
}

struct HealthVitalDayView: View {
    let metric: HealthMetric
    @StateObject private var model: HealthVitalDayModel
    @State private var scrubbed: Date?
    // A unit picked below redraws the page.
    @AppStorage(GlucoseUnit.key) private var glucoseUnit: GlucoseUnit = .mmolL
    @AppStorage(BloodFatUnit.key) private var bloodFatUnit: BloodFatUnit = .mmolL
    @AppStorage(UricAcidUnit.key) private var uricAcidUnit: UricAcidUnit = .umolL

    init(metric: HealthMetric, day: Date, model: HealthVitalDayModel? = nil) {
        self.metric = metric
        _model = StateObject(wrappedValue: model ?? HealthVitalDayModel(metric: metric, day: day))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepper
            if let history = model.history {
                content(history)
            } else if let error = model.error {
                CardGroup {
                    Row { Text(error).font(.subheadline).foregroundStyle(.orange) }
                    RowDivider()
                    Row { Button("Try again") { Task { await model.load() } } }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 240)
            }
        }
        .task(id: model.key) {
            scrubbed = nil
            await model.load()
        }
        .sensoryFeedback(.selection, trigger: slot(points)?.start)
    }

    // MARK: Day

    private var stepper: some View {
        HStack {
            Button { model.step(-1) } label: { JcIcon("chevron.left", size: 15) }
                .accessibilityLabel("The day before")
            Spacer()
            Text(model.isToday ? "Today" : model.day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
            Spacer()
            Button { model.step(1) } label: { JcIcon("chevron.right", size: 15) }
                .disabled(model.isToday)
                .opacity(model.isToday ? 0.3 : 1)
                .accessibilityLabel("The day after")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 28)
    }

    /// The day's readings, oldest first.
    private var points: [HealthVitalReading] {
        (model.history?.readings ?? []).filter { $0.metric == metric.rawValue }.sorted { $0.date < $1.date }
    }

    private var kind: String { model.history?.kind ?? "" }

    private func content(_ history: HealthHistory) -> some View {
        let points = self.points
        return VStack(alignment: .leading, spacing: 20) {
            CardGroup {
                VStack(spacing: 6) {
                    headline(points)
                    if points.isEmpty {
                        Text("No \(metric.inSentence) on this day.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 200)
                    } else {
                        chart(points)
                    }
                }
                .padding(14)
                if let average = history.headline.value, !points.isEmpty {
                    RowDivider()
                    Row {
                        HStack {
                            Text("Average for the whole day").font(.subheadline)
                            Spacer()
                            Text(averageText(average, history.headline.low))
                                .font(.system(.title3, design: .rounded).weight(.semibold))
                                .monospacedDigit()
                        }
                    }
                }
            }
            if let lowest = points.min(by: { $0.value < $1.value }), let highest = points.max(by: { $0.value < $1.value }) {
                CardGroup {
                    HStack(spacing: 0) {
                        extreme("Min.", lowest, symbol: "arrow.down")
                        Divider().frame(height: 50)
                        extreme("Max.", highest, symbol: "arrow.up")
                    }
                    .padding(.vertical, 14)
                }
            }
            if let bars = history.reference, !bars.isEmpty {
                HealthReferenceCard(bars: bars, value: { marker($0, points) }, caption: slotLabel(points))
            }
            if !points.isEmpty {
                CardGroup("Highlights") {
                    Row {
                        Text(history.highlight).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 4)
                    }
                }
                HealthReadingsCard(readings: points.reversed(), kind: kind, bars: history.reference ?? [],
                                   timesOnly: true)
            }
            HealthUnitCard(kind: kind)
        }
    }

    // MARK: Headline: the half hour under the finger (the latest one before a touch)

    struct Slot: Equatable {
        var start: Date
        var value: Double
        var low: Double?
        var count: Int
    }

    private func slot(_ points: [HealthVitalReading]) -> Slot? {
        let anchor: HealthVitalReading?
        if let scrubbed {
            anchor = points.min { abs($0.date.timeIntervalSince(scrubbed)) < abs($1.date.timeIntervalSince(scrubbed)) }
        } else {
            anchor = points.last
        }
        guard let anchor else { return nil }
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.hour, .minute], from: anchor.date)
        let start = calendar.startOfDay(for: anchor.date)
            .addingTimeInterval(TimeInterval((parts.hour ?? 0) * 3600 + (parts.minute ?? 0) / 30 * 1800))
        let inside = points.filter { $0.date >= start && $0.date < start.addingTimeInterval(1800) }
        guard !inside.isEmpty else { return nil }
        let lows = inside.compactMap(\.diastolic)
        return Slot(start: start, value: inside.map(\.value).reduce(0, +) / Double(inside.count),
                    low: lows.isEmpty ? nil : lows.reduce(0, +) / Double(lows.count), count: inside.count)
    }

    /// "07:30 AM–07:59 AM".
    private func slotLabel(_ points: [HealthVitalReading]) -> String {
        guard let slot = slot(points) else { return model.day.formatted(.dateTime.month(.abbreviated).day()) }
        let style = Date.FormatStyle.dateTime.hour(.twoDigits(amPM: .abbreviated)).minute()
        return "\(slot.start.formatted(style))–\(slot.start.addingTimeInterval(1740).formatted(style))"
    }

    private func headline(_ points: [HealthVitalReading]) -> some View {
        let slot = slot(points)
        return VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(slot.map { $0.count > 1 ? "Average" : "Reading" } ?? "Average")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text(slot.map { averageText($0.value, $0.low) } ?? "—")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.2), value: slot?.value)
            }
            Text(slotLabel(points))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(scrubbed == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(JcTheme.accent))
        }
        .frame(maxWidth: .infinity)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }

    private func averageText(_ value: Double, _ low: Double?) -> String {
        if kind == "mmhg", let low { return "\(Int(value.rounded()))/\(Int(low.rounded())) mmHg" }
        return HealthFormat.string(value, kind: kind)
    }

    private func extreme(_ title: String, _ reading: HealthVitalReading, symbol: String) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 2) {
                RingMetricSymbol(name: metric.symbol, tint: metric.tint, size: 18)
                JcIcon(symbol, size: 12).foregroundStyle(metric.tint)
            }
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(HealthReadingsCard.text(reading, kind: kind))
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
            Text(reading.date.formatted(.dateTime.hour().minute())).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Reference

    private func marker(_ bar: HealthReferenceBar, _ points: [HealthVitalReading]) -> Double? {
        guard let slot = slot(points) else { return nil }
        return bar.field == "low" ? slot.low : slot.value
    }

    // MARK: Chart

    /// The band records every half hour: a missed one breaks the line over the gap.
    private func runs(_ points: [HealthVitalReading]) -> [[HealthVitalReading]] {
        var out: [[HealthVitalReading]] = []
        for p in points {
            if let last = out.last?.last, p.date.timeIntervalSince(last.date) <= 2400 {
                out[out.count - 1].append(p)
            } else {
                out.append([p])
            }
        }
        return out
    }

    private func shown(_ v: Double) -> Double { HealthFormat.shown(v, kind: kind) }

    private func chart(_ points: [HealthVitalReading]) -> some View {
        let start = model.day
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let values = points.flatMap { [$0.value, $0.diastolic].compactMap { $0 } }.map(shown)
        let domain = HealthChartScale.padded(values) ?? 0...1
        let picked = scrubbed == nil ? nil : slot(points)
        let runs = Array(runs(points).enumerated())
        return Chart {
            ForEach(runs, id: \.offset) { index, run in
                ForEach(run) { p in
                    if kind != "mmhg" {
                        AreaMark(x: .value("Time", p.date), yStart: .value("Floor", domain.lowerBound),
                                 yEnd: .value(metric.title, shown(p.value)), series: .value("Run", "a\(index)"))
                            .foregroundStyle(LinearGradient(colors: [metric.tint.opacity(0.28), metric.tint.opacity(0.02)],
                                                            startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.catmullRom)
                    }
                    LineMark(x: .value("Time", p.date), y: .value(metric.title, shown(p.value)),
                             series: .value("Run", "v\(index)"))
                        .foregroundStyle(metric.tint)
                        .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
                        .interpolationMethod(.catmullRom)
                    if let low = p.diastolic {
                        LineMark(x: .value("Time", p.date), y: .value("Diastolic", low), series: .value("Run", "d\(index)"))
                            .foregroundStyle(metric.tint.opacity(0.55))
                            .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
                            .interpolationMethod(.catmullRom)
                    }
                    if run.count < 3 {
                        PointMark(x: .value("Time", p.date), y: .value(metric.title, shown(p.value)))
                            .foregroundStyle(metric.tint)
                            .symbolSize(30)
                        if let low = p.diastolic {
                            PointMark(x: .value("Time", p.date), y: .value("Diastolic", low))
                                .foregroundStyle(metric.tint.opacity(0.55))
                                .symbolSize(30)
                        }
                    }
                }
            }
            if let picked {
                RuleMark(x: .value("When", picked.start.addingTimeInterval(900)))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .chartXScale(domain: start...end)
        .chartYScale(domain: domain)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [2, 4])).foregroundStyle(Color.primary.opacity(0.15))
                AxisValueLabel { Text(Self.axisLabel(value.as(Double.self) ?? 0)) }
            }
        }
        .chartXSelection(value: $scrubbed)
        .frame(height: 220)
    }

    /// The axis is in the shown unit: mmol/L-sized numbers keep a decimal.
    static func axisLabel(_ value: Double) -> String {
        value < 20 && value != value.rounded() ? String(format: "%.1f", value) : "\(Int(value.rounded()))"
    }
}

// MARK: Units

/// "Unit": the reading's unit where it has a choice (glucose, blood fats, uric acid), as the
/// band's own page ends with. The band and Jarvis's sentences follow it.
struct HealthUnitCard: View {
    let kind: String
    @AppStorage(GlucoseUnit.key) private var glucose: GlucoseUnit = .mmolL
    @AppStorage(BloodFatUnit.key) private var bloodFat: BloodFatUnit = .mmolL
    @AppStorage(UricAcidUnit.key) private var uricAcid: UricAcidUnit = .umolL

    var body: some View {
        switch kind {
        case "glucose":
            card(Binding(get: { glucose }, set: { glucose = $0; HealthUnitSync.push() }), GlucoseUnit.allCases, \.label)
        case "cholesterol", "triglycerides":
            card(Binding(get: { bloodFat }, set: { bloodFat = $0; HealthUnitSync.push() }), BloodFatUnit.allCases, \.label)
        case "uric_acid":
            card(Binding(get: { uricAcid }, set: { uricAcid = $0; HealthUnitSync.push() }), UricAcidUnit.allCases, \.label)
        default:
            EmptyView()
        }
    }

    private func card<U: Hashable & Identifiable>(_ selection: Binding<U>, _ options: [U],
                                                  _ label: KeyPath<U, String>) -> some View {
        CardGroup {
            Row {
                HStack {
                    Text("Unit")
                    Spacer()
                    Picker("Unit", selection: selection) {
                        ForEach(options) { Text($0[keyPath: label]).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 170)
                }
            }
        }
    }
}

/// The units the app shows, copied to the band (its own screens) and to Jarvis Health (the
/// sentences Jarvis writes about the readings).
enum HealthUnitSync {
    private static let sentKey = "healthUnitsSent"

    private static var units: [String: String] {
        ["glucose_unit": GlucoseUnit.current.rawValue, "blood_fat_unit": BloodFatUnit.current.rawValue,
         "uric_acid_unit": UricAcidUnit.current.rawValue]
    }

    /// Jarvis Health's copy, once per change (a choice made on the band page, or before the
    /// server kept one): its sentences then say mg/dL when the page does.
    static func sendIfChanged() async {
        let units = self.units
        let signature = units.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        guard UserDefaults.standard.string(forKey: sentKey) != signature else { return }
        guard (try? await HealthClient(spaceID: HealthSpace.shared).updateSettings(units)) != nil else { return }
        UserDefaults.standard.setValue(signature, forKey: sentKey)
    }

    static func push() {
        let glucose = GlucoseUnit.current, fat = BloodFatUnit.current, uric = UricAcidUnit.current
        Task { @MainActor in
            await sendIfChanged()
            let session = WearablesHub.shared.band.session
            try? await session.setUnit(.glucose, metric: glucose == .mmolL)
            try? await session.setUnit(.bloodFat, metric: fat == .mmolL)
            try? await session.setUnit(.uricAcid, metric: uric == .umolL)
        }
    }
}

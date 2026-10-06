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

/// A day's readings as the chart draws them: each half hour's average (the band records every
/// ten minutes; the band's own app draws the half hours).
struct HealthVitalDay: Equatable {
    struct Slot: Equatable, Identifiable {
        var start: Date
        var value: Double
        var low: Double?
        var count: Int

        var id: Date { start }
        var middle: Date { start.addingTimeInterval(900) }
    }

    /// Every reading, oldest first.
    var points: [HealthVitalReading]
    var slots: [Slot]
    /// Runs of half hours with no gap: the line breaks where one is missing.
    var runs: [[Slot]]

    init(_ history: HealthHistory, metric: HealthMetric) {
        points = (history.readings ?? []).filter { $0.metric == metric.rawValue }.sorted { $0.date < $1.date }
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: points) { p -> Date in
            let parts = calendar.dateComponents([.hour, .minute], from: p.date)
            return calendar.startOfDay(for: p.date)
                .addingTimeInterval(TimeInterval((parts.hour ?? 0) * 3600 + (parts.minute ?? 0) / 30 * 1800))
        }
        slots = grouped.keys.sorted().map { start in
            let inside = grouped[start]!
            let lows = inside.compactMap(\.diastolic)
            return Slot(start: start, value: inside.map(\.value).reduce(0, +) / Double(inside.count),
                        low: lows.isEmpty ? nil : lows.reduce(0, +) / Double(lows.count), count: inside.count)
        }
        var runs: [[Slot]] = []
        for slot in slots {
            if let last = runs.last?.last, slot.start.timeIntervalSince(last.start) <= 1800 {
                runs[runs.count - 1].append(slot)
            } else {
                runs.append([slot])
            }
        }
        self.runs = runs
    }

    /// The half hour nearest `date` (within two hours), else nil.
    func slot(near date: Date) -> Slot? {
        guard let nearest = slots.min(by: { abs($0.middle.timeIntervalSince(date)) < abs($1.middle.timeIntervalSince(date)) }),
              abs(nearest.middle.timeIntervalSince(date)) <= 7200 else { return nil }
        return nearest
    }
}

/// One vital's day from the server (`/health/history?range=D&end=`), each day kept once
/// loaded so stepping back and forth doesn't wait.
@MainActor
final class HealthVitalDayModel: ObservableObject {
    let metric: HealthMetric
    @Published private(set) var day: Date
    @Published private(set) var history: HealthHistory? {
        didSet { readings = history.map { HealthVitalDay($0, metric: metric) } }
    }
    /// The day worked out once per load, not on every frame of a scrub.
    @Published private(set) var readings: HealthVitalDay?
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
            guard key == self.key, fresh != history else { return }
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
    /// The half hour under the finger. Only a new half hour is a change: the drag moves every
    /// frame, and redrawing the page that often made scrubbing crawl.
    @State private var picked: Date?
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
            if let history = model.history, let day = model.readings {
                content(history, day)
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
            picked = nil
            await model.load()
        }
        .sensoryFeedback(.selection, trigger: picked)
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

    private var kind: String { model.history?.kind ?? "" }

    /// The scrubbed half hour, else the latest.
    private func slot(_ day: HealthVitalDay) -> HealthVitalDay.Slot? {
        if let picked { return day.slots.first { $0.start == picked } }
        return day.slots.last
    }

    private func content(_ history: HealthHistory, _ day: HealthVitalDay) -> some View {
        let slot = slot(day)
        return VStack(alignment: .leading, spacing: 20) {
            headline(slot, day: day)
                .padding(.horizontal, 24)
            CardGroup {
                if day.points.isEmpty {
                    Row(minHeight: 180) {
                        Text("No \(metric.inSentence) on this day.").font(.subheadline).foregroundStyle(.secondary)
                    }
                } else {
                    HealthVitalDayChart(day: day, kind: kind, tint: metric.tint, title: metric.title,
                                        start: model.day, picked: picked == nil ? nil : slot?.middle,
                                        selection: selection(day))
                        .equatable()
                        .padding(14)
                }
                if let average = history.headline.value, !day.points.isEmpty {
                    RowDivider()
                    Row {
                        HStack {
                            Text("Average for the whole day").font(.subheadline)
                            Spacer()
                            Text(text(average, history.headline.low))
                                .font(.system(.body, design: .rounded).weight(.semibold))
                                .monospacedDigit()
                        }
                    }
                }
            }
            if let lowest = day.points.min(by: { $0.value < $1.value }),
               let highest = day.points.max(by: { $0.value < $1.value }) {
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
                HealthReferenceCard(bars: bars, value: { bar in bar.field == "low" ? slot?.low : slot?.value },
                                    caption: slot.map(span) ?? model.day.formatted(.dateTime.month(.abbreviated).day()))
            }
            if !day.points.isEmpty {
                CardGroup("Highlights") {
                    Row {
                        Text(history.highlight).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 4)
                    }
                }
                HealthReadingsCard(readings: day.points.reversed(), kind: kind, bars: history.reference ?? [],
                                   timesOnly: true)
            }
            HealthUnitCard(kind: kind)
        }
    }

    /// The chart's selection, kept as the half hour it falls in.
    private func selection(_ day: HealthVitalDay) -> Binding<Date?> {
        Binding(get: { picked }, set: { date in
            let start = date.flatMap { day.slot(near: $0)?.start }
            if start != picked { picked = start }
        })
    }

    // MARK: Headline, as the other ranges write theirs

    /// "4:30–4:59 PM".
    private func span(_ slot: HealthVitalDay.Slot) -> String {
        let end = slot.start.addingTimeInterval(1740)
        return "\(slot.start.formatted(.dateTime.hour().minute()))–\(end.formatted(.dateTime.hour().minute()))"
    }

    private func headline(_ slot: HealthVitalDay.Slot?, day: HealthVitalDay) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text((slot.map { "\($0.count > 1 ? "Average" : "Reading") · \(span($0))" } ?? "Average").uppercased())
                .font(.caption.weight(.semibold))
                .kerning(0.4)
                .foregroundStyle(picked == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(JcTheme.accent))
            Text(slot.map { text($0.value, $0.low) } ?? "—")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.2), value: slot?.value)
            Text(picked == nil ? "\(day.points.count) reading\(day.points.count == 1 ? "" : "s") · latest half hour"
                 : "\(slot?.count ?? 0) reading\(slot?.count == 1 ? "" : "s") in this half hour")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func text(_ value: Double, _ low: Double?) -> String {
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
}

/// The day's line, redrawn only when the day, the unit or the picked half hour changes.
struct HealthVitalDayChart: View, Equatable {
    let day: HealthVitalDay
    let kind: String
    let tint: Color
    let title: String
    let start: Date
    let picked: Date?
    let selection: Binding<Date?>
    /// The shown unit, so a new one redraws.
    private let unitScale = HealthFormat.shown(1, kind: "glucose") + HealthFormat.shown(1, kind: "cholesterol")
        + HealthFormat.shown(1, kind: "uric_acid")

    init(day: HealthVitalDay, kind: String, tint: Color, title: String, start: Date, picked: Date?,
         selection: Binding<Date?>) {
        self.day = day
        self.kind = kind
        self.tint = tint
        self.title = title
        self.start = start
        self.picked = picked
        self.selection = selection
    }

    static func == (a: Self, b: Self) -> Bool {
        a.day == b.day && a.kind == b.kind && a.start == b.start && a.picked == b.picked && a.unitScale == b.unitScale
    }

    private func shown(_ v: Double) -> Double { HealthFormat.shown(v, kind: kind) }

    var body: some View {
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let values = day.slots.flatMap { [$0.value, $0.low].compactMap { $0 } }.map(shown)
        let domain = HealthChartScale.padded(values) ?? 0...1
        let runs = Array(day.runs.enumerated())
        return Chart {
            ForEach(runs, id: \.offset) { index, run in
                ForEach(run) { slot in
                    if kind != "mmhg" {
                        AreaMark(x: .value("Time", slot.middle), yStart: .value("Floor", domain.lowerBound),
                                 yEnd: .value(title, shown(slot.value)), series: .value("Run", "a\(index)"))
                            .foregroundStyle(LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0.02)],
                                                            startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                    }
                    LineMark(x: .value("Time", slot.middle), y: .value(title, shown(slot.value)),
                             series: .value("Run", "v\(index)"))
                        .foregroundStyle(tint)
                        .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
                        .interpolationMethod(.monotone)
                    if let low = slot.low {
                        LineMark(x: .value("Time", slot.middle), y: .value("Diastolic", low), series: .value("Run", "d\(index)"))
                            .foregroundStyle(tint.opacity(0.55))
                            .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
                            .interpolationMethod(.monotone)
                    }
                    if run.count < 3 {
                        PointMark(x: .value("Time", slot.middle), y: .value(title, shown(slot.value)))
                            .foregroundStyle(tint)
                            .symbolSize(30)
                        if let low = slot.low {
                            PointMark(x: .value("Time", slot.middle), y: .value("Diastolic", low))
                                .foregroundStyle(tint.opacity(0.55))
                                .symbolSize(30)
                        }
                    }
                }
            }
            if let picked {
                RuleMark(x: .value("When", picked))
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
        .chartXSelection(value: selection)
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

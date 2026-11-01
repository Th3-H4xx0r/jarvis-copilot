import Foundation

/// The band's battery over time: its level each time the phone reads it (`A0`), and what the
/// band was doing in between — a workout, a spot reading, its every-minute sensing, linked to the
/// phone — so the Battery page can draw the curve, find the charges and say where it went.
///
/// The band reports only a percentage, so every figure is measured from that: the drain between
/// two readings off the charger is shared out over what the band was doing in that time.
@MainActor
final class BandBatteryLog: ObservableObject {
    struct Sample: Codable, Equatable {
        var date: Date
        var percent: Int
        var charging: Bool
    }

    /// What the band was doing, most demanding first: a stretch with several counts as the first.
    enum Activity: String, Codable, CaseIterable {
        case workout, reading, sensing, linked
    }

    struct Span: Codable, Equatable {
        var kind: Activity
        var start: Date
        var end: Date
        /// For a reading, which (`BandMeasure.name`).
        var detail: String?
    }

    enum Event: String, Codable { case sync, find }

    struct Stamp: Codable, Equatable {
        var kind: Event
        var date: Date
    }

    private struct Stored: Codable {
        var samples: [Sample] = []
        var spans: [Span] = []
        var events: [Stamp] = []
        var open: [String: Span] = [:]
        var savedAt: Date?
    }

    static let retention: TimeInterval = 30 * 86_400
    /// An unchanged level is still written this often, so a flat stretch shows as observed.
    static let keepEvery: TimeInterval = 30 * 60
    /// The band's level is read this often while it's linked.
    static let readEvery: TimeInterval = 10 * 60

    @Published private(set) var samples: [Sample] = []
    @Published private(set) var spans: [Span] = []
    @Published private(set) var events: [Stamp] = []
    /// Spans under way, by kind.
    private var open: [Activity: Span] = [:]
    private let file: URL?
    var now: () -> Date = Date.init

    /// `file` nil keeps it in memory (tests).
    init(file: URL? = BandBatteryLog.defaultFile) {
        self.file = file
        guard let file, let data = try? Data(contentsOf: file),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        samples = stored.samples
        spans = stored.spans
        events = stored.events
        // The app was closed with these under way: the link and anything on it ended then;
        // the band's sensing carries on without the phone.
        let closedAt = stored.savedAt ?? stored.samples.last?.date ?? Date()
        for (name, span) in stored.open {
            guard let kind = Activity(rawValue: name) else { continue }
            if kind == .sensing {
                open[kind] = span
            } else if closedAt > span.start {
                spans.append(Span(kind: kind, start: span.start, end: closedAt, detail: span.detail))
            }
        }
    }

    nonisolated static var defaultFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BandBattery/log.json")
    }

    /// When the level was last read.
    var lastRead: Date? { samples.last?.date }

    func record(percent: Int, charging: Bool) {
        let date = now()
        guard (0...100).contains(percent) else { return }
        if let last = samples.last {
            guard date >= last.date else { return }
            if last.percent == percent, last.charging == charging,
               date.timeIntervalSince(last.date) < Self.keepEvery { return }
        }
        samples.append(Sample(date: date, percent: percent, charging: charging))
        save()
    }

    /// Starts or ends a stretch of `kind` (a no-op when it's already so).
    func set(_ kind: Activity, _ on: Bool, detail: String? = nil) {
        let date = now()
        if on {
            guard open[kind] == nil else { return }
            open[kind] = Span(kind: kind, start: date, end: date, detail: detail)
        } else {
            guard var span = open.removeValue(forKey: kind) else { return }
            span.end = date
            if span.end > span.start { spans.append(span) }
        }
        save()
    }

    func note(_ event: Event) {
        events.append(Stamp(kind: event, date: now()))
        save()
    }

    /// Everything so far, spans under way counted up to now.
    func report() -> BandBatteryReport {
        let date = now()
        let current = open.values.map { Span(kind: $0.kind, start: $0.start, end: date, detail: $0.detail) }
        return BandBatteryReport(samples: samples, spans: spans + current, events: events, now: date)
    }

    private func save() {
        let cutoff = now().addingTimeInterval(-Self.retention)
        samples.removeAll { $0.date < cutoff }
        spans.removeAll { $0.end < cutoff }
        events.removeAll { $0.date < cutoff }
        guard let file else { return }
        var stored = Stored(samples: samples, spans: spans, events: events, savedAt: now())
        stored.open = Dictionary(uniqueKeysWithValues: open.map { ($0.key.rawValue, $0.value) })
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(stored).write(to: file, options: .atomic)
    }
}

/// What the log says: the charges, the drain each day and on average, how long is left, and
/// where the battery went.
struct BandBatteryReport {
    typealias Sample = BandBatteryLog.Sample
    typealias Span = BandBatteryLog.Span
    typealias Activity = BandBatteryLog.Activity

    struct Charge: Equatable {
        var start: Date
        var end: Date
        var from: Int
        var to: Int
        /// Seen on the charger; false when the level just came back higher after a gap.
        var observed: Bool
        var ongoing: Bool
        var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    /// The fall in the level from one reading to the next, off the charger.
    struct Drain: Equatable {
        var start: Date
        var end: Date
        var points: Double
    }

    /// Where the battery went: what the band was doing, or nothing in particular (`kind` nil).
    struct Use: Equatable, Identifiable {
        var kind: Activity?
        var points: Double
        var seconds: TimeInterval
        var id: String { kind?.rawValue ?? "alone" }
        /// Points an hour while doing it.
        var perHour: Double? { seconds >= 600 ? points / seconds * 3600 : nil }
    }

    struct Day: Equatable, Identifiable {
        var start: Date
        var points: Double
        /// How much of the day the level was followed.
        var seconds: TimeInterval
        var id: Date { start }
    }

    let samples: [Sample]
    let spans: [Span]
    let events: [BandBatteryLog.Stamp]
    let now: Date
    let charges: [Charge]
    let drains: [Drain]

    /// A jump of this many points between two readings off the charger is a charge.
    static let chargeJump = 5
    /// Two readings further apart than this aren't joined: the band may have been off.
    static let longestGap: TimeInterval = 48 * 3600

    init(samples: [Sample], spans: [Span], events: [BandBatteryLog.Stamp] = [], now: Date) {
        self.samples = samples
        self.spans = spans
        self.events = events
        self.now = now
        charges = Self.charges(samples)
        drains = Self.drains(samples)
    }

    var latest: Sample? { samples.last }
    var lastCharge: Charge? { charges.last { !$0.ongoing } }
    var charging: Bool { latest?.charging ?? false }

    // MARK: Charges

    static func charges(_ samples: [Sample]) -> [Charge] {
        var out: [Charge] = []
        var current: Charge?
        var previous: Sample?
        for s in samples {
            if s.charging {
                // From the last level seen off the charger, if it's recent.
                let before = previous.flatMap { !$0.charging && s.date.timeIntervalSince($0.date) < 3 * 3600 ? $0 : nil }
                var charge = current ?? Charge(start: s.date, end: s.date, from: min(before?.percent ?? s.percent, s.percent),
                                               to: s.percent, observed: true, ongoing: true)
                charge.to = max(charge.to, s.percent)
                charge.end = s.date
                current = charge
            } else if var charge = current {
                // Off the charger: it may have gone on charging after the last reading on it.
                if s.percent > charge.to { charge.to = s.percent; charge.end = s.date }
                charge.ongoing = false
                out.append(charge)
                current = nil
            } else if let p = previous, !p.charging, s.percent - p.percent >= chargeJump {
                out.append(Charge(start: p.date, end: s.date, from: p.percent, to: s.percent,
                                  observed: false, ongoing: false))
            }
            previous = s
        }
        if let current { out.append(current) }
        return out
    }

    // MARK: Drain

    static func drains(_ samples: [Sample]) -> [Drain] {
        zip(samples, samples.dropFirst()).compactMap { a, b in
            guard !a.charging, !b.charging, b.percent <= a.percent,
                  b.date > a.date, b.date.timeIntervalSince(a.date) <= longestGap else { return nil }
            return Drain(start: a.date, end: b.date, points: Double(a.percent - b.percent))
        }
    }

    /// The drains within `since…now`, a drain across the edge counted for its share inside.
    func drains(since: Date) -> [Drain] {
        drains.compactMap { d in
            guard d.end > since else { return nil }
            guard d.start < since else { return d }
            let share = d.end.timeIntervalSince(since) / d.end.timeIntervalSince(d.start)
            return Drain(start: since, end: d.end, points: d.points * share)
        }
    }

    /// Points a day, from the stretches followed since `since` (gaps aren't counted as zero).
    func perDay(since: Date) -> Double? {
        let within = drains(since: since)
        let seconds = within.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        guard seconds >= 6 * 3600 else { return nil }
        return within.reduce(0) { $0 + $1.points } / seconds * 86_400
    }

    /// Points an hour lately: the last three days, else the last week.
    var recentPerHour: Double? {
        let rate = perDay(since: now.addingTimeInterval(-3 * 86_400)) ?? perDay(since: now.addingTimeInterval(-7 * 86_400))
        return rate.map { $0 / 24 }
    }

    /// How long the battery lasts at the recent rate, off the charger.
    var timeLeft: TimeInterval? {
        guard let latest, !latest.charging, let rate = recentPerHour, rate > 0.01 else { return nil }
        return Double(latest.percent) / rate * 3600
    }

    /// Each calendar day's drain, from `days` days ago to today.
    func days(_ days: Int, calendar: Calendar = .current) -> [Day] {
        let today = calendar.startOfDay(for: now)
        return (0..<days).reversed().compactMap { back in
            guard let start = calendar.date(byAdding: .day, value: -back, to: today),
                  let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
            var day = Day(start: start, points: 0, seconds: 0)
            for d in drains where d.end > start && d.start < end {
                let from = max(d.start, start), to = min(d.end, end)
                let length = d.end.timeIntervalSince(d.start)
                day.points += d.points * to.timeIntervalSince(from) / length
                day.seconds += to.timeIntervalSince(from)
            }
            return day
        }
    }

    // MARK: Where it went

    /// The drain since `since`, shared out over what the band was doing, most first.
    func uses(since: Date) -> [Use] {
        var totals: [String: Use] = [:]
        for d in drains(since: since) {
            let total = d.end.timeIntervalSince(d.start)
            for (kind, seconds) in Self.slices(d.start, d.end, spans: spans) where seconds > 0 {
                let id = kind?.rawValue ?? "alone"
                var use = totals[id] ?? Use(kind: kind, points: 0, seconds: 0)
                use.points += d.points * seconds / total
                use.seconds += seconds
                totals[id] = use
            }
        }
        return totals.values.sorted { $0.points > $1.points }
    }

    /// Seconds of `start…end` spent on each activity, a moment with several going to the first.
    static func slices(_ start: Date, _ end: Date, spans: [Span]) -> [Activity?: TimeInterval] {
        let inside = spans.filter { $0.end > start && $0.start < end }
        var edges = Set([start, end])
        for s in inside {
            edges.insert(max(s.start, start))
            edges.insert(min(s.end, end))
        }
        let sorted = edges.sorted()
        var out: [Activity?: TimeInterval] = [:]
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            let middle = a.addingTimeInterval(b.timeIntervalSince(a) / 2)
            let kind = Activity.allCases.first { k in inside.contains { $0.kind == k && $0.start <= middle && middle < $0.end } }
            out[kind, default: 0] += b.timeIntervalSince(a)
        }
        return out
    }

    // MARK: Activity

    func spans(_ kind: Activity, since: Date) -> [Span] {
        spans.filter { $0.kind == kind && $0.end > since }
    }

    func seconds(_ kind: Activity, since: Date) -> TimeInterval {
        spans(kind, since: since).reduce(0) { $0 + $1.end.timeIntervalSince(max($1.start, since)) }
    }

    func count(_ event: BandBatteryLog.Event, since: Date) -> Int {
        events.filter { $0.kind == event && $0.date >= since }.count
    }

    /// Days from one charge ending to the next starting, on average.
    var daysBetweenCharges: Double? {
        let done = charges.filter { !$0.ongoing }
        let gaps = zip(done, done.dropFirst()).map { $1.start.timeIntervalSince($0.end) }.filter { $0 > 3600 }
        guard !gaps.isEmpty else { return nil }
        return gaps.reduce(0, +) / Double(gaps.count) / 86_400
    }

    // MARK: Words

    static func duration(_ seconds: TimeInterval) -> String {
        if seconds >= 2 * 86_400 {
            let d = Int(seconds / 86_400), h = Int((seconds - Double(d) * 86_400) / 3600)
            return h == 0 ? "\(d) days" : "\(d) days \(h) h"
        }
        if seconds >= 86_400 {
            let h = Int((seconds - 86_400) / 3600)
            return h == 0 ? "1 day" : "1 day \(h) h"
        }
        return BatteryUsageSummary.duration(seconds)
    }

    static func title(_ kind: Activity?) -> String {
        switch kind {
        case .workout: return "Workouts"
        case .reading: return "Spot readings"
        case .sensing: return "All-day sensing"
        case .linked: return "Linked to the phone"
        case nil: return "On its own"
        }
    }

    static func symbol(_ kind: Activity?) -> String {
        switch kind {
        case .workout: return "figure.run"
        case .reading: return "waveform.path.ecg"
        case .sensing: return "heart.text.square"
        case .linked: return "dot.radiowaves.left.and.right"
        case nil: return "applewatch"
        }
    }

    static func about(_ kind: Activity?) -> String {
        switch kind {
        case .workout: return "Its sensor and the link on the whole time"
        case .reading: return "Readings asked for: heart rate, BP, SpO₂, ECG…"
        case .sensing: return "Pulse each minute, HRV each 5 min, by the band"
        case .linked: return "Bluetooth held open to the phone"
        case nil: return "Steps, screen, notifications, the clock"
        }
    }

    /// For Jarvis (`band_get_status`).
    var json: [String: Any] {
        var out: [String: Any] = [:]
        let week = now.addingTimeInterval(-7 * 86_400)
        if let rate = perDay(since: week) {
            out["battery_drain_per_day_percent"] = (rate * 10).rounded() / 10
        }
        if let left = timeLeft { out["battery_hours_left"] = Int((left / 3600).rounded()) }
        if let charge = lastCharge {
            out["last_charged"] = ISO8601DateFormatter().string(from: charge.end)
            out["last_charged_from_percent"] = charge.from
            out["last_charged_to_percent"] = charge.to
        }
        let uses = uses(since: week)
        let total = uses.reduce(0) { $0 + $1.points }
        if total > 0 {
            out["battery_use_last_7_days"] = uses.map {
                ["what": Self.title($0.kind), "percent_points": ($0.points * 10).rounded() / 10,
                 "share": Int(($0.points / total * 100).rounded())] as [String: Any]
            }
        }
        return out
    }
}

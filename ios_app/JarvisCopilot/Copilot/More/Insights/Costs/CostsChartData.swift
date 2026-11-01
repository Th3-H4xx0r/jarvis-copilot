import Foundation

/// Shaping for the Costs tab, kept free of SwiftUI like `InsightsChartData`:
/// pure functions over the parsed models, so the grouping, the deltas and the
/// labels are unit tested without hosting a view. Colours come back as palette
/// SLOTS; the view maps a slot to a colour derived from `JcAccent`.

/// One coloured series of the stacked daily chart: a top service, or "Other".
struct CostSeries: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    /// The series' total over the period (what it was ranked by).
    var total: Double
    /// Palette slot: 0… for the ranked services, `CostsUI.otherSlot` for Other.
    var slot: Int

    var isOther: Bool { id == CostsUI.otherID }
}

/// One bar of the stacked chart: a day (or, for a year, a week).
struct CostStackDay: Identifiable, Equatable, Sendable {
    /// First day in the bucket, "2026-10-03".
    var day: String
    /// Last day in the bucket (== `day` for a daily chart).
    var lastDay: String
    /// Local midnight opening `day`.
    var date: Date
    /// Local midnight after `lastDay`: the bar spans `date..<end`.
    var end: Date
    var total: Double
    /// Series id → amount, only non-zero parts.
    var parts: [String: Double]

    var id: String { day }
    /// Where the bar's middle sits on the time axis (what a scrub snaps to).
    var center: Date { date.addingTimeInterval(end.timeIntervalSince(date) / 2) }
}

/// One rectangle of the stacked chart, flattened for `Chart`. Drawn as an
/// explicit `date..<end` × `low...high` rectangle rather than a `unit:` bar:
/// Swift Charts bins a `unit: .weekOfYear` value into the CALENDAR week, so
/// buckets counted back from today drew a few days off their own dates, the
/// short leftover bucket of a 90-day or 1-year window landed in the same week
/// as its neighbour, and a scrub picked the bar beside the one under the finger.
struct CostStackSegment: Identifiable, Equatable, Sendable {
    var day: String
    var lastDay: String
    var date: Date
    var end: Date
    var seriesID: String
    var amount: Double
    /// Where the segment sits in its bar's stack (series order, positives up
    /// from 0, negatives — a credit — down from it).
    var low: Double
    var high: Double

    var id: String { "\(day)|\(seriesID)" }
}

struct CostsStack: Equatable, Sendable {
    /// Ranked services first, then "Other" when anything was grouped into it.
    var series: [CostSeries] = []
    var days: [CostStackDay] = []
    /// 1 for a daily chart, 7 when a long window is bucketed into weeks.
    var bucketDays = 1
    /// Days in the window (the bars can be fewer: a week holds seven).
    var dayCount = 0

    /// Flattened in series order, so every bar stacks the same way.
    var segments: [CostStackSegment] {
        days.flatMap { day in
            var up = 0.0, down = 0.0
            return series.compactMap { s -> CostStackSegment? in
                guard let amount = day.parts[s.id], amount != 0 else { return nil }
                let low: Double
                if amount > 0 { low = up; up += amount } else { low = down + amount; down += amount }
                return CostStackSegment(day: day.day, lastDay: day.lastDay, date: day.date, end: day.end, seriesID: s.id,
                                        amount: amount, low: low, high: low + abs(amount))
            }
        }
    }

    var hasSpend: Bool { days.contains { $0.total > 0 } }

    /// The average bar: a day's spend, or a full week's on a weekly chart. Taken
    /// over the window's DAYS, not the bars — a year is 52 weeks and a day, and
    /// dividing by its 53 bars understated every week.
    func averagePerBar(total: Double) -> Double {
        guard dayCount > 0 else { return 0 }
        return total / Double(dayCount) * Double(bucketDays)
    }

    /// The palette slot a service is drawn in: its own when it ranked, Other's
    /// when it was grouped, nil when it spent nothing in the period.
    func slot(for serviceID: String) -> Int? {
        if let own = series.first(where: { $0.id == serviceID && !$0.isOther }) { return own.slot }
        return grouped.contains(serviceID) ? CostsUI.otherSlot : nil
    }

    /// Ids folded into "Other".
    var grouped: Set<String> = []
}

/// One bar of a service's chart: a day, or a week on long windows.
struct CostDetailBar: Identifiable, Equatable, Sendable {
    var day: String
    var lastDay: String
    /// Local midnight opening `day`; the bar spans `date..<end`.
    var date: Date
    /// Local midnight after `lastDay`.
    var end: Date
    var effective: Double
    var billing: Double?
    var estimate: Double?
    /// Every day in it came from Jarvis's own count (shown with "≈").
    var onlyEstimated: Bool
    var units: CostUnits

    var id: String { day }
    var center: Date { date.addingTimeInterval(end.timeIntervalSince(date) / 2) }
}

/// The month-to-date vs budget bar.
struct CostsBudgetState: Equatable, Sendable {
    var budget: Double
    var spent: Double
    var projected: Double
    /// spent / budget (not clamped — over budget reads > 1).
    var fraction: Double
    var projectedFraction: Double
    var percentUsed: Double
    var tone: MoreTone

    var isOver: Bool { spent > budget }
    var projectedOver: Bool { projected > budget }
}

enum CostsUI {
    static let otherID = "_other"
    static let otherSlot = -1
    /// How many services get their own colour before the rest fold into Other.
    static let topServices = 5
    /// Windows longer than this draw weekly bars (90d, 1y); shorter ones daily.
    static let weeklyAfterDays = 62

    static func bucketDays(for dayCount: Int) -> Int { dayCount > weeklyAfterDays ? 7 : 1 }

    /// Split `count` items into buckets of `size`, counted back from the end so
    /// the latest bucket is whole (ending today); the leftover opens the range.
    static func bucketRanges(count: Int, size: Int) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var index = count
        while index > 0 {
            let from = max(0, index - size)
            out.insert(from..<index, at: 0)
            index = from
        }
        return out
    }

    // MARK: Money

    /// One formatter per precision, built once: `money` runs for every chart
    /// segment's VoiceOver value, on every scrub frame.
    private static func makeMoneyFormatter(decimals: Int) -> NumberFormatter {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.groupingSeparator = ","
        f.decimalSeparator = "."
        f.minimumFractionDigits = decimals
        f.maximumFractionDigits = decimals
        return f
    }

    private static let wholeFormatter = makeMoneyFormatter(decimals: 0)
    private static let centsFormatter = makeMoneyFormatter(decimals: 2)

    private static func grouped(_ value: Double, decimals: Int) -> String {
        let f = decimals == 0 ? wholeFormatter : centsFormatter
        return f.string(from: NSNumber(value: value)) ?? String(format: "%.\(decimals)f", value)
    }

    /// "$309.71", "$12,500", "<$0.01", "$0". `estimated` prefixes "≈ " on a
    /// non-zero amount — Jarvis's own count, not the provider's bill.
    static func money(_ value: Double, estimated: Bool = false) -> String {
        let a = abs(value)
        let sign = value < 0 ? "-" : ""
        let core: String
        if a == 0 {
            core = "$0"
        } else if a < 0.005 {
            core = "<$0.01"
        } else if a >= 10_000 {
            core = "\(sign)$\(grouped(a, decimals: 0))"
        } else {
            core = "\(sign)$\(grouped(a, decimals: 2))"
        }
        return estimated && a != 0 ? "≈ \(core)" : core
    }

    /// Axis labels: "$0", "$5", "$2.5", "$1.2K".
    static func axisMoney(_ value: Double) -> String {
        let a = abs(value)
        if a >= 1000 { return String(format: "$%.1fK", value / 1000) }
        if a == a.rounded() { return String(format: "$%.0f", value) }
        if a >= 1 { return String(format: "$%.1f", value) }
        return String(format: "$%.2f", value)
    }

    /// "$200/mo", "$9.99/mo", "$120/yr".
    static func planPrice(_ amount: Double, interval: String) -> String {
        let core = amount == amount.rounded() ? "$\(grouped(amount, decimals: 0))"
                                              : "$\(grouped(amount, decimals: 2))"
        return core + (interval == "year" ? "/yr" : "/mo")
    }

    /// A typed price → dollars. Tolerates "$20", "1,200", " 9.99 ". nil when
    /// it isn't a non-negative number.
    static func parseAmount(_ text: String) -> Double? {
        let cleaned = text.replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let value = Double(cleaned), value.isFinite, value >= 0 else { return nil }
        return value
    }

    /// The text an amount field starts with: "200", "9.99".
    static func amountText(_ amount: Double) -> String {
        amount == amount.rounded() ? String(format: "%.0f", amount) : String(format: "%.2f", amount)
    }

    // MARK: Headline

    /// Change vs the previous period in percent, nil when there's nothing to
    /// compare with (no previous period, or it cost nothing).
    static func deltaPercent(current: Double, previous: Double?) -> Double? {
        guard let previous, previous > 0 else { return nil }
        return (current - previous) / previous * 100
    }

    /// "+24%", "−5%", "0%".
    static func deltaText(_ percent: Double) -> String {
        let rounded = Int(percent.rounded())
        if rounded > 0 { return "+\(rounded)%" }
        if rounded < 0 { return "−\(abs(rounded))%" }
        return "0%"
    }

    /// More spend is the thing to notice (amber); less is good news.
    static func deltaTone(_ percent: Double) -> MoreTone {
        let rounded = Int(percent.rounded())
        if rounded > 0 { return .amber }
        if rounded < 0 { return .success }
        return .muted
    }

    /// The period total split by where it came from, largest first:
    /// [("Plans", 225.25), ("Estimated", 84.46)] — sums back to the period total.
    static func sourceSplit(_ totals: CostsTotals) -> [(label: String, amount: Double, estimated: Bool)] {
        let order = ["billing", "subscription", "estimate"]
        return totals.bySource
            .filter { $0.value > 0 }
            .sorted { $0.value == $1.value ? (order.firstIndex(of: $0.key) ?? 9) < (order.firstIndex(of: $1.key) ?? 9)
                                           : $0.value > $1.value }
            .map { (sourceLabel($0.key), $0.value, $0.key == "estimate") }
    }

    static func sourceLabel(_ key: String) -> String {
        switch key {
        case "billing": return "Billed"
        case "subscription": return "Plans"
        case "estimate": return "Estimated"
        default: return key.capitalized
        }
    }

    /// The headline's total gets "≈" only when ALL of it is an estimate.
    static func periodIsEstimate(_ totals: CostsTotals) -> Bool {
        let positive = totals.bySource.filter { $0.value > 0 }
        return !positive.isEmpty && positive.keys.allSatisfy { $0 == "estimate" }
    }

    // MARK: Budget

    static func budgetState(totals: CostsTotals, budget: CostsBudget) -> CostsBudgetState? {
        guard let limit = budget.monthlyUSD, limit > 0 else { return nil }
        let spent = totals.monthToDate
        let projected = max(totals.projectedMonth, spent)
        let fraction = spent / limit
        let tone: MoreTone = spent > limit ? .danger : (projected > limit ? .amber : .cyan)
        return CostsBudgetState(budget: limit, spent: spent, projected: projected,
                                fraction: fraction, projectedFraction: projected / limit,
                                percentUsed: budget.usedPercent ?? fraction * 100, tone: tone)
    }

    /// "On track for $281.18 — $131.18 over" / "On track for $120.00 — $30.00 to spare".
    static func budgetProjection(_ state: CostsBudgetState) -> String {
        if state.isOver {
            return "\(money(state.spent - state.budget)) over budget"
        }
        let gap = state.budget - state.projected
        let tail = gap < 0 ? "\(money(-gap)) over" : "\(money(gap)) to spare"
        return "On track for \(money(state.projected)) — \(tail)"
    }

    // MARK: Days

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// "2026-10-03" → local midnight that day (what the chart's x axis plots).
    static func date(fromDay day: String) -> Date? {
        dayFormatter.date(from: String(day.prefix(10)))
    }

    static func dayString(_ date: Date) -> String { dayFormatter.string(from: date) }

    /// Local midnight after `day` — where a bar for that day ends.
    static func dayEnd(_ day: String) -> Date? {
        guard let start = date(fromDay: day) else { return nil }
        return Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: start)
    }

    /// Every day from `start` to `end` inclusive, capped at 400.
    static func days(from start: String, to end: String) -> [String] {
        guard let first = date(fromDay: start), let last = date(fromDay: end), first <= last else { return [] }
        var out: [String] = []
        var cursor = first
        let calendar = Calendar(identifier: .gregorian)
        while cursor <= last && out.count < 400 {
            out.append(dayString(cursor))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return out
    }

    /// `count` days ending at `end` inclusive.
    static func days(endingAt end: String, count: Int) -> [String] {
        guard count > 0, let last = date(fromDay: end),
              let first = Calendar(identifier: .gregorian).date(byAdding: .day, value: -(count - 1), to: last)
        else { return [] }
        return days(from: dayString(first), to: end)
    }

    /// "Oct 3".
    static func shortDay(_ day: String) -> String {
        guard let d = date(fromDay: day) else { return day }
        return d.formatted(.dateTime.month(.abbreviated).day())
    }

    /// "Oct 3 – Nov 1"; with years when the range crosses one, so a year's
    /// window doesn't read "Nov 2 – Nov 1".
    static func periodLabel(start: String, end: String) -> String {
        guard !start.isEmpty, !end.isEmpty else { return "" }
        if start.prefix(4) != end.prefix(4), let a = date(fromDay: start), let b = date(fromDay: end) {
            let style = Date.FormatStyle.dateTime.month(.abbreviated).day().year()
            return "\(a.formatted(style)) – \(b.formatted(style))"
        }
        return "\(shortDay(start)) – \(shortDay(end))"
    }

    // MARK: Stacked chart

    /// Rank services by their period spend, give the top `top` their own
    /// series and fold the rest into "Other". Windows over `weeklyAfterDays`
    /// are bucketed into weeks (counted back from the last day, so the latest bar
    /// is a full week ending today).
    static func stack(daily: [CostsDay], names: [String: String],
                      top: Int = topServices) -> CostsStack {
        guard !daily.isEmpty else { return CostsStack() }
        var totals: [String: Double] = [:]
        for day in daily {
            for (sid, amount) in day.byService { totals[sid, default: 0] += amount }
        }
        let ranked = totals.filter { $0.value > 0 }
            .sorted { $0.value == $1.value ? (names[$0.key] ?? $0.key) < (names[$1.key] ?? $1.key)
                                           : $0.value > $1.value }
        let kept = ranked.prefix(top)
        var series = kept.enumerated().map { index, entry in
            CostSeries(id: entry.key, name: names[entry.key] ?? entry.key, total: entry.value, slot: index)
        }
        let keptIDs = Set(kept.map(\.key))
        // Everything not kept: the long tail, and any service whose period nets
        // out negative (a credit), which ranking skips but the bars still hold.
        let restIDs = Set(totals.filter { $0.value != 0 && !keptIDs.contains($0.key) }.map(\.key))
        if !restIDs.isEmpty {
            series.append(CostSeries(id: otherID, name: "Other",
                                     total: restIDs.reduce(0) { $0 + (totals[$1] ?? 0) }, slot: otherSlot))
        }

        let bucket = bucketDays(for: daily.count)
        let chunks = bucketRanges(count: daily.count, size: bucket).map { Array(daily[$0]) }

        let days: [CostStackDay] = chunks.compactMap { chunk in
            guard let first = chunk.first, let last = chunk.last,
                  let date = date(fromDay: first.day), let end = dayEnd(last.day) else { return nil }
            var parts: [String: Double] = [:]
            var total = 0.0
            for day in chunk {
                for (sid, amount) in day.byService {
                    let key = keptIDs.contains(sid) ? sid : otherID
                    parts[key, default: 0] += amount
                    total += amount
                }
            }
            return CostStackDay(day: first.day, lastDay: last.day, date: date, end: end, total: total,
                                parts: parts.filter { $0.value != 0 })
        }
        var stack = CostsStack(series: series, days: days, bucketDays: bucket, dayCount: daily.count)
        stack.grouped = restIDs
        return stack
    }

    /// The bar's date as a readout: "Oct 11", or "Oct 6 – Oct 12" for a week.
    static func barLabel(_ day: CostStackDay) -> String { barLabel(day: day.day, lastDay: day.lastDay) }

    static func barLabel(day: String, lastDay: String) -> String {
        day == lastDay ? shortDay(day) : "\(shortDay(day)) – \(shortDay(lastDay))"
    }

    // MARK: Service rows

    /// "7,649 calls · 240M tokens" — the first two counts a service has.
    static func unitsSummary(_ units: CostUnits, limit: Int = 2) -> String {
        var parts: [String] = []
        if let calls = units.calls, calls > 0 { parts.append(count(calls, "call")) }
        if let tokens = units.totalTokens, tokens > 0 { parts.append("\(Insights.formatTokensCompact(tokens)) tokens") }
        if let searches = units.searches, searches > 0 {
            parts.append(count(searches, "search", plural: "searches"))
        }
        if let requests = units.requests, requests > 0 {
            parts.append(count(requests, "request"))
        }
        if let seconds = units.audioSeconds, seconds > 0 { parts.append("\(audioDuration(seconds)) audio") }
        if let bytes = units.bytes, bytes > 0 { parts.append("\(Insights.formatBytes(bytes)) sent") }
        return parts.prefix(limit).joined(separator: " · ")
    }

    /// "1 call", "7,649 calls".
    static func count(_ n: Int, _ singular: String, plural: String? = nil) -> String {
        "\(Insights.formatTokenCount(n)) \(n == 1 ? singular : (plural ?? singular + "s"))"
    }

    /// "45 s", "30 min", "2.5 h".
    static func audioDuration(_ seconds: Double) -> String {
        if seconds < 60 { return "\(Int(seconds.rounded())) s" }
        if seconds < 3600 { return "\(Int((seconds / 60).rounded())) min" }
        let hours = seconds / 3600
        return hours == hours.rounded() ? "\(Int(hours)) h" : String(format: "%.1f h", hours)
    }

    /// The muted line under a service's name.
    static func serviceSubtitle(_ s: CostService) -> String {
        var parts: [String] = []
        if let sub = s.subscription {
            if let plan = sub.plan { parts.append(plan) }
            parts.append(planPrice(sub.amountUSD, interval: sub.interval))
        } else if s.status == .needsPrice {
            parts.append("No price set")
        }
        // One count at most: the row is narrow, and the sheet has the rest.
        if s.subscription == nil {
            let units = unitsSummary(s.units, limit: 1)
            if !units.isEmpty { parts.append(units) }
        }
        if parts.isEmpty { parts.append(s.category) }
        return parts.joined(separator: " · ")
    }

    /// "Would have cost ≈ $7.10 on the API" for calls a plan covered.
    static func apiEquivalentLine(_ s: CostService) -> String? {
        guard s.kind == .subscription, let usd = s.units.apiEquivUSD, usd > 0 else { return nil }
        return "These calls would have cost \(money(usd, estimated: true)) on the API"
    }

    /// The status chip.
    static func statusBadge(_ status: CostStatus) -> (label: String, tone: MoreTone) {
        switch status {
        case .billing: return ("Billing API", .success)
        case .estimated: return ("Estimated", .cyan)
        case .subscription: return ("Plan", .blue)
        case .needsPrice: return ("Needs price", .amber)
        case .free: return ("Free", .muted)
        case .error: return ("Error", .danger)
        case .unknown: return ("Unknown", .muted)
        }
    }

    /// "Balance $12.30" / "Balance $12.30 of $50.00".
    static func balanceText(_ s: CostService) -> String? {
        guard let balance = s.balanceUSD else { return nil }
        if let limit = s.limitUSD, limit > 0 { return "Balance \(money(balance)) of \(money(limit))" }
        return "Balance \(money(balance))"
    }

    // MARK: Service detail

    /// One row per day of the period, oldest first. The server sends every day
    /// (zero rows included); an older server sent only days with data, so
    /// those rows are laid over `period` with zeros filling the gaps.
    static func detailDays(_ detail: CostServiceDetail, period: [String]) -> [CostDetailDay] {
        if detail.days > 0, detail.daily.count == detail.days { return detail.daily }
        var byDay: [String: CostDetailDay] = [:]
        for row in detail.daily { byDay[row.day] = row }
        let days = period.isEmpty ? detail.daily.map(\.day) : period
        return days.map { byDay[$0] ?? CostDetailDay(day: $0) }
    }

    /// The service's period, from the overview's window when it matches the
    /// detail's length, else counted back from the detail's last day (or today).
    static func detailPeriod(_ detail: CostServiceDetail, overview: CostsOverview) -> [String] {
        let count = detail.days > 0 ? detail.days : detail.service.spark.count
        if overview.days == count, !overview.start.isEmpty, !overview.end.isEmpty {
            let span = days(from: overview.start, to: overview.end)
            if span.count == count { return span }
        }
        let end = [overview.end, detail.daily.last?.day ?? ""].filter { !$0.isEmpty }.max()
            ?? dayString(Date())
        return days(endingAt: end, count: max(count, 1))
    }

    /// The per-service chart's bars: one per day, or per week past
    /// `weeklyAfterDays` (like the overview's).
    static func detailBars(_ days: [CostDetailDay]) -> [CostDetailBar] {
        let bucket = bucketDays(for: days.count)
        return bucketRanges(count: days.count, size: bucket).compactMap { range in
            let chunk = days[range]
            guard let first = chunk.first, let last = chunk.last,
                  let date = date(fromDay: first.day), let end = dayEnd(last.day) else { return nil }
            func total(_ key: KeyPath<CostDetailDay, Double?>) -> Double? {
                let values = chunk.compactMap { $0[keyPath: key] }
                return values.isEmpty ? nil : values.reduce(0, +)
            }
            let sources = Set(chunk.compactMap(\.source))
            return CostDetailBar(day: first.day, lastDay: last.day, date: date, end: end,
                                 effective: chunk.reduce(0) { $0 + $1.effective },
                                 billing: total(\.billing), estimate: total(\.estimate),
                                 onlyEstimated: sources == ["estimate"],
                                 units: chunk.reduce(CostUnits()) { $0.adding($1.units) })
        }
    }

    /// Both a provider bill and Jarvis's estimate exist in the window — the
    /// chart then shows the estimate alongside the billed bars.
    static func showsBillingVsEstimate(_ bars: [CostDetailBar], kind: CostKind) -> Bool {
        kind == .usage && bars.contains { $0.billing != nil } && bars.contains { ($0.estimate ?? 0) > 0 }
    }

    /// What VoiceOver reads for one bar of a service's chart: "$10.88, 438 calls",
    /// or "billed $9.20, estimated $10.88" when both exist.
    static func detailAccessibilityValue(_ bar: CostDetailBar) -> String {
        var parts = [money(bar.effective, estimated: bar.onlyEstimated)]
        if let billing = bar.billing, let estimate = bar.estimate, estimate > 0 {
            parts = ["billed \(money(billing))", "estimated \(money(estimate, estimated: true))"]
        }
        let units = unitsSummary(bar.units, limit: 1)
        if !units.isEmpty { parts.append(units) }
        return parts.joined(separator: ", ")
    }

    /// "Oct 11 · $10.88 · 438 calls" — the detail chart's scrub readout.
    static func detailReadout(_ bar: CostDetailBar) -> String {
        let label = barLabel(day: bar.day, lastDay: bar.lastDay)
        var parts = [label, money(bar.effective, estimated: bar.onlyEstimated)]
        if let billing = bar.billing, let estimate = bar.estimate, estimate > 0 {
            parts = [label, "billed \(money(billing))", "est. \(money(estimate, estimated: true))"]
        }
        let units = unitsSummary(bar.units, limit: 1)
        if !units.isEmpty { parts.append(units) }
        return parts.joined(separator: " · ")
    }
}

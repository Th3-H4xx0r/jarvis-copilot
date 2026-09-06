import Foundation

/// Chart/table shaping for the Insights screen, ported from the presentation half
/// of `pages/more/insights_page.dart`.
///
/// Deliberately free of SwiftUI: everything here is a pure function over the
/// parsed store models, so the shaping (which is where the bugs live) is unit
/// tested without hosting a view. Colours come back as hex so this layer keeps
/// no dependency on `JcTheme`; the view maps them with `Color(jcHex:)`.

/// One day's stacked bar in the daily-token chart.
struct InsightsDailyBar: Identifiable, Equatable, Sendable {
    var label: String
    var input: Double
    var output: Double

    var id: String { label }
    var total: Double { input + output }
}

/// One bucket of `activity_by_hour` (0…23).
struct InsightsHourBar: Identifiable, Equatable, Sendable {
    var hour: Int
    var sessions: Double

    var id: Int { hour }
    /// "00", "13" — a fixed-width axis label.
    var label: String { String(format: "%02d", hour) }
}

/// One bucket of `activity_by_day` ("Mon", "Tue", …).
struct InsightsDayBar: Identifiable, Equatable, Sendable {
    var day: String
    var sessions: Double

    var id: String { day }
}

/// One section of a message's input composition, largest first.
struct InsightsCompositionSlice: Identifiable, Equatable, Sendable {
    var key: String
    var tokens: Double
    /// 0…100 share of the message's composition total.
    var percent: Double

    var id: String { key }
    var label: String { InsightsUI.sectionLabel(key) }
    var colorHex: UInt32 { InsightsUI.sectionColorHex(key) }
}

enum InsightsUI {

    // MARK: Daily tokens

    /// "2026-06-21" → "06-21"; anything shorter passes through unchanged.
    static func dayLabel(_ date: Any?) -> String {
        let s = MoreJSON.text(date)
        guard s.count >= 10 else { return s }
        return String(s.dropFirst(5))
    }

    /// Shape `daily_tokens` for the chart: drop the leading all-zero days (a 1y
    /// window is mostly empty for a new install) and keep at most the last 30
    /// buckets so the chart stays readable. Mirrors `_DailyTokensCard._trim`.
    static func dailyBars(_ rows: [JSONObject]) -> [InsightsDailyBar] {
        let bars = rows.map {
            InsightsDailyBar(label: dayLabel($0["date"]),
                             input: Insights.number($0["input_tokens"]),
                             output: Insights.number($0["output_tokens"]))
        }
        guard !bars.isEmpty else { return [] }
        var start = 0
        while start < bars.count - 1 && bars[start].total == 0 { start += 1 }
        let trimmed = Array(bars[start...])
        return trimmed.count > 30 ? Array(trimmed.suffix(30)) : trimmed
    }

    /// True when at least one bar carries usage — otherwise the card shows its
    /// empty block rather than a flat axis.
    static func hasUsage(_ bars: [InsightsDailyBar]) -> Bool {
        bars.contains { $0.total > 0 }
    }

    // MARK: Activity

    /// `activity_by_hour` rows → 0…23 buckets, out-of-range hours dropped and
    /// duplicates summed (the server occasionally reports a bucket twice when a
    /// window straddles a DST change).
    static func hourBars(_ rows: [JSONObject]) -> [InsightsHourBar] {
        var totals: [Int: Double] = [:]
        for row in rows {
            let hour = MoreJSON.int(row["hour"], or: -1)
            guard (0...23).contains(hour) else { continue }
            totals[hour, default: 0] += Insights.number(row["sessions"])
        }
        return totals.keys.sorted().map { InsightsHourBar(hour: $0, sessions: totals[$0] ?? 0) }
    }

    /// `activity_by_day` rows → weekday buckets in the server's order, unlabelled
    /// rows dropped.
    static func dayBars(_ rows: [JSONObject]) -> [InsightsDayBar] {
        rows.compactMap { row in
            guard let day = MoreJSON.nonEmpty(row["day"]) else { return nil }
            return InsightsDayBar(day: day, sessions: Insights.number(row["sessions"]))
        }
    }

    // MARK: Composition

    /// `{section: tokens}` → slices sorted by size, each with its percentage of
    /// the message total. Non-positive entries are already dropped upstream; a
    /// zero total yields no slices (rather than a divide-by-zero).
    static func compositionSlices(_ composition: [String: Double]) -> [InsightsCompositionSlice] {
        let positive = composition.filter { $0.value > 0 }
        let total = positive.values.reduce(0, +)
        guard total > 0 else { return [] }
        return positive
            // Ties sort by key so the bar's colour order is stable between renders.
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { InsightsCompositionSlice(key: $0.key, tokens: $0.value,
                                            percent: $0.value / total * 100) }
    }

    /// Section → human label, mirroring the web panel's `_INSIGHTS_SECTION_META`.
    /// An unknown key shows verbatim — better a raw `system_message` than "Other".
    static func sectionLabel(_ key: String) -> String {
        switch key {
        case "identity":             return "Identity / SOUL.md"
        case "behavioral_guidance":  return "Behavioral guidance"
        case "tool_use_guidance":    return "Tool-use guidance"
        case "lazy_manifest":        return "Deferred-tools manifest"
        case "skills_catalog":       return "Skills catalog"
        case "env_profile":          return "Environment & profile"
        case "context_files":        return "Context files"
        case "memory":               return "Memory (MEMORY/USER.md)"
        case "external_memory":      return "External memory"
        case "timestamp":            return "Timestamp"
        case "system_prompt":        return "System prompt"
        case "tool_schemas":         return "Tool schemas"
        case "conversation_history": return "Conversation history"
        case "user_message":         return "User message"
        case "other":                return "Other (system)"
        default:                     return key
        }
    }

    /// Section → colour, mirroring the web panel's `_INSIGHTS_SECTION_META`.
    static func sectionColorHex(_ key: String) -> UInt32 {
        switch key {
        case "identity":             return 0x7C5CFF
        case "behavioral_guidance":  return 0x4F8CFF
        case "tool_use_guidance":    return 0x3FB6C9
        case "lazy_manifest":        return 0x2DBF7E
        case "skills_catalog":       return 0x8BC34A
        case "env_profile":          return 0xC9B03F
        case "context_files":        return 0xE0913A
        case "memory":               return 0xE0573A
        case "external_memory":      return 0xD24B86
        case "timestamp":            return 0x9AA0A6
        case "system_prompt":        return 0x7C5CFF
        case "tool_schemas":         return 0xA06BFF
        case "conversation_history": return 0x5B6FB0
        case "user_message":         return 0x34C759
        default:                     return 0x6B7280
        }
    }

    // MARK: System health

    /// The section only renders when a metric actually arrived.
    ///
    /// The Flutter page also honoured `available != false`, but `SystemHealth`
    /// collapses a MISSING `available` to false, so that check can't be restated
    /// here without hiding a healthy host. Presence of a metric is the same
    /// signal in every payload the server actually sends.
    static func healthIsAvailable(_ health: SystemHealth) -> Bool {
        guard !health.isEmpty else { return false }
        return health.cpuPercent != nil || health.memoryPercent != nil || health.diskPercent != nil
    }

    /// "45%" for a whole number, "45.5%" otherwise — as the Flutter bar labels it.
    static func metricPercentText(_ percent: Double) -> String {
        percent == percent.rounded() ? String(format: "%.0f%%", percent)
                                     : String(format: "%.1f%%", percent)
    }

    /// Bar colour tier: red at 90%+, pink from 70%, brand cyan below.
    static func metricTone(_ percent: Double) -> MoreTone {
        if percent >= 90 { return .danger }
        if percent >= 70 { return .accentAlt }
        return .cyan
    }

    /// The "LIVE" / "PARTIAL" chip beside the System health header.
    static func healthBadge(_ health: SystemHealth) -> (label: String, tone: MoreTone) {
        health.status == "partial" ? ("PARTIAL", .blue) : ("LIVE", .success)
    }

    // MARK: LLM Wiki

    /// Availability chip. Mirrors `_WikiCard`: ready → Available, error → Error,
    /// empty → Empty, anything else → Unavailable.
    static func wikiBadge(_ wiki: WikiStatus) -> (label: String, tone: MoreTone) {
        if wiki.available && wiki.status == "ready" { return ("Available", .success) }
        if wiki.status == "error" { return ("Error", .danger) }
        if wiki.available && wiki.status == "empty" { return ("Empty", .accentAlt) }
        return ("Unavailable", .muted)
    }

    /// The explanatory line under the chip.
    static func wikiNote(_ wiki: WikiStatus) -> String {
        if wiki.available && wiki.status == "ready" {
            return "LLM Wiki is configured and page metadata is visible without "
                 + "exposing wiki content."
        }
        if wiki.available && wiki.status == "empty" {
            return "LLM Wiki exists but has no entity, concept, comparison, or "
                 + "query pages yet."
        }
        if wiki.status == "error" {
            let detail = wiki.error.map { ": \($0)" } ?? ""
            return "Unable to inspect LLM Wiki status\(detail)."
        }
        return "No LLM Wiki directory was found. Set WIKI_PATH or "
             + "skills.config.wiki.path to enable status visibility."
    }

    /// The six key/value tiles in the Wiki card, in the Flutter order.
    static func wikiTiles(_ wiki: WikiStatus) -> [(label: String, value: String)] {
        [("Enabled", wiki.enabled ? "Yes" : "No"),
         ("Entries", Insights.formatTokenCount(wiki.entryCount)),
         ("Pages", Insights.formatTokenCount(wiki.pageCount)),
         ("Raw files", Insights.formatTokenCount(wiki.rawSourceCount)),
         ("Last updated", wiki.lastUpdatedLabel),
         ("Last writer", wiki.lastWriter.isEmpty ? "Not available" : wiki.lastWriter)]
    }

    // MARK: Models table

    /// "12 sessions · 1.2M tokens · 41% share" — the sub-line of a model row.
    /// Share prefers cost, then tokens, then sessions (the web's fallback chain).
    static func modelSubtitle(_ model: ModelStat) -> String {
        let share = modelShare(model)
        return "\(Insights.formatTokenCount(model.sessions)) sessions · "
             + "\(Insights.formatTokensCompact(model.totalTokens)) tokens · "
             + "\(share)% share"
    }

    /// Rounded percentage share, cost → tokens → sessions.
    static func modelShare(_ model: ModelStat) -> Int {
        let raw = model.costShare != 0 ? model.costShare
                : (model.tokenShare != 0 ? model.tokenShare : model.sessionShare)
        return Int(raw.rounded())
    }
}

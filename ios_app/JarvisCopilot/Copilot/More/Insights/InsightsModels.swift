import Foundation

/// One row of the `models` cost/token breakdown, sorted by cost desc server-side.
struct ModelStat: Identifiable, Equatable, Sendable {
    var model: String
    var sessions: Int
    var inputTokens: Int
    var outputTokens: Int
    var totalTokens: Int
    var cost: Double
    var sessionShare: Double
    var tokenShare: Double
    var costShare: Double

    var id: String { model }

    init(json: JSONObject) {
        let name = MoreJSON.text(json["model"]).trimmingCharacters(in: .whitespaces)
        model = name.isEmpty ? "unknown" : name
        sessions = MoreJSON.int(json["sessions"])
        inputTokens = MoreJSON.int(json["input_tokens"])
        outputTokens = MoreJSON.int(json["output_tokens"])
        totalTokens = MoreJSON.int(json["total_tokens"])
        cost = MoreJSON.double(json["cost"]) ?? 0
        sessionShare = MoreJSON.double(json["session_share"]) ?? 0
        tokenShare = MoreJSON.double(json["token_share"]) ?? 0
        costShare = MoreJSON.double(json["cost_share"]) ?? 0
    }
}

/// The `/api/insights?days=N` payload. `models`, `daily_tokens` and
/// `activity_by_*` are LISTS, not maps — everything is parsed defensively so a
/// renamed field never throws.
struct InsightsOverview: Equatable, Sendable {
    var periodDays = 0
    var totalSessions = 0
    var totalMessages = 0
    var totalInputTokens = 0
    var totalOutputTokens = 0
    var totalTokens = 0
    var totalCost: Double = 0
    var models: [ModelStat] = []
    /// `[{date, input_tokens, output_tokens, sessions, cost}]`, kept raw for the
    /// chart (it needs whatever series the server sends).
    var dailyTokens: [JSONObject] = []
    /// `[{day:"Mon", sessions}]`, 7 rows.
    var activityByDay: [JSONObject] = []
    /// `[{hour:0..23, sessions}]`, 24 rows.
    var activityByHour: [JSONObject] = []
    var isEmpty = true

    static func == (l: InsightsOverview, r: InsightsOverview) -> Bool {
        l.periodDays == r.periodDays && l.totalSessions == r.totalSessions
            && l.totalMessages == r.totalMessages && l.totalTokens == r.totalTokens
            && l.totalCost == r.totalCost && l.models == r.models
            && l.dailyTokens.count == r.dailyTokens.count
            && l.activityByDay.count == r.activityByDay.count
            && l.activityByHour.count == r.activityByHour.count
            && l.isEmpty == r.isEmpty
    }

    init() {}

    init(json: JSONObject) {
        periodDays = MoreJSON.int(json["period_days"])
        totalSessions = MoreJSON.int(json["total_sessions"])
        totalMessages = MoreJSON.int(json["total_messages"])
        totalInputTokens = MoreJSON.int(json["total_input_tokens"])
        totalOutputTokens = MoreJSON.int(json["total_output_tokens"])
        totalTokens = MoreJSON.int(json["total_tokens"])
        totalCost = MoreJSON.double(json["total_cost"]) ?? 0
        models = Insights.parseModelStats(json["models"])
        dailyTokens = Insights.parseRows(json["daily_tokens"])
        activityByDay = Insights.parseRows(json["activity_by_day"])
        activityByHour = Insights.parseRows(json["activity_by_hour"])
        isEmpty = json.isEmpty
    }
}

/// `/api/system/health` — coarse host CPU/RAM/disk usage.
struct SystemHealth: Equatable, Sendable {
    var status = ""
    var available = false
    var checkedAt = ""
    var cpu: JSONObject?
    var memory: JSONObject?
    var disk: JSONObject?
    var errors: [String] = []
    /// Nothing loaded — the section hides entirely.
    var isEmpty = true
    /// The fetch itself failed (as opposed to the server answering "{}").
    /// Distinguishing them is the whole point: an empty body means "this host
    /// reports no metrics", a failure means "we don't know", and collapsing both
    /// to a hidden section makes an unreachable server look healthy.
    var failed = false

    static func == (l: SystemHealth, r: SystemHealth) -> Bool {
        l.status == r.status && l.available == r.available && l.checkedAt == r.checkedAt
            && l.errors == r.errors && l.isEmpty == r.isEmpty && l.failed == r.failed
            && Insights.systemHealthPercent(l.cpu) == Insights.systemHealthPercent(r.cpu)
            && Insights.systemHealthPercent(l.memory) == Insights.systemHealthPercent(r.memory)
            && Insights.systemHealthPercent(l.disk) == Insights.systemHealthPercent(r.disk)
    }

    init() {}

    init(json: JSONObject) {
        status = MoreJSON.text(json["status"])
        available = MoreJSON.isTrue(json["available"])
        checkedAt = MoreJSON.text(json["checked_at"])
        cpu = json["cpu"] as? JSONObject
        memory = json["memory"] as? JSONObject
        disk = json["disk"] as? JSONObject
        errors = MoreJSON.stringList(json["errors"])
        isEmpty = json.isEmpty
    }

    var cpuPercent: Double? { Insights.systemHealthPercent(cpu) }
    var memoryPercent: Double? { Insights.systemHealthPercent(memory) }
    var diskPercent: Double? { Insights.systemHealthPercent(disk) }
    var memoryLabel: String { Insights.systemHealthBytesLabel(memory) }
    var diskLabel: String { Insights.systemHealthBytesLabel(disk) }
}

/// `/api/wiki/status` — LLM Wiki knowledge-base observability metadata.
struct WikiStatus: Equatable, Sendable {
    var available = false
    var enabled = false
    var status = ""
    var entryCount = 0
    var pageCount = 0
    var rawSourceCount = 0
    var lastUpdated: String?
    var lastWriter = ""
    var pathConfigured = false
    var pathSource = ""
    var toggleAvailable = false
    var toggleReason = ""
    var docsURL = ""
    var error: String?

    init() {}

    init(json: JSONObject) {
        available = MoreJSON.isTrue(json["available"])
        enabled = MoreJSON.isTrue(json["enabled"])
        status = MoreJSON.text(json["status"])
        entryCount = MoreJSON.int(json["entry_count"])
        pageCount = MoreJSON.int(json["page_count"])
        rawSourceCount = MoreJSON.int(json["raw_source_count"])
        lastUpdated = MoreJSON.nonEmpty(json["last_updated"])
        lastWriter = MoreJSON.text(json["last_writer"])
        pathConfigured = MoreJSON.isTrue(json["path_configured"])
        pathSource = MoreJSON.text(json["path_source"])
        toggleAvailable = MoreJSON.isTrue(json["toggle_available"])
        toggleReason = MoreJSON.text(json["toggle_reason"])
        docsURL = MoreJSON.text(json["docs_url"])
        error = MoreJSON.nonEmpty(json["error"])
    }

    /// "2026-06-21 09:30", "Never" when absent, or the raw string when it isn't
    /// a timestamp we recognise.
    var lastUpdatedLabel: String { Insights.formatTimestamp(lastUpdated) }
}

/// One per-message token-usage record from `/api/insights/messages`.
struct MessageUsage: Identifiable, Equatable, Sendable {
    var turn: Int
    var timestamp: String
    var model: String
    var provider: String
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheWriteTokens: Int
    var reasoningTokens: Int
    var latencySeconds: Double
    /// `composition.sections` → `{sectionKey: tokens}`, non-positive dropped.
    var composition: [String: Double]

    var id: String { "\(turn)-\(timestamp)" }

    init(json: JSONObject) {
        turn = MoreJSON.int(json["turn"])
        timestamp = MoreJSON.text(json["timestamp"])
        model = MoreJSON.text(json["model"])
        provider = MoreJSON.text(json["provider"])
        inputTokens = MoreJSON.int(json["input_tokens"])
        outputTokens = MoreJSON.int(json["output_tokens"])
        cacheReadTokens = MoreJSON.int(json["cache_read_tokens"])
        cacheWriteTokens = MoreJSON.int(json["cache_write_tokens"])
        reasoningTokens = MoreJSON.int(json["reasoning_tokens"])
        latencySeconds = MoreJSON.double(json["latency_s"]) ?? 0
        composition = Insights.messageComposition(json)
    }
}

/// The four parallel sub-fetches, bundled for the page. `hasSession` is false
/// when there's no open conversation to drill into, so the Messages section
/// hides entirely rather than showing an empty list.
struct InsightsBundle: Equatable, Sendable {
    var overview = InsightsOverview()
    var health = SystemHealth()
    var wiki = WikiStatus()
    var hasSession = false
    var sessionID: String?
    var messages: [MessageUsage] = []
}

/// Formatting + parsing helpers, ported from `insights.dart`.
enum Insights {
    /// The period selector's options, in order.
    static let periodOptions: [(days: Int, label: String)] =
        [(7, "7d"), (30, "30d"), (90, "90d"), (365, "1y")]

    /// Best-effort numeric coercion: num, numeric string ("$1,234.5" ok), or 0.
    static func number(_ value: Any?) -> Double { MoreJSON.double(value) ?? 0 }

    /// 1234 → "1,234". Rounds non-integers; handles negatives.
    static func formatTokenCount(_ value: Any?) -> String {
        let n = Int(number(value).rounded())
        let negative = n < 0
        let digits = String(abs(n))
        var out = ""
        for (index, char) in digits.enumerated() {
            if index != 0 && (digits.count - index) % 3 == 0 { out.append(",") }
            out.append(char)
        }
        return negative ? "-\(out)" : out
    }

    /// Compact form matching the web panel: 1.2M / 3.4K / 999.
    static func formatTokensCompact(_ value: Any?) -> String {
        let n = abs(number(value))
        if n >= 1e6 { return String(format: "%.1fM", n / 1e6) }
        if n >= 1e3 { return String(format: "%.1fK", n / 1e3) }
        return formatTokenCount(value)
    }

    /// Cost: 4 decimals under $1, else 2; an em dash at or below zero.
    static func formatCost(_ value: Any?) -> String {
        let n = number(value)
        if n <= 0 { return "—" }
        return n < 1 ? String(format: "$%.4f", n) : String(format: "$%.2f", n)
    }

    /// Human-readable bytes, mirroring the web's rounding (0 decimals at >= 10
    /// or for raw bytes).
    static func formatBytes(_ value: Any?) -> String {
        var n = number(value)
        let units = ["B", "KB", "MB", "GB", "TB"]
        var index = 0
        while n >= 1024 && index < units.count - 1 {
            n /= 1024
            index += 1
        }
        let decimals = (n >= 10 || index == 0) ? 0 : 1
        return String(format: "%.\(decimals)f %@", n, units[index])
    }

    /// A health metric's percent as 0…100 (clamped), or nil when the block is
    /// absent. Tolerates the cpu shape (`{percent}`) and the memory/disk shape.
    static func systemHealthPercent(_ metric: Any?) -> Double? {
        guard let m = metric as? JSONObject, let raw = m["percent"], !(raw is NSNull) else { return nil }
        return min(max(number(raw), 0), 100)
    }

    /// "1.2 GB / 8.0 GB" for memory/disk, or "" when absent (CPU has no bytes).
    static func systemHealthBytesLabel(_ metric: Any?) -> String {
        guard let m = metric as? JSONObject else { return "" }
        guard let used = m["used_bytes"], !(used is NSNull),
              let total = m["total_bytes"], !(total is NSNull) else { return "" }
        guard number(total) > 0 else { return "" }
        return "\(formatBytes(used)) / \(formatBytes(total))"
    }

    /// Parse the `models` breakdown. Tolerates nil, the current list-of-objects
    /// shape, and the older map-keyed-by-model-name shape.
    static func parseModelStats(_ value: Any?) -> [ModelStat] {
        if let list = value as? [Any] {
            // A wholly empty object carries no model and no numbers — drop it
            // rather than render a phantom "unknown" row.
            return list.compactMap { $0 as? JSONObject }
                .filter { !$0.isEmpty }
                .map(ModelStat.init(json:))
        }
        if let map = value as? JSONObject {
            return map.compactMap { key, value in
                guard var inner = value as? JSONObject else { return nil }
                inner["model"] = key
                return ModelStat(json: inner)
            }
        }
        return []
    }

    /// Normalise any list-of-objects payload; a non-list yields `[]`.
    static func parseRows(_ value: Any?) -> [JSONObject] {
        guard let list = value as? [Any] else { return [] }
        return list.compactMap { $0 as? JSONObject }
    }

    /// The per-message input composition (`composition.sections`) as
    /// `{sectionKey: tokens}`, dropping non-positive entries.
    static func messageComposition(_ message: JSONObject) -> [String: Double] {
        guard let comp = message["composition"] as? JSONObject,
              let sections = comp["sections"] as? JSONObject else { return [:] }
        var out: [String: Double] = [:]
        for (key, value) in sections {
            let n = number(value)
            if n > 0 { out[key] = n }
        }
        return out
    }

    /// "YYYY-MM-DD HH:mm" local, "Never" for nil, the raw string when unparseable.
    static func formatTimestamp(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "Never" }
        let s = MoreJSON.text(value)
        guard let date = RelativeTime.parseISOString(s) else { return s }
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02d %02d:%02d",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }
}

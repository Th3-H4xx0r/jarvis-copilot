import Foundation

/// One usage window within a provider's quota (e.g. "Current session",
/// "Current week"). `usedPercent` is 0…100, or nil when the server couldn't
/// compute it — the UI then shows "—" with an empty bar rather than a fake value.
struct QuotaWindow: Identifiable, Equatable, Sendable {
    var label: String
    var usedPercent: Double?
    var remainingPercent: Double?
    var resetAt: Date?
    var detail: String?

    var id: String { label }

    init(label: String, usedPercent: Double? = nil, remainingPercent: Double? = nil,
         resetAt: Date? = nil, detail: String? = nil) {
        self.label = label
        self.usedPercent = usedPercent
        self.remainingPercent = remainingPercent
        self.resetAt = resetAt
        self.detail = detail
    }

    init(json: JSONObject) {
        label = MoreJSON.text(json["label"])
        usedPercent = QuotaWindow.parseNumber(json["used_percent"])
        remainingPercent = QuotaWindow.parseNumber(json["remaining_percent"])
        resetAt = QuotaWindow.parseDate(json["reset_at"])
        detail = MoreJSON.nonEmpty(json["detail"])
    }

    static func parseNumber(_ value: Any?) -> Double? {
        guard let value, !(value is NSNull) else { return nil }
        return MoreJSON.double(value)
    }

    static func parseDate(_ value: Any?) -> Date? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        return RelativeTime.parseISOString(s)
    }

    /// What the bar and the percentage actually show: `used_percent`, or
    /// `100 - remaining_percent` when only the remainder was reported.
    var effectiveUsedPercent: Double? {
        if let usedPercent { return usedPercent }
        if let remainingPercent { return 100 - remainingPercent }
        return nil
    }

    /// "45%" or "—".
    var percentText: String {
        guard let used = effectiveUsedPercent else { return "—" }
        return "\(Int(min(max(used, 0), 100).rounded()))%"
    }

    /// 0…1 fill fraction for the bar; 0 when unknown (paired with "—").
    var barFraction: Double {
        guard let used = effectiveUsedPercent else { return 0 }
        return min(max(used, 0), 100) / 100
    }

    /// Bar colour tier: red near the limit, amber approaching it, brand
    /// otherwise, muted when the value is unknown.
    var barTone: QuotaBarTone {
        guard let used = effectiveUsedPercent else { return .unknown }
        if used >= 90 { return .critical }
        if used >= 75 { return .warning }
        return .normal
    }

    /// "resets in 2h 15m", or nil when the server sent no reset time.
    func resetText(now: Date = Date()) -> String? {
        guard let resetAt else { return nil }
        let seconds = Int(resetAt.timeIntervalSince(now))
        if seconds <= 0 { return "resets now" }
        if seconds < 60 { return "resets in <1m" }
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 { return "resets in \(days)d \(hours)h" }
        if hours > 0 { return "resets in \(hours)h \(minutes)m" }
        return "resets in \(minutes)m"
    }

    /// "resets in 2h 15m · Opus + Sonnet" — the sub-line under the bar.
    func subtitle(now: Date = Date()) -> String {
        [resetText(now: now), detail].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Bar colour tier. Concrete colours live in the view; `critical`/`warning` are
/// the hard-coded red/amber gradients of the Flutter card, `normal` is the
/// cyan→accent brand gradient.
enum QuotaBarTone: String, Equatable, Sendable {
    case normal, warning, critical, unknown
}

/// A configured quota-capable provider (Claude Code, Codex, …) and its windows —
/// the same usage data the web Providers panel and the Dynamic Island show.
struct QuotaProvider: Identifiable, Equatable, Sendable {
    var provider: String
    var displayName: String
    var windows: [QuotaWindow]
    var plan: String?
    var details: [String]
    var fetchedAt: Date?

    var id: String { provider }

    init(provider: String, displayName: String, windows: [QuotaWindow],
         plan: String? = nil, details: [String] = [], fetchedAt: Date? = nil) {
        self.provider = provider
        self.displayName = displayName
        self.windows = windows
        self.plan = plan
        self.details = details
        self.fetchedAt = fetchedAt
    }

    init(json: JSONObject) {
        provider = MoreJSON.text(json["provider"])
        let display = MoreJSON.text(json["display_name"])
        displayName = display.isEmpty ? provider : display
        plan = MoreJSON.nonEmpty(json["plan"])
        // A window with no label can't be rendered — drop it.
        windows = MoreJSON.mapList(json["windows"])
            .map(QuotaWindow.init(json:))
            .filter { !$0.label.isEmpty }
        details = MoreJSON.list(json["details"])
            .map { MoreJSON.text($0) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        fetchedAt = QuotaWindow.parseDate(json["fetched_at"])
    }

    /// "Claude Code · Max" when a plan is known, else just the name.
    var headerTitle: String {
        guard let plan, !plan.isEmpty else { return displayName }
        return "\(displayName) · \(plan)"
    }

    /// SF Symbol for the provider badge.
    var iconName: String {
        switch provider {
        case "claude-code", "anthropic": return "bolt.fill"
        case "openai-codex": return "cpu"
        case "openrouter": return "arrow.triangle.branch"
        default: return "speedometer"
        }
    }

    var hasLimits: Bool { !windows.isEmpty }
}

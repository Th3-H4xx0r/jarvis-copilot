import Foundation

/// Insights → Costs payloads (`/api/costs`, `/api/costs/service`), parsed
/// defensively like `InsightsModels`: every field is coerced on read through
/// `MoreJSON`, so a renamed or missing field degrades to a blank rather than
/// throwing. The server builds these in `agent/costs/report.py`.

/// How a service is paid for.
enum CostKind: String, Equatable, Sendable {
    case usage, subscription, free

    init(_ value: Any?) { self = CostKind(rawValue: MoreJSON.text(value)) ?? .usage }
}

/// Where a service's numbers come from (the card's `status`).
enum CostStatus: String, Equatable, Sendable {
    /// The provider's own billing API.
    case billing
    /// Jarvis's own count × the list price — shown with "≈".
    case estimated
    /// A plan price spread over the days.
    case subscription
    /// A subscription service without a price yet.
    case needsPrice = "needs_price"
    case free
    /// The billing API is failing; `error` says why.
    case error
    case unknown

    init(_ value: Any?) { self = CostStatus(rawValue: MoreJSON.text(value)) ?? .unknown }
}

/// One connect-form field. A saved secret is never sent back — only `isSet`.
struct CostField: Identifiable, Equatable, Sendable {
    var key: String
    var label: String
    var kind: String
    var placeholder: String
    var isSet: Bool
    /// Only this page uses the key, so Disconnect may remove it. A service's
    /// main key (it also runs the service) is managed in Settings instead.
    var billingOnly: Bool

    var id: String { key }
    var isSecret: Bool { kind != "text" }

    init(json: JSONObject) {
        key = MoreJSON.text(json["key"])
        let name = MoreJSON.text(json["label"])
        label = name.isEmpty ? key : name
        kind = MoreJSON.nonEmpty(json["kind"]) ?? "secret"
        placeholder = MoreJSON.text(json["placeholder"])
        isSet = MoreJSON.isTrue(json["is_set"])
        billingOnly = MoreJSON.isTrue(json["billing_only"])
    }
}

/// A plan the server suggests for a subscription service ("Pro $20/mo").
struct CostPlan: Identifiable, Equatable, Sendable {
    var label: String
    var amountUSD: Double
    var interval: String

    var id: String { "\(label)-\(amountUSD)-\(interval)" }

    init(json: JSONObject) {
        label = MoreJSON.text(json["label"])
        amountUSD = MoreJSON.double(json["amount_usd"]) ?? 0
        interval = MoreJSON.text(json["interval"]) == "year" ? "year" : "month"
    }

    init(label: String, amountUSD: Double, interval: String) {
        self.label = label
        self.amountUSD = amountUSD
        self.interval = interval
    }
}

/// The plan price the user set for a subscription service.
struct CostSubscription: Equatable, Sendable {
    var amountUSD: Double
    var interval: String
    var plan: String?
    var since: String?

    /// nil when the block is absent or carries no amount.
    init?(json: Any?) {
        guard let json = json as? JSONObject, let amount = MoreJSON.double(json["amount_usd"]) else {
            return nil
        }
        amountUSD = amount
        interval = MoreJSON.text(json["interval"]) == "year" ? "year" : "month"
        plan = MoreJSON.nonEmpty(json["plan"])
        since = MoreJSON.nonEmpty(json["since"])
    }

    var isYearly: Bool { interval == "year" }
}

/// The countable usage behind a service's amount. Every count is optional: a
/// search service has `searches`, a speech one `audioSeconds`, and so on.
struct CostUnits: Equatable, Sendable {
    var calls: Int?
    var inputTokens: Int?
    var outputTokens: Int?
    var cacheReadTokens: Int?
    var cacheWriteTokens: Int?
    var searches: Int?
    var requests: Int?
    var audioSeconds: Double?
    var bytes: Int?
    /// What the calls a subscription covered would have cost on the pay-as-you-go API.
    var apiEquivUSD: Double?
    var unpricedCalls: Int?
    /// Counted from older history rather than live metering.
    var fromHistory = false

    init() {}

    init(json: Any?) {
        let u = MoreJSON.map(json)
        // `Int(_:)` traps on a non-finite or out-of-range Double ("inf", 1e300).
        func count(_ key: String) -> Int? {
            MoreJSON.double(u[key]).flatMap { $0.isFinite && abs($0) < 9e18 ? Int($0) : nil }
        }
        calls = count("calls")
        inputTokens = count("input_tokens")
        outputTokens = count("output_tokens")
        cacheReadTokens = count("cache_read_tokens")
        cacheWriteTokens = count("cache_write_tokens")
        searches = count("searches")
        requests = count("requests")
        audioSeconds = MoreJSON.double(u["audio_seconds"])
        bytes = count("bytes")
        apiEquivUSD = MoreJSON.double(u["api_equiv_usd"])
        unpricedCalls = count("unpriced_calls")
        fromHistory = MoreJSON.isTrue(u["from_history"])
    }

    /// Input + output + cache tokens, or nil when the service counts none.
    var totalTokens: Int? {
        let parts = [inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens].compactMap { $0 }
        return parts.isEmpty ? nil : parts.reduce(0, +)
    }

    /// Two days' counts added up (a weekly bar's units).
    func adding(_ other: CostUnits) -> CostUnits {
        func sum(_ a: Int?, _ b: Int?) -> Int? { a == nil && b == nil ? nil : (a ?? 0) + (b ?? 0) }
        func sum(_ a: Double?, _ b: Double?) -> Double? { a == nil && b == nil ? nil : (a ?? 0) + (b ?? 0) }
        var out = CostUnits()
        out.calls = sum(calls, other.calls)
        out.inputTokens = sum(inputTokens, other.inputTokens)
        out.outputTokens = sum(outputTokens, other.outputTokens)
        out.cacheReadTokens = sum(cacheReadTokens, other.cacheReadTokens)
        out.cacheWriteTokens = sum(cacheWriteTokens, other.cacheWriteTokens)
        out.searches = sum(searches, other.searches)
        out.requests = sum(requests, other.requests)
        out.audioSeconds = sum(audioSeconds, other.audioSeconds)
        out.bytes = sum(bytes, other.bytes)
        out.apiEquivUSD = sum(apiEquivUSD, other.apiEquivUSD)
        out.unpricedCalls = sum(unpricedCalls, other.unpricedCalls)
        out.fromHistory = fromHistory || other.fromHistory
        return out
    }

    var isEmpty: Bool {
        calls == nil && totalTokens == nil && searches == nil && requests == nil
            && audioSeconds == nil && bytes == nil
    }
}

/// One service card, in `services` (used) or `available` (can be connected).
struct CostService: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var category: String
    var kind: CostKind
    var custom: Bool
    var status: CostStatus
    var detected: Bool
    var billingConnected: Bool
    var periodTotal: Double
    var monthToDate: Double
    /// Which sources fed the period: "billing", "estimate", "subscription".
    var sources: [String]
    var estimateTotal: Double?
    var billingTotal: Double?
    /// For a subscription whose provider reports usage: what the plan covered.
    var planUsageUSD: Double?
    var units: CostUnits
    /// Per-day effective amounts over the period, oldest first.
    var spark: [Double]
    var balanceUSD: Double?
    var limitUSD: Double?
    var balanceAt: Date?
    var lastSynced: Date?
    var error: String?
    var subscription: CostSubscription?
    var suggestedPlans: [CostPlan]
    var fields: [CostField]
    var url: URL?
    var help: String

    init(json: JSONObject) {
        let sid = MoreJSON.text(json["id"])
        id = sid
        name = MoreJSON.nonEmpty(json["name"]) ?? sid
        category = MoreJSON.nonEmpty(json["category"]) ?? "Other"
        kind = CostKind(json["kind"])
        custom = MoreJSON.isTrue(json["custom"])
        status = CostStatus(json["status"])
        detected = MoreJSON.isTrue(json["detected"])
        billingConnected = MoreJSON.isTrue(json["billing_connected"])
        periodTotal = MoreJSON.double(json["period_total"]) ?? 0
        monthToDate = MoreJSON.double(json["month_to_date"]) ?? 0
        sources = MoreJSON.stringList(json["sources"])
        estimateTotal = MoreJSON.double(json["estimate_total"])
        billingTotal = MoreJSON.double(json["billing_total"])
        planUsageUSD = MoreJSON.double(json["plan_usage_usd"])
        units = CostUnits(json: json["units"])
        spark = MoreJSON.list(json["spark"]).map { MoreJSON.double($0) ?? 0 }
        balanceUSD = MoreJSON.double(json["balance_usd"])
        limitUSD = MoreJSON.double(json["limit_usd"])
        balanceAt = RelativeTime.parse(json["balance_at"])
        lastSynced = RelativeTime.parse(json["last_synced"])
        error = MoreJSON.nonEmpty(json["error"])
        subscription = CostSubscription(json: json["subscription"])
        suggestedPlans = MoreJSON.mapList(json["suggested_plans"]).map(CostPlan.init(json:))
        fields = MoreJSON.mapList(json["fields"]).map(CostField.init(json:)).filter { !$0.key.isEmpty }
        url = MoreJSON.nonEmpty(json["url"]).flatMap(URL.init(string:))
        help = MoreJSON.text(json["help"])
    }

    /// The amount is (at least partly) Jarvis's own estimate — shown with "≈".
    var isEstimate: Bool {
        sources.contains("estimate") || (sources.isEmpty && status == .estimated)
    }

    /// A billing-only key saved by this page — what "Disconnect billing" removes.
    var hasBillingKey: Bool {
        fields.contains { $0.isSet && $0.billingOnly }
    }
}

struct CostsTotals: Equatable, Sendable {
    var period: Double = 0
    var previousPeriod: Double?
    var monthToDate: Double = 0
    var projectedMonth: Double = 0
    /// "subscription" / "estimate" / "billing" → amount, summing to `period`.
    var bySource: [String: Double] = [:]

    init() {}

    init(json: Any?) {
        let t = MoreJSON.map(json)
        period = MoreJSON.double(t["period"]) ?? 0
        previousPeriod = MoreJSON.double(t["previous_period"])
        monthToDate = MoreJSON.double(t["month_to_date"]) ?? 0
        projectedMonth = MoreJSON.double(t["projected_month"]) ?? 0
        for (key, value) in MoreJSON.map(t["by_source"]) {
            if let amount = MoreJSON.double(value) { bySource[key] = amount }
        }
    }
}

struct CostsBudget: Equatable, Sendable {
    var monthlyUSD: Double?
    var usedPercent: Double?

    init() {}

    init(json: Any?) {
        let b = MoreJSON.map(json)
        monthlyUSD = MoreJSON.double(b["monthly_usd"]).flatMap { $0 > 0 ? $0 : nil }
        usedPercent = MoreJSON.double(b["used_pct"])
    }
}

/// One day of the overview's stacked chart.
struct CostsDay: Equatable, Sendable {
    var day: String
    var total: Double
    var byService: [String: Double]

    init(json: JSONObject) {
        day = MoreJSON.text(json["day"])
        total = MoreJSON.double(json["total"]) ?? 0
        var parts: [String: Double] = [:]
        for (key, value) in MoreJSON.map(json["by_service"]) {
            if let amount = MoreJSON.double(value), amount != 0 { parts[key] = amount }
        }
        byService = parts
    }

    init(day: String, total: Double, byService: [String: Double]) {
        self.day = day
        self.total = total
        self.byService = byService
    }
}

/// `GET /api/costs?days=N`.
struct CostsOverview: Equatable, Sendable {
    var currency = "USD"
    var days = 0
    var start = ""
    var end = ""
    var lastRun: Date?
    var totals = CostsTotals()
    var budget = CostsBudget()
    var daily: [CostsDay] = []
    var services: [CostService] = []
    var available: [CostService] = []
    /// Nothing arrived at all (the empty-state check).
    var isEmpty = true

    init() {}

    init(json: JSONObject) {
        currency = MoreJSON.nonEmpty(json["currency"]) ?? "USD"
        days = MoreJSON.int(json["days"])
        start = MoreJSON.text(json["start"])
        end = MoreJSON.text(json["end"])
        lastRun = RelativeTime.parse(json["last_run"])
        totals = CostsTotals(json: json["totals"])
        budget = CostsBudget(json: json["budget"])
        daily = MoreJSON.mapList(json["daily"]).map(CostsDay.init(json:)).filter { !$0.day.isEmpty }
        services = MoreJSON.mapList(json["services"]).map(CostService.init(json:)).filter { !$0.id.isEmpty }
        available = MoreJSON.mapList(json["available"]).map(CostService.init(json:)).filter { !$0.id.isEmpty }
        isEmpty = json.isEmpty
    }

    /// Any service, used or available, by id.
    func service(_ id: String) -> CostService? {
        services.first { $0.id == id } ?? available.first { $0.id == id }
    }
}

/// One day of a service's detail. Only days with data are sent.
struct CostDetailDay: Equatable, Sendable {
    var day: String
    var effective: Double
    var billing: Double?
    var estimate: Double?
    var subscription: Double?
    var source: String?
    var units: CostUnits

    init(json: JSONObject) {
        day = MoreJSON.text(json["day"])
        effective = MoreJSON.double(json["effective"]) ?? 0
        billing = MoreJSON.double(json["billing"])
        estimate = MoreJSON.double(json["estimate"])
        subscription = MoreJSON.double(json["subscription"])
        source = MoreJSON.nonEmpty(json["source"])
        units = CostUnits(json: json["units"])
    }

    init(day: String, effective: Double = 0, billing: Double? = nil, estimate: Double? = nil,
         subscription: Double? = nil, source: String? = nil, units: CostUnits = CostUnits()) {
        self.day = day
        self.effective = effective
        self.billing = billing
        self.estimate = estimate
        self.subscription = subscription
        self.source = source
        self.units = units
    }
}

/// One model's share of a service's estimate.
struct CostModelRow: Identifiable, Equatable, Sendable {
    var model: String
    var calls: Int
    var tokens: Int
    var costUSD: Double
    var unpriced: Bool

    var id: String { model }

    init(json: JSONObject) {
        model = MoreJSON.nonEmpty(json["model"]) ?? "unknown"
        calls = MoreJSON.int(json["calls"])
        tokens = MoreJSON.int(json["tokens"])
        costUSD = MoreJSON.double(json["cost_usd"]) ?? 0
        unpriced = MoreJSON.isTrue(json["unpriced"])
    }
}

/// One line of the provider's own bill.
struct CostBillingItem: Identifiable, Equatable, Sendable {
    var item: String
    var costUSD: Double

    var id: String { item }

    init(json: JSONObject) {
        item = MoreJSON.nonEmpty(json["item"]) ?? "Other"
        costUSD = MoreJSON.double(json["cost_usd"]) ?? 0
    }
}

/// A balance / plan-usage reading.
struct CostSnapshot: Equatable, Sendable {
    var at: Date?
    var balanceUSD: Double?
    var usedUSD: Double?
    var limitUSD: Double?

    init(json: JSONObject) {
        at = RelativeTime.parse(json["ts"])
        balanceUSD = MoreJSON.double(json["balance_usd"])
        usedUSD = MoreJSON.double(json["used_usd"])
        limitUSD = MoreJSON.double(json["limit_usd"])
    }
}

/// `GET /api/costs/service?id=X&days=N`.
struct CostServiceDetail: Equatable, Sendable {
    var service: CostService
    var days: Int
    var daily: [CostDetailDay]
    var models: [CostModelRow]
    var billingItems: [CostBillingItem]
    var snapshots: [CostSnapshot]

    init(json: JSONObject) {
        service = CostService(json: MoreJSON.map(json["service"]))
        days = MoreJSON.int(json["days"])
        daily = MoreJSON.mapList(json["daily"]).map(CostDetailDay.init(json:)).filter { !$0.day.isEmpty }
        models = MoreJSON.mapList(json["models"]).map(CostModelRow.init(json:))
        billingItems = MoreJSON.mapList(json["billing_items"]).map(CostBillingItem.init(json:))
        snapshots = MoreJSON.mapList(json["snapshots"]).map(CostSnapshot.init(json:))
    }
}

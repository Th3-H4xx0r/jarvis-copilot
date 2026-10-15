import Foundation

// The shapes `/api/services/*` sends (see `webui/api/services_routes.py` and
// `jarvis_services/base.py`). Every parser is forgiving: a field the server
// leaves out (or a newer one sends differently) falls back to a default rather
// than dropping the row, because a pill with a blank line beats a missing pill.

/// A pill's colour: what state the service is in.
enum ServiceTone: String, Equatable {
    case ok, warning, error, info, idle

    init(_ raw: Any?) {
        self = ServiceTone(rawValue: CodingJSON.text(raw).lowercased()) ?? .idle
    }
}

/// An epoch-seconds field, or nil when absent / not a number.
private func epoch(_ v: Any?) -> Date? {
    guard let s = CodingJSON.double(v), s > 0 else { return nil }
    return Date(timeIntervalSince1970: s)
}

/// Only web links open from a service row; anything else (a `javascript:` or
/// app scheme a third-party API echoed back) is dropped.
private func webURL(_ v: Any?) -> URL? {
    guard let s = CodingJSON.str(v), let url = URL(string: s),
          let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
    return url
}

private func doubles(_ v: Any?) -> [Double] {
    (v as? [Any])?.compactMap { CodingJSON.double($0) } ?? []
}

// MARK: - Snapshot (the pill)

/// Something the server can do on an item, e.g. `vercel.redeploy`. Offered in a
/// detail only; the server re-checks every request against its latest offer.
struct ServiceAction: Identifiable, Equatable, Hashable {
    let kind: String
    let title: String
    let target: String
    let symbol: String
    let destructive: Bool
    /// Asked before doing it, when it can't be undone.
    let confirm: String?

    var id: String { "\(kind)|\(target)" }

    /// Nil without a kind or a target: there would be nothing to send.
    init?(json: [String: Any]) {
        guard let kind = CodingJSON.str(json["kind"]), let target = CodingJSON.str(json["target"]) else { return nil }
        self.kind = kind
        self.target = target
        title = CodingJSON.str(json["title"]) ?? kind
        symbol = CodingJSON.text(json["symbol"])
        destructive = CodingJSON.bool(json["destructive"])
        confirm = CodingJSON.str(json["confirm"])
    }
}

struct ServiceItem: Identifiable, Equatable {
    /// Position in its section: items carry no id of their own.
    let id: Int
    let title: String
    let subtitle: String
    let value: String?
    let url: URL?
    let tone: ServiceTone
    let date: Date?
    /// A short tag on the right ("Production", "Draft", "Active"…).
    let badge: String?
    let actions: [ServiceAction]

    init(json: [String: Any], index: Int) {
        id = index
        title = CodingJSON.text(json["title"])
        subtitle = CodingJSON.text(json["subtitle"])
        value = CodingJSON.str(json["value"])
        url = webURL(json["url"])
        tone = ServiceTone(json["tone"])
        date = epoch(json["date"])
        badge = CodingJSON.str(json["badge"])
        actions = CodingJSON.maps(json["actions"]).compactMap(ServiceAction.init(json:))
    }
}

struct ServiceSection: Identifiable, Equatable {
    let id: Int
    let title: String
    let items: [ServiceItem]
    let footer: String?

    init(json: [String: Any], index: Int) {
        id = index
        title = CodingJSON.text(json["title"])
        items = CodingJSON.maps(json["items"]).enumerated().map { ServiceItem(json: $1, index: $0) }
        footer = CodingJSON.str(json["footer"])
    }

    static func list(_ v: Any?) -> [ServiceSection] {
        CodingJSON.maps(v).enumerated().map { ServiceSection(json: $1, index: $0) }
    }
}

/// One day of the GitHub contribution calendar.
struct ContributionDay: Equatable {
    let date: String
    let count: Int
    /// 0 (none) … 4 (most), GitHub's own quartiles.
    let level: Int
    /// 0 = Sunday.
    let weekday: Int
}

/// GitHub's `extra`: who, how much, and the year of contributions.
struct GitHubActivity: Equatable {
    let login: String
    let repos: Int?
    let stars: Int?
    let total: Int
    /// Oldest week first; a week can be partial (the first and the current one).
    let weeks: [[ContributionDay]]

    /// Nil without a calendar: there's no grid to draw.
    init?(extra: Any?) {
        guard let extra = CodingJSON.dict(extra), let activity = CodingJSON.dict(extra["activity"]) else { return nil }
        login = CodingJSON.text(extra["login"])
        let stats = CodingJSON.dict(extra["stats"])
        repos = stats.flatMap { $0["repos"] == nil ? nil : CodingJSON.int($0["repos"]) }
        stars = stats.flatMap { $0["stars"] == nil ? nil : CodingJSON.int($0["stars"]) }
        total = CodingJSON.int(activity["total"])
        weeks = ((activity["weeks"] as? [Any]) ?? []).map { week in
            CodingJSON.maps(week).map {
                ContributionDay(date: CodingJSON.text($0["date"]), count: CodingJSON.int($0["count"]),
                                level: min(4, max(0, CodingJSON.int($0["level"]))),
                                weekday: min(6, max(0, CodingJSON.int($0["weekday"]))))
            }
        }.filter { !$0.isEmpty }
    }

    /// The last `count` weeks, for a grid that hasn't room for the whole year.
    func recentWeeks(_ count: Int) -> [[ContributionDay]] {
        Array(weeks.suffix(max(0, count)))
    }
}

/// What a pill shows: its dot, why it has that colour, the latest items.
struct ServiceSnapshot: Identifiable, Equatable {
    let id: String
    let displayName: String
    let tone: ServiceTone
    let headline: String
    let reason: String
    let sections: [ServiceSection]
    let updatedAt: Date?
    /// The last poll failed (the pill keeps its previous content).
    let error: String?
    let github: GitHubActivity?

    init(json: [String: Any]) {
        id = CodingJSON.text(json["id"])
        displayName = CodingJSON.str(json["display_name"]) ?? id
        tone = ServiceTone(json["tone"])
        headline = CodingJSON.text(json["headline"])
        reason = CodingJSON.text(json["reason"])
        sections = ServiceSection.list(json["sections"])
        updatedAt = epoch(json["updated_at"])
        error = CodingJSON.str(json["error"])
        github = GitHubActivity(extra: json["extra"])
    }
}

// MARK: - Detail (up close)

struct ServiceStat: Identifiable, Equatable {
    let id: Int
    let label: String
    let value: String
    let tone: ServiceTone
}

/// What the last action did, kept on the detail until the next one.
struct ServiceActionResult: Equatable {
    let title: String
    let ok: Bool
    let message: String
    let at: Date?

    init?(json: Any?) {
        guard let json = CodingJSON.dict(json) else { return nil }
        title = CodingJSON.text(json["title"])
        ok = CodingJSON.bool(json["ok"])
        message = CodingJSON.text(json["message"])
        at = epoch(json["at"])
    }

    /// "Redeploy: Redeploying app", or just the title when there's no message.
    var line: String {
        message.isEmpty ? title : title.isEmpty ? message : "\(title): \(message)"
    }
}

struct ServiceDetail: Equatable {
    let id: String
    let displayName: String
    let stats: [ServiceStat]
    let sections: [ServiceSection]
    let fetchedAt: Date?
    /// Why the API couldn't be read (no key, 401…).
    let error: String?
    let lastAction: ServiceActionResult?

    init(json: [String: Any]) {
        id = CodingJSON.text(json["id"])
        displayName = CodingJSON.str(json["display_name"]) ?? id
        stats = CodingJSON.maps(json["stats"]).enumerated().map { i, s in
            ServiceStat(id: i, label: CodingJSON.text(s["label"]), value: CodingJSON.text(s["value"]),
                        tone: ServiceTone(s["tone"]))
        }
        sections = ServiceSection.list(json["sections"])
        fetchedAt = epoch(json["fetched_at"])
        error = CodingJSON.str(json["error"])
        lastAction = ServiceActionResult(json: json["last_action"])
    }
}

/// `POST /api/services/<id>/action`'s answer, whatever its status: 200 done,
/// 409 refused (with `confirm` when only the confirmation was missing), 502 the
/// service's API failed. All three carry the detail as it stands now.
struct ServiceActionReply {
    let status: Int
    let result: ServiceActionResult?
    let error: String?
    let confirm: String?
    let detail: ServiceDetail?

    init(status: Int, json: [String: Any]) {
        self.status = status
        result = ServiceActionResult(json: json["result"])
        error = CodingJSON.str(json["error"])
        confirm = CodingJSON.str(json["confirm"])
        detail = CodingJSON.dict(json["detail"]).map(ServiceDetail.init(json:))
    }
}

// MARK: - Portfolio

struct CryptoQuote: Identifiable, Equatable {
    let symbol: String
    let price: Double
    let open24h: Double
    /// Percent since 24 h ago.
    let change24h: Double
    /// Hourly closes over the last day, oldest first.
    let spark: [Double]
    let url: URL?

    var id: String { symbol }

    init(json: [String: Any]) {
        symbol = CodingJSON.text(json["symbol"])
        price = CodingJSON.double(json["price"]) ?? 0
        open24h = CodingJSON.double(json["open_24h"]) ?? 0
        change24h = CodingJSON.double(json["change_24h"]) ?? 0
        spark = doubles(json["spark"])
        url = webURL(json["url"])
    }
}

/// The watchlist: prices from one exchange's public market data.
struct CryptoBoard: Equatable {
    let exchange: String
    let currency: String
    let quotes: [CryptoQuote]
    /// Coins the exchange had no price for.
    let missing: [String]
    let alertSymbol: String?
    let updatedAt: Date?
    let error: String?

    /// Nil for `null`: the watchlist is off.
    init?(json: Any?) {
        guard let json = CodingJSON.dict(json) else { return nil }
        exchange = CodingJSON.text(json["exchange"])
        currency = CodingJSON.str(json["currency"]) ?? "USD"
        quotes = CodingJSON.maps(json["quotes"]).map(CryptoQuote.init(json:)).filter { !$0.symbol.isEmpty }
        missing = CodingJSON.strings(json["missing"])
        alertSymbol = CodingJSON.str(json["alert_symbol"])
        updatedAt = epoch(json["updated_at"])
        error = CodingJSON.str(json["error"])
    }
}

struct PortfolioHolding: Identifiable, Equatable {
    let symbol: String
    let amount: Double
    let price: Double
    /// In USD.
    let value: Double
    /// Nil for fiat and unpriced stablecoins.
    let change24h: Double?
    /// The last 7 daily closes, oldest first.
    let history: [Double]

    var id: String { symbol }

    init(json: [String: Any]) {
        symbol = CodingJSON.text(json["symbol"])
        amount = CodingJSON.double(json["amount"]) ?? 0
        price = CodingJSON.double(json["price"]) ?? 0
        value = CodingJSON.double(json["value"]) ?? 0
        change24h = CodingJSON.double(json["change_24h"])
        history = doubles(json["history"])
    }
}

/// An exchange account or a public wallet.
struct PortfolioAccount: Identifiable, Equatable {
    let id: String
    /// "exchange" | "wallet".
    let kind: String
    /// The exchange id, or the wallet's network id.
    let source: String
    let name: String
    let label: String
    let address: String?
    let holdings: [PortfolioHolding]
    let totalUSD: Double
    let error: String?

    var isWallet: Bool { kind == "wallet" }

    init(json: [String: Any]) {
        id = CodingJSON.text(json["id"])
        kind = CodingJSON.text(json["kind"])
        source = CodingJSON.text(json["source"])
        name = CodingJSON.text(json["name"])
        label = CodingJSON.str(json["label"]) ?? CodingJSON.text(json["name"])
        address = CodingJSON.str(json["address"])
        holdings = CodingJSON.maps(json["holdings"]).map(PortfolioHolding.init(json:))
        totalUSD = CodingJSON.double(json["total_usd"]) ?? 0
        error = CodingJSON.str(json["error"])
    }
}

struct PortfolioBoard: Equatable {
    let accounts: [PortfolioAccount]
    let totalUSD: Double
    let updatedAt: Date?
    let error: String?

    /// Nil for `null`: no exchange key and no wallet yet.
    init?(json: Any?) {
        guard let json = CodingJSON.dict(json) else { return nil }
        accounts = CodingJSON.maps(json["accounts"]).map(PortfolioAccount.init(json:))
        totalUSD = CodingJSON.double(json["total_usd"]) ?? 0
        updatedAt = epoch(json["updated_at"])
        error = CodingJSON.str(json["error"])
    }
}

// MARK: - Config (the keys screen)

/// A secret the server holds: its label and whether one is saved. The value
/// itself never leaves the server.
struct ServiceSecretField: Identifiable, Equatable {
    let name: String
    let label: String
    let hasKey: Bool

    var id: String { name }

    static func list(_ v: Any?) -> [ServiceSecretField] {
        CodingJSON.maps(v).compactMap { f in
            guard let name = CodingJSON.str(f["name"]) else { return nil }
            return ServiceSecretField(name: name, label: CodingJSON.str(f["label"]) ?? name,
                                      hasKey: CodingJSON.bool(f["has_key"]))
        }
    }
}

enum ServiceSettingValue: Equatable {
    case text(String)
    case list([String])
}

/// A non-secret setting (n8n's address, the Vercel projects to watch…).
struct ServiceSetting: Identifiable, Equatable {
    let key: String
    let value: ServiceSettingValue

    var id: String { key }

    var label: String {
        switch key {
        case "url": return "Server address"
        case "from": return "From address"
        case "projects": return "Projects to watch"
        case "workflows": return "Workflows to watch"
        default: return key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    var placeholder: String {
        switch key {
        case "url": return "https://n8n.example.com"
        case "from": return "jarvis@example.com"
        case "projects", "workflows": return "All of them (or names, comma-separated)"
        default: return ""
        }
    }

    /// What the field shows: the text, or a list joined with commas.
    var text: String {
        switch value {
        case .text(let s): return s
        case .list(let items): return items.joined(separator: ", ")
        }
    }

    /// The edited field as the server wants it: text stays text, a list is split
    /// on commas / new lines with the blanks dropped.
    func payload(_ edited: String) -> Any {
        switch value {
        case .text: return edited.trimmingCharacters(in: .whitespacesAndNewlines)
        case .list: return ServiceSetting.split(edited)
        }
    }

    static func split(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func list(_ v: Any?) -> [ServiceSetting] {
        let all = CodingJSON.dict(v) ?? [:]
        return all.keys.sorted().map { key in
            let raw = all[key]
            if let items = raw as? [Any] { return ServiceSetting(key: key, value: .list(items.map(CodingJSON.stringify))) }
            return ServiceSetting(key: key, value: .text(CodingJSON.text(raw)))
        }
    }
}

struct ServiceConfigEntry: Identifiable, Equatable {
    let id: String
    let displayName: String
    let configured: Bool
    let secrets: [ServiceSecretField]
    let settings: [ServiceSetting]

    init(json: [String: Any]) {
        id = CodingJSON.text(json["id"])
        displayName = CodingJSON.str(json["display_name"]) ?? id
        configured = CodingJSON.bool(json["configured"])
        secrets = ServiceSecretField.list(json["secrets"])
        settings = ServiceSetting.list(json["settings"])
    }
}

struct ExchangeConfigEntry: Identifiable, Equatable {
    let id: String
    let displayName: String
    let configured: Bool
    let secrets: [ServiceSecretField]

    init(json: [String: Any]) {
        id = CodingJSON.text(json["id"])
        displayName = CodingJSON.str(json["display_name"]) ?? id
        configured = CodingJSON.bool(json["configured"])
        secrets = ServiceSecretField.list(json["secrets"])
    }
}

/// The watchlist's settings, and the choices the server allows.
struct CryptoOptions: Equatable {
    var enabled: Bool
    var exchange: String
    var currency: String
    var coins: [String]
    var alertEnabled: Bool
    var alertPercent: Double
    let exchanges: [String]
    let currencies: [String]
    let maxCoins: Int

    init?(json: Any?) {
        guard let json = CodingJSON.dict(json) else { return nil }
        enabled = CodingJSON.bool(json["enabled"])
        exchange = CodingJSON.str(json["exchange"]) ?? "coinbase"
        currency = CodingJSON.str(json["currency"]) ?? "USD"
        coins = CodingJSON.strings(json["coins"])
        alertEnabled = CodingJSON.bool(json["alert_enabled"])
        alertPercent = CodingJSON.double(json["alert_percent"]) ?? 5
        let ex = CodingJSON.strings(json["exchanges"])
        exchanges = ex.isEmpty ? ["coinbase", "okx"] : ex
        let cur = CodingJSON.strings(json["currencies"])
        currencies = cur.isEmpty ? ["USD", "EUR"] : cur
        maxCoins = CodingJSON.int(json["max_coins"], or: 8)
    }
}

struct WalletEntry: Identifiable, Equatable, Hashable {
    let network: String
    let address: String
    let label: String

    var id: String { "\(network):\(address)" }

    static func list(_ v: Any?) -> [WalletEntry] {
        CodingJSON.maps(v).compactMap { w in
            guard let network = CodingJSON.str(w["network"]), let address = CodingJSON.str(w["address"]) else { return nil }
            return WalletEntry(network: network, address: address, label: CodingJSON.text(w["label"]))
        }
    }
}

struct WalletNetwork: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let symbol: String
    let placeholder: String
}

/// `GET /api/services/config`: every service, exchange, the watchlist, the
/// wallets and the networks a wallet can be on. `has_key` booleans only.
struct ServicesConfig: Equatable {
    var services: [ServiceConfigEntry]
    var exchanges: [ExchangeConfigEntry]
    var crypto: CryptoOptions?
    var wallets: [WalletEntry]
    var networks: [WalletNetwork]

    init(json: [String: Any]) {
        services = CodingJSON.maps(json["services"]).map(ServiceConfigEntry.init(json:)).filter { !$0.id.isEmpty }
        exchanges = CodingJSON.maps(json["exchanges"]).map(ExchangeConfigEntry.init(json:)).filter { !$0.id.isEmpty }
        crypto = CryptoOptions(json: json["crypto"])
        wallets = WalletEntry.list(json["wallets"])
        networks = CodingJSON.maps(json["networks"]).compactMap { n in
            guard let id = CodingJSON.str(n["id"]) else { return nil }
            return WalletNetwork(id: id, name: CodingJSON.str(n["name"]) ?? id,
                                 symbol: CodingJSON.text(n["symbol"]), placeholder: CodingJSON.text(n["placeholder"]))
        }
    }

    func network(_ id: String) -> WalletNetwork? { networks.first { $0.id == id } }
}

/// What the keys form holds before Save. A secret goes out ONLY when it was
/// typed here (or explicitly removed): a saved key is never shown, so it can
/// never be sent back by accident.
struct KeysDraft: Equatable {
    /// field name → what was typed.
    var typed: [String: String] = [:]
    /// Saved keys to remove.
    var removed: Set<String> = []
    /// setting key → the edited text.
    var settings: [String: String] = [:]

    /// `{field: value | null}` for the known fields that were typed or removed.
    func secretsPayload(fields: [ServiceSecretField]) -> [String: Any] {
        var out: [String: Any] = [:]
        for field in fields {
            let value = (typed[field.name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                out[field.name] = value
            } else if removed.contains(field.name) {
                out[field.name] = NSNull()
            }
        }
        return out
    }

    /// The settings whose text changed, in the server's types.
    func settingsPayload(_ original: [ServiceSetting]) -> [String: Any] {
        var out: [String: Any] = [:]
        for setting in original {
            guard let edited = settings[setting.key] else { continue }
            let new = setting.payload(edited)
            let old = setting.payload(setting.text)
            if let a = new as? String, let b = old as? String, a == b { continue }
            if let a = new as? [String], let b = old as? [String], a == b { continue }
            out[setting.key] = new
        }
        return out
    }
}

// MARK: - Formatting

enum ServicesFormat {
    /// "+3.03%" / "−1.50%" (a real minus, as the server writes it).
    static func percent(_ value: Double) -> String {
        let s = String(format: "%.2f%%", abs(value))
        return (value < 0 ? "−" : "+") + s
    }

    /// The server's own rule: whole units from 1000 up, cents from 1, else 4 places.
    static func priceDigits(_ value: Double) -> Int {
        abs(value) >= 1000 ? 0 : abs(value) >= 1 ? 2 : 4
    }

    static func price(_ value: Double, currency: String) -> String {
        let digits = priceDigits(value)
        return value.formatted(.currency(code: currency).precision(.fractionLength(digits)))
    }

    static func usd(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(abs(value) >= 1000 ? 0 : 2)))
    }

    static func amount(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...(abs(value) >= 1 ? 4 : 8))))
    }

    /// "now", "4m", "3h", "2d".
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h" }
        return "\(s / 86_400)d"
    }

    /// "just now", "4m ago".
    static func agoPhrase(_ date: Date, now: Date = Date()) -> String {
        let a = ago(date, now: now)
        return a == "now" ? "just now" : "\(a) ago"
    }
}


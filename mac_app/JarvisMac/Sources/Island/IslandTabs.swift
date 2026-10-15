import Foundation

/// The expanded island's tabs.
enum IslandTab: String, CaseIterable, Identifiable {
    case agents, chat, services, music, mail
    /// Talking to Jarvis: the voice panel in the island (the orb in the ear,
    /// "Hey Jarvis", the tab row's orb). Not one of the tab buttons.
    case voice
    var id: String { rawValue }

    /// The tab row's buttons.
    static var tabBar: [IslandTab] { allCases.filter { $0 != .voice } }

    /// What opening the island by a click on the notch shows: only the orb
    /// opens Voice, so from Voice it's the last other tab.
    static func forIslandClick(current: IslandTab, last: IslandTab) -> IslandTab {
        current == .voice ? (last == .voice ? .agents : last) : current
    }

    var icon: String {
        switch self {
        case .agents: return "terminal"
        case .chat: return "bubble.left.and.text.bubble.right"
        case .services: return "gauge.with.needle"
        case .music: return "music.note"
        case .mail: return "envelope"
        case .voice: return "waveform"
        }
    }

    var title: String {
        switch self {
        case .agents: return "Agents"
        case .chat: return "Chat"
        case .services: return "Services"
        case .music: return "Music"
        case .mail: return "Mail"
        case .voice: return "Voice"
        }
    }

    /// The expanded height of every tab but Agents (which sizes to its sessions)
    /// and Music (to its rows; expandedHeight passes the real inset).
    var height: CGFloat {
        switch self {
        case .agents: return 500
        case .chat: return 480
        case .services: return 440
        case .music: return IslandLayout.musicHeight(topInset: 40)   // sized to its rows
        case .mail: return 430
        case .voice: return IslandLayout.voiceHeight(topInset: 40)   // the panel under the tab row
        }
    }
}

/// One service pill from the server's `services` topic (jarvis_services Snapshot).
struct MacServiceCard: Identifiable, Equatable {
    enum Tone: String { case ok, info, warning, error, idle
        var rank: Int { [.error: 0, .warning: 1, .info: 2, .ok: 3, .idle: 4][self] ?? 4 }
    }
    struct Item: Equatable {
        let title: String
        let subtitle: String
        let url: URL?
    }

    let id: String
    let name: String
    let tone: Tone
    let headline: String
    let reason: String
    let items: [Item]
    let error: String?

    init(json: [String: Any]) {
        id = J.s(json["id"])
        name = J.s(json["display_name"], id.capitalized)
        tone = Tone(rawValue: J.s(json["tone"])) ?? .idle
        headline = J.s(json["headline"])
        reason = J.s(json["reason"])
        error = json["error"] as? String
        items = J.arr(json["sections"]).flatMap { J.arr($0["items"]) }.prefix(4).map { i in
            Item(title: J.s(i["title"]), subtitle: J.s(i["subtitle"]), url: Self.webURL(i["url"]))
        }
    }

    /// Only http(s) links open from a card.
    static func webURL(_ v: Any?) -> URL? {
        guard let s = v as? String, let u = URL(string: s), let scheme = u.scheme?.lowercased(),
              scheme == "https" || scheme == "http", u.host != nil else { return nil }
        return u
    }

    static func sorted(_ cards: [MacServiceCard]) -> [MacServiceCard] {
        cards.sorted { ($0.tone.rank, $0.name) < ($1.tone.rank, $1.name) }
    }
}

/// The `portfolio` topic: wallet + exchange balances and the crypto board.
struct MacPortfolio: Equatable {
    struct Quote: Equatable { let symbol: String; let price: String; let change: String; let up: Bool }

    let total: String?
    let accounts: [(label: String, value: String)]
    let quotes: [Quote]
    var isEmpty: Bool { total == nil && quotes.isEmpty }

    static func == (a: MacPortfolio, b: MacPortfolio) -> Bool {
        a.total == b.total && a.quotes == b.quotes && a.accounts.map(\.label) == b.accounts.map(\.label)
    }

    init(json: [String: Any]) {
        let p = J.obj(json["portfolio"])
        total = p["total_usd"] == nil ? nil : Self.money(J.d(p["total_usd"]) ?? 0, digits: 0)
        accounts = J.arr(p["accounts"]).map { (J.s($0["label"], J.s($0["name"])), Self.money(J.d($0["total_usd"]) ?? 0, digits: 0)) }
        quotes = J.arr(J.obj(json["crypto"])["quotes"]).prefix(6).map { q in
            let ch = J.d(q["change_24h"]) ?? 0
            let sign = ch < 0 ? "−" : "+"
            return Quote(symbol: J.s(q["symbol"]), price: Self.money(J.d(q["price"]) ?? 0, digits: 2),
                         change: "\(sign)\(String(format: "%.1f", abs(ch)))%", up: ch >= 0)
        }
    }

    static func money(_ v: Double, digits: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.locale = Locale(identifier: "en_US")
        f.maximumFractionDigits = digits
        f.minimumFractionDigits = digits
        return f.string(from: NSNumber(value: v)) ?? "$\(Int(v))"
    }
}

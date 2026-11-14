import Foundation

/// One field on a Power integration's settings form (`settings_schema` in `/api/power`).
struct PowerSetting: Identifiable, Equatable {
    enum Kind: String { case toggle, text, number, picker, secret }
    struct Option: Equatable { let value: String; let label: String }

    let key: String
    let label: String
    let kind: Kind
    let help: String
    let options: [Option]
    let min: Double?
    let max: Double?
    let unit: String
    var id: String { key }

    init?(json o: [String: Any]) {
        guard let key = o["key"] as? String, let raw = o["kind"] as? String,
              let kind = Kind(rawValue: raw) else { return nil }
        self.key = key
        self.kind = kind
        label = o["label"] as? String ?? key
        help = o["help"] as? String ?? ""
        options = (o["options"] as? [[String: Any]] ?? []).compactMap { opt in
            guard let value = opt["value"] else { return nil }
            return Option(value: "\(value)", label: opt["label"] as? String ?? "\(value)")
        }
        min = (o["min"] as? NSNumber)?.doubleValue
        max = (o["max"] as? NSNumber)?.doubleValue
        unit = o["unit"] as? String ?? ""
    }
}

/// A settings value as the server sent it. A secret only says whether it's set.
enum PowerValue: Equatable {
    case bool(Bool)
    case number(Double)
    case text(String)
    case secretSet(Bool)
    case none

    init(_ raw: Any?, kind: PowerSetting.Kind) {
        switch (kind, raw) {
        case (.secret, let o as [String: Any]): self = .secretSet(o["set"] as? Bool ?? false)
        case (.toggle, let b as Bool): self = .bool(b)
        case (.number, let n as NSNumber): self = .number(n.doubleValue)
        case (_, let s as String): self = .text(s)
        case (_, let n as NSNumber): self = .text(n.stringValue)
        default: self = .none
        }
    }
}

/// An existing screen a Power integration's page offers to open.
struct PowerLink: Equatable, Identifiable {
    let platform: String
    let target: String
    let label: String
    var id: String { platform + "/" + target }
}

/// One Power integration as `/api/power` describes it.
struct PowerRow: Identifiable, Equatable {
    let id: String
    let name: String
    let icon: String
    let summary: String
    let enabled: Bool
    let protected: Bool
    let statusLine: String
    let error: String?
    let settingsSchema: [PowerSetting]
    let settings: [String: PowerValue]
    let links: [PowerLink]
    let nativePieces: [String: Set<String>]
    let hasCard: Bool
    let hasPage: Bool
    let space: String

    init?(json o: [String: Any]) {
        guard let id = o["id"] as? String, !id.isEmpty else { return nil }
        self.id = id
        name = o["name"] as? String ?? id
        icon = o["icon"] as? String ?? "bolt.fill"
        summary = o["summary"] as? String ?? ""
        enabled = o["enabled"] as? Bool ?? true
        protected = o["protected"] as? Bool ?? false
        statusLine = o["status_line"] as? String ?? ""
        error = (o["error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let schema = (o["settings_schema"] as? [[String: Any]] ?? []).compactMap(PowerSetting.init(json:))
        settingsSchema = schema
        let values = o["settings"] as? [String: Any] ?? [:]
        settings = Dictionary(uniqueKeysWithValues: schema.map { ($0.key, PowerValue(values[$0.key], kind: $0.kind)) })
        links = (o["links"] as? [[String: Any]] ?? []).compactMap { l in
            guard let platform = l["platform"] as? String, let target = l["target"] as? String else { return nil }
            return PowerLink(platform: platform, target: target, label: l["label"] as? String ?? target)
        }
        nativePieces = (o["native"] as? [String: [String]] ?? [:]).mapValues(Set.init)
        hasCard = o["has_card"] as? Bool ?? false
        hasPage = o["has_page"] as? Bool ?? false
        space = o["space"] as? String ?? id
    }

    /// The links this device can open.
    var iosLinks: [PowerLink] { links.filter { $0.platform == "ios" } }
}

/// What a switch or settings change came back as.
enum PowerSetResult: Equatable {
    case done
    /// Waiting for Face ID on this iPhone (a protected integration, or a guarded setting).
    case pending
    case failed(String)
}

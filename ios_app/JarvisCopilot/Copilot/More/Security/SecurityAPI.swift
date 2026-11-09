import Foundation

/// `/api/security` on the Jarvis server — the Security Advisor (webui/api/security_routes.py).
/// Block and Allow on an alert carry a Face ID proof over `jarvis-security|<action>:<id>|<nonce>|<ts>`;
/// Dismiss, Undo and Settings need only the paired session.
///
/// The decoders are deliberately forgiving: ids may come as numbers or strings, lists bare or
/// wrapped, and any field may be missing.
struct SecurityAPI: Sendable {
    var api: JarvisAPI
    static let prefix = "/api/security"
    /// The Face ID message domain — never the car's or the door alarm's.
    static let domain = "jarvis-security"

    init(api: JarvisAPI = .shared) {
        self.api = api
    }

    func status() async throws -> SecurityStatus {
        SecurityStatus(json: try await api.get(Self.prefix + "/status", timeout: 20).object())
    }

    func alerts(status: String? = "open") async throws -> [SecurityAlert] {
        var query: [String: String] = [:]
        if let status { query["status"] = status }
        return Self.rows(try await api.get(Self.prefix + "/alerts", query: query, timeout: 20), "alerts")
            .compactMap(SecurityAlert.init(json:))
    }

    func events(limit: Int = 200) async throws -> [SecurityEvent] {
        Self.rows(try await api.get(Self.prefix + "/events", query: ["limit": String(limit)], timeout: 20), "events")
            .compactMap(SecurityEvent.init(json:))
    }

    func blocks() async throws -> [SecurityBlock] {
        Self.rows(try await api.get(Self.prefix + "/blocks", timeout: 20), "blocks").compactMap(SecurityBlock.init(json:))
    }

    func digests() async throws -> [SecurityDigest] {
        Self.rows(try await api.get(Self.prefix + "/digests", timeout: 20), "digests")
            .enumerated().map { SecurityDigest(json: $1, index: $0) }
    }

    func settings() async throws -> SecuritySettingsPayload {
        SecuritySettingsPayload(json: try await api.get(Self.prefix + "/settings", timeout: 20).object())
    }

    /// `action` is "block", "allow" or "dismiss"; block and allow need `proof`.
    func resolve(_ alertID: String, action: String, proof: ToyotaApprover.Proof?) async throws {
        var body: [String: Any] = ["action": action]
        if let proof {
            body["nonce"] = proof.nonce
            body["ts"] = proof.ts
            body["signature"] = proof.signature
        }
        _ = try await api.post(Self.prefix + "/alerts/\(Self.segment(alertID))/resolve", json: body, timeout: 20)
    }

    func undoBlock(_ ip: String) async throws {
        _ = try await api.post(Self.prefix + "/blocks/\(Self.segment(ip))/undo", timeout: 20)
    }

    func saveSettings(_ body: [String: Any]) async throws {
        _ = try await api.post(Self.prefix + "/settings", json: body, timeout: 20)
    }

    // MARK: Helpers

    /// A list answer: a bare array (read back as `{"data": [...]}`), or wrapped under `key` / `items`.
    static func rows(_ response: APIResponse, _ key: String) -> [[String: Any]] {
        guard let o = try? response.object() else { return [] }
        for k in [key, "data", "items"] {
            if let list = o[k] as? [[String: Any]] { return list }
        }
        return []
    }

    /// One path segment (an id or an IP — IPv6 has colons) safely escaped.
    static func segment(_ s: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

// MARK: - Models

/// A JSON scalar as text: ids and times come as strings or numbers.
func securityText(_ v: Any?) -> String? {
    switch v {
    case let s as String: return s.isEmpty ? nil : s
    case let n as NSNumber: return n.stringValue
    default: return nil
    }
}

private func securityInt(_ v: Any?) -> Int? {
    switch v {
    case let n as NSNumber: return n.intValue
    case let s as String: return Int(s)
    default: return nil
    }
}

struct SecurityStatus: Equatable, Sendable {
    let state: String
    let openAlerts: Int
    let blocks: Int
    let lastEventTime: String?
    let lastEventKind: String?
    /// "ssh" / "files" → "running", "off", an error …
    let sources: [String: String]
    let chainOK: Bool?

    init(json o: [String: Any]) {
        state = o["state"] as? String ?? "quiet"
        openAlerts = securityInt(o["open_alerts"]) ?? 0
        blocks = securityInt(o["blocks"]) ?? (o["blocks"] as? [Any])?.count ?? 0
        if let last = o["last_event"] as? [String: Any] {
            lastEventTime = securityText(last["ts"])
            lastEventKind = last["kind"] as? String
        } else {
            lastEventTime = securityText(o["last_event"])
            lastEventKind = nil
        }
        var sources: [String: String] = [:]
        for (k, v) in o["sources"] as? [String: Any] ?? [:] {
            if let text = securityText(v) { sources[k] = text }
            else if let d = v as? [String: Any], let text = securityText(d["state"] ?? d["status"]) { sources[k] = text }
            else if let b = v as? Bool { sources[k] = b ? "running" : "off" }
        }
        self.sources = sources
        chainOK = o["chain_ok"] as? Bool
    }
}

struct SecurityAlert: Identifiable, Equatable, Sendable {
    let id: String
    let eventID: String?
    let rule: String
    let title: String
    let summary: String?
    let explanation: String?
    let severity: String?
    let count: Int
    let status: String
    let created: String?
    let updated: String?

    var isOpen: Bool { status == "open" }

    init?(json o: [String: Any]) {
        guard let id = securityText(o["id"]) else { return nil }
        self.id = id
        eventID = securityText(o["event_id"])
        rule = o["rule"] as? String ?? ""
        title = (o["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (rule.isEmpty ? "Alert" : rule)
        summary = securityText(o["summary"])
        explanation = securityText(o["explanation"])
        severity = securityText(o["severity"])
        count = securityInt(o["count"]) ?? 1
        status = o["status"] as? String ?? "open"
        created = securityText(o["created"])
        updated = securityText(o["updated"])
    }
}

struct SecurityEvent: Identifiable, Equatable, Sendable {
    let id: String
    let ts: String?
    /// "device", "host" or "agent".
    let source: String
    let kind: String
    /// The server's readable name ("Failed sign-in"); older servers don't send it.
    let title: String?
    let actor: String?
    /// "ignore", "digest", "alert" or "block" once evaluated.
    let outcome: String?

    /// The row title: the readable name when there is one, else the raw kind.
    var displayTitle: String { title ?? kind }

    init?(json o: [String: Any]) {
        guard let id = securityText(o["id"]) else { return nil }
        self.id = id
        ts = securityText(o["ts"])
        source = o["source"] as? String ?? ""
        kind = (o["kind"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "event"
        title = (o["title"] as? String)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        actor = securityText(o["actor"])
        outcome = securityText(o["outcome"])
    }
}

struct SecurityBlock: Identifiable, Equatable, Sendable {
    let ip: String
    let reason: String?
    let until: String?
    var id: String { ip }

    init?(json o: [String: Any]) {
        guard let ip = o["ip"] as? String, !ip.isEmpty else { return nil }
        self.ip = ip
        reason = securityText(o["reason"])
        until = securityText(o["until"])
    }
}

struct SecurityDigest: Identifiable, Equatable, Sendable {
    let id: String
    let date: String?
    let text: String

    init(json o: [String: Any], index: Int) {
        id = securityText(o["id"]) ?? "digest-\(index)"
        date = securityText(o["date"] ?? o["day"] ?? o["created"] ?? o["ts"])
        text = securityText(o["text"] ?? o["summary"] ?? o["body"]) ?? ""
    }
}

/// The advisor's own settings (`security_advisor` in config.yaml).
struct SecuritySettings: Equatable, Sendable {
    var alertCapPerHour: Int
    var digestHour: Int
    var blockTTLHours: Int
    /// [from, to] local hours.
    var quietHours: [Int]
    var usualHours: [Int]
    var disabledRules: [String]

    init(json o: [String: Any]) {
        alertCapPerHour = securityInt(o["alert_cap_per_hour"]) ?? 3
        digestHour = securityInt(o["digest_hour"]) ?? 8
        blockTTLHours = securityInt(o["block_ttl_hours"]) ?? 24
        quietHours = Self.pair(o["quiet_hours"]) ?? [22, 7]
        usualHours = Self.pair(o["usual_hours"]) ?? [7, 23]
        disabledRules = o["disabled_rules"] as? [String] ?? []
    }

    var json: [String: Any] {
        ["alert_cap_per_hour": alertCapPerHour, "digest_hour": digestHour, "block_ttl_hours": blockTTLHours,
         "quiet_hours": quietHours, "usual_hours": usualHours, "disabled_rules": disabledRules]
    }

    private static func pair(_ v: Any?) -> [Int]? {
        guard let list = v as? [Any], list.count == 2 else { return nil }
        let hours = list.compactMap(securityInt)
        return hours.count == 2 ? hours : nil
    }
}

struct SecurityModelOption: Identifiable, Hashable, Sendable {
    let provider: String
    let model: String
    let label: String
    var id: String { provider + "|" + model }

    init(provider: String, model: String, label: String) {
        self.provider = provider
        self.model = model
        self.label = label.isEmpty ? model : label
    }

    /// A string ("@provider:model" or "model") or an object ({provider, model|id, label}).
    init?(any v: Any) {
        if let s = v as? String {
            if s.hasPrefix("@"), let colon = s.dropFirst().firstIndex(of: ":") {
                let model = String(s[s.index(after: colon)...])
                self.init(provider: String(s.dropFirst()[..<colon]), model: model, label: model)
            } else if !s.isEmpty {
                self.init(provider: "", model: s, label: s)
            } else {
                return nil
            }
        } else if let o = v as? [String: Any] {
            guard let model = securityText(o["model"] ?? o["id"] ?? o["name"]) else { return nil }
            self.init(provider: o["provider"] as? String ?? "", model: model,
                      label: securityText(o["label"] ?? o["title"] ?? o["name"]) ?? model)
        } else {
            return nil
        }
    }
}

/// `GET /settings`: the settings, the model in use and the models to pick from.
struct SecuritySettingsPayload: Equatable, Sendable {
    var settings: SecuritySettings
    var model: SecurityModelOption?
    var models: [SecurityModelOption]
    /// Rule ids the page can switch off, with a readable title when the server sends one.
    var rules: [(id: String, title: String)]

    init(json o: [String: Any]) {
        let s = o["settings"] as? [String: Any] ?? [:]
        settings = SecuritySettings(json: s)
        if let m = o["model"] as? [String: Any], let model = securityText(m["model"]) {
            self.model = SecurityModelOption(provider: m["provider"] as? String ?? "", model: model, label: model)
        } else {
            model = nil
        }
        var models = (o["models"] as? [Any] ?? []).compactMap(SecurityModelOption.init(any:))
        if let current = model, !models.contains(where: { $0.id == current.id }) { models.insert(current, at: 0) }
        self.models = models
        var rules: [(id: String, title: String)] = []
        for r in (o["rules"] as? [Any]) ?? (s["rules"] as? [Any]) ?? [] {
            if let id = r as? String { rules.append((id, id)) }
            else if let d = r as? [String: Any], let id = securityText(d["id"] ?? d["name"]) {
                rules.append((id, securityText(d["title"] ?? d["label"]) ?? id))
            }
        }
        for id in settings.disabledRules where !rules.contains(where: { $0.id == id }) { rules.append((id, id)) }
        self.rules = rules
    }

    static func == (a: Self, b: Self) -> Bool {
        a.settings == b.settings && a.model == b.model && a.models == b.models
            && a.rules.map(\.id) == b.rules.map(\.id) && a.rules.map(\.title) == b.rules.map(\.title)
    }
}

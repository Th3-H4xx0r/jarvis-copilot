import Foundation

/// The Jarvis Ball as the app sees it: a paired server device (`/api/devices`) whose
/// controls are the same `ball_*` bridge skills the agent uses, called through
/// `/api/devices/skills/invoke`. There is no second control path.

struct JarvisBallDevice: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var online: Bool
    var bridgeConnected: Bool
    var lastSeen: Date?
    var pairedAt: Date?

    static let userAgentPrefix = "JarvisBall/"

    static func from(devices: [[String: Any]]) -> [JarvisBallDevice] {
        devices.compactMap { d in
            guard let ua = d["user_agent"] as? String, ua.hasPrefix(userAgentPrefix),
                  let id = d["id"] as? String, !id.isEmpty else { return nil }
            return JarvisBallDevice(id: id, name: d["name"] as? String ?? "Jarvis Ball",
                                    online: d["online"] as? Bool ?? false,
                                    bridgeConnected: d["bridge_connected"] as? Bool ?? false,
                                    lastSeen: date(d["last_seen"]), pairedAt: date(d["paired_at"]))
        }
    }

    static func date(_ value: Any?) -> Date? {
        if let n = value as? Double, n > 0 { return Date(timeIntervalSince1970: n) }
        if let n = value as? Int, n > 0 { return Date(timeIntervalSince1970: TimeInterval(n)) }
        if let s = value as? String, !s.isEmpty {
            if let n = Double(s) { return Date(timeIntervalSince1970: n) }
            return ISO8601DateFormatter().date(from: s)
        }
        return nil
    }
}

struct JarvisBallStatus: Equatable, Sendable {
    var battery: Int?
    var charging = false
    var ssid = ""
    var rssi: Int?
    var ip = ""
    var link = ""
    var home = "orb"
    var homeTitle = "Orb"
    var shown = ""
    var touch = false
    var wakeWord = true
    var firmware = ""

    init(json o: [String: Any]) {
        let battery = o["battery"] as? [String: Any]
        self.battery = battery?["level"] as? Int
        charging = battery?["charging"] as? Bool ?? false
        let wifi = o["wifi"] as? [String: Any]
        ssid = wifi?["ssid"] as? String ?? ""
        rssi = (wifi?["rssi"] as? Int).flatMap { $0 == 0 ? nil : $0 }
        ip = wifi?["ip"] as? String ?? ""
        link = o["link"] as? String ?? ""
        let page = o["page"] as? [String: Any]
        home = page?["home"] as? String ?? "orb"
        homeTitle = page?["home_title"] as? String ?? home
        shown = page?["shown"] as? String ?? ""
        touch = o["touch"] as? Bool ?? false
        wakeWord = o["wake_word"] as? Bool ?? true
        firmware = o["fw"] as? String ?? ""
    }
}

struct JarvisBallSettings: Equatable, Sendable {
    var home = "orb"
    var brightness = 0
    var volume = 0
    var wakeWord = true
    var accent = ""
    var timezone = ""
    var tzPosix = ""
    var clock24h = false

    init(json o: [String: Any]) {
        home = o["home"] as? String ?? "orb"
        brightness = o["brightness"] as? Int ?? 0
        volume = o["volume"] as? Int ?? 0
        wakeWord = o["wake_word"] as? Bool ?? true
        accent = ((o["theme"] as? [String: Any])?["accent"] as? String ?? "").uppercased()
        timezone = o["timezone"] as? String ?? ""
        tzPosix = o["tz_posix"] as? String ?? ""
        clock24h = o["clock_24h"] as? Bool ?? false
    }
}

struct JarvisBallHome: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var builtin: Bool

    static func list(_ o: [String: Any]) -> [JarvisBallHome] {
        (o["pages"] as? [[String: Any]] ?? []).compactMap { p in
            guard let id = p["id"] as? String else { return nil }
            return JarvisBallHome(id: id, title: p["title"] as? String ?? id, builtin: p["builtin"] as? Bool ?? false)
        }
    }
}

/// What the ball needs from the app's look and locale, derived from the single sources
/// (`JcAccent.hex`, `JcTheme.*Hex`, the phone's time zone and clock format).
enum JarvisBallLook {
    static func hex(_ v: UInt32) -> String { String(format: "#%06X", v & 0xFFFFFF) }

    static var theme: [String: String] {
        ["accent": hex(JcAccent.hex), "success": hex(JcTheme.successHex),
         "warning": hex(JcTheme.amberHex), "danger": hex(JcTheme.dangerHex)]
    }

    static var clock24h: Bool {
        let format = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? ""
        return !format.contains("a")
    }

    /// The POSIX TZ string the ball's C library needs, e.g. "STD8DST,M3.2.0,M11.1.0" for
    /// Los Angeles. Built from the zone's next two DST transitions; zone names don't matter.
    static func posixTZ(_ tz: TimeZone, now: Date = Date()) -> String {
        guard let t1 = tz.nextDaylightSavingTimeTransition(after: now),
              let t2 = tz.nextDaylightSavingTimeTransition(after: t1) else {
            return "STD" + offset(-tz.secondsFromGMT(for: now))
        }
        let startsDST = tz.isDaylightSavingTime(for: t1.addingTimeInterval(60))
        let start = startsDST ? t1 : t2
        let end = startsDST ? t2 : t1
        let std = tz.secondsFromGMT(for: end.addingTimeInterval(60))
        let dst = tz.secondsFromGMT(for: start.addingTimeInterval(60))
        var out = "STD" + offset(-std) + "DST"
        if dst - std != 3600 { out += offset(-dst) }
        return out + "," + rule(start, wallOffset: std) + "," + rule(end, wallOffset: dst)
    }

    private static func offset(_ seconds: Int) -> String {
        let sign = seconds < 0 ? "-" : ""
        let a = abs(seconds)
        let h = a / 3600, m = (a % 3600) / 60
        return m == 0 ? "\(sign)\(h)" : "\(sign)\(h):" + String(format: "%02d", m)
    }

    /// "Mm.w.d[/time]" in the wall-clock time in effect just before the transition.
    private static func rule(_ transition: Date, wallOffset: Int) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let wall = transition.addingTimeInterval(TimeInterval(wallOffset))
        let c = cal.dateComponents([.month, .day, .weekday, .hour, .minute], from: wall)
        let days = cal.range(of: .day, in: .month, for: wall)?.count ?? 31
        let day = c.day ?? 1
        let week = day + 7 > days ? 5 : (day - 1) / 7 + 1
        var out = "M\(c.month ?? 1).\(week).\((c.weekday ?? 1) - 1)"
        let hour = c.hour ?? 2, minute = c.minute ?? 0
        if hour != 2 || minute != 0 {
            out += "/" + (minute == 0 ? "\(hour)" : "\(hour):" + String(format: "%02d", minute))
        }
        return out
    }
}

struct JarvisBallAPI: Sendable {
    func balls() async throws -> [JarvisBallDevice] {
        let list = try await JarvisAPI.shared.get("/api/devices").array(key: "devices")
        return JarvisBallDevice.from(devices: list.compactMap { $0 as? [String: Any] })
    }

    func invoke(_ deviceID: String, _ skill: String, _ args: [String: Any] = [:]) async throws -> [String: Any] {
        let obj = try await JarvisAPI.shared.post("/api/devices/skills/invoke",
                                                  json: ["device_id": deviceID, "skill": skill, "args": args, "timeout": 20],
                                                  timeout: 30).object()
        if obj["ok"] as? Bool == false {
            throw APIError.badResponse(obj["error"] as? String ?? "the ball didn't answer")
        }
        return obj["result"] as? [String: Any] ?? [:]
    }

    func status(_ id: String) async throws -> JarvisBallStatus { JarvisBallStatus(json: try await invoke(id, "ball_status")) }
    func settings(_ id: String) async throws -> JarvisBallSettings { JarvisBallSettings(json: try await invoke(id, "ball_settings_get")) }
    func homes(_ id: String) async throws -> [JarvisBallHome] { JarvisBallHome.list(try await invoke(id, "ball_home_list")) }

    @discardableResult
    func setSettings(_ id: String, _ changes: [String: Any]) async throws -> JarvisBallSettings {
        JarvisBallSettings(json: try await invoke(id, "ball_settings_set", changes))
    }

    func deleteHome(_ id: String, home: String) async throws { _ = try await invoke(id, "ball_home_delete", ["id": home]) }

    /// What the ball's screen shows right now, as JPEG bytes.
    func snapshot(_ id: String) async throws -> Data? {
        let o = try await invoke(id, "ball_snapshot")
        guard let uri = o["image"] as? String, let comma = uri.firstIndex(of: ",") else { return nil }
        return Data(base64Encoded: String(uri[uri.index(after: comma)...]))
    }
    func reboot(_ id: String) async throws { _ = try await invoke(id, "ball_reboot") }
}

// MARK: - Server side of setup

struct BallPairing: Equatable, Sendable {
    var code: String
    var cfID: String
    var cfSecret: String
}

protocol BallServerTalking: Sendable {
    func serverURL() async -> String
    func pairStart(label: String) async throws -> BallPairing
    /// True once the server lists `name` as a freshly paired ball holding its bridge.
    func ballOnline(name: String, since: Date) async -> Bool
}

struct JarvisBallServer: BallServerTalking {
    func serverURL() async -> String { await MainActor.run { BridgeClient.shared.serverURL } }

    func pairStart(label: String) async throws -> BallPairing {
        let obj = try await JarvisAPI.shared.post("/api/devices/pair/start", json: ["label": label, "ttl": 600], timeout: 30).object()
        guard let code = obj["code"] as? String, !code.isEmpty else {
            throw APIError.badResponse("the server returned no pairing code")
        }
        let cf = obj["cf_access"] as? [String: Any]
        let fallback = await MainActor.run { BridgeClient.shared.cfAccessToken }
        let id = (cf?["client_id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallback?.id ?? ""
        let secret = (cf?["client_secret"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallback?.secret ?? ""
        return BallPairing(code: code, cfID: id, cfSecret: secret)
    }

    func ballOnline(name: String, since: Date) async -> Bool {
        guard let balls = try? await JarvisBallAPI().balls() else { return false }
        return balls.contains { $0.name == name && $0.bridgeConnected && ($0.pairedAt ?? .distantFuture) >= since.addingTimeInterval(-30) }
    }
}

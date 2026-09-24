import Foundation

/// The Jarvis Pod as the app sees it: a paired server device (`/api/devices`) whose
/// controls are the same `pod_*` bridge skills the agent uses, called through
/// `/api/devices/skills/invoke`. There is no second control path.

struct JarvisPodDevice: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var online: Bool
    var bridgeConnected: Bool
    var lastSeen: Date?
    var pairedAt: Date?

    static let userAgentPrefix = "JarvisPod/"

    static func from(devices: [[String: Any]]) -> [JarvisPodDevice] {
        devices.compactMap { d in
            guard let ua = d["user_agent"] as? String, ua.hasPrefix(userAgentPrefix),
                  let id = d["id"] as? String, !id.isEmpty else { return nil }
            return JarvisPodDevice(id: id, name: d["name"] as? String ?? "Jarvis Pod",
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

struct JarvisPodStatus: Equatable, Sendable {
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

struct JarvisPodSettings: Equatable, Sendable {
    var home = "orb"
    var brightness = 0
    var volume = 0
    var wakeWord = true
    var accent = ""
    var timezone = ""
    var tzPosix = ""
    var clock24h = false
    var noiseCancel = true
    /// How long a pause ends your turn ("Pause before Jarvis answers"). The Pod's old
    /// fixed 550 ms cut sentences in half at a breath.
    var endPauseMs = 1000

    static let endPauseChoices = [600, 800, 1000, 1300, 1600, 2000, 2500]

    static func endPauseLabel(_ ms: Int) -> String {
        let seconds = Double(ms) / 1000
        return seconds == seconds.rounded() ? "\(Int(seconds)) s" : String(format: "%.1f s", seconds)
    }

    init(json o: [String: Any]) {
        home = o["home"] as? String ?? "orb"
        brightness = o["brightness"] as? Int ?? 0
        volume = o["volume"] as? Int ?? 0
        wakeWord = o["wake_word"] as? Bool ?? true
        accent = ((o["theme"] as? [String: Any])?["accent"] as? String ?? "").uppercased()
        timezone = o["timezone"] as? String ?? ""
        tzPosix = o["tz_posix"] as? String ?? ""
        clock24h = o["clock_24h"] as? Bool ?? false
        noiseCancel = o["noise_cancel"] as? Bool ?? true
        endPauseMs = o["end_pause_ms"] as? Int ?? 1000
    }
}

struct JarvisPodHome: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var builtin: Bool

    static func list(_ o: [String: Any]) -> [JarvisPodHome] {
        (o["pages"] as? [[String: Any]] ?? []).compactMap { p in
            guard let id = p["id"] as? String else { return nil }
            return JarvisPodHome(id: id, title: p["title"] as? String ?? id, builtin: p["builtin"] as? Bool ?? false)
        }
    }
}

/// What the pod needs from the app's look and locale, derived from the single sources
/// (`JcAccent.hex`, `JcTheme.*Hex`, the phone's time zone and clock format).
enum JarvisPodLook {
    static func hex(_ v: UInt32) -> String { String(format: "#%06X", v & 0xFFFFFF) }

    static var theme: [String: String] {
        ["accent": hex(JcAccent.hex), "success": hex(JcTheme.successHex),
         "warning": hex(JcTheme.amberHex), "danger": hex(JcTheme.dangerHex)]
    }

    static var clock24h: Bool {
        let format = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? ""
        return !format.contains("a")
    }

    /// The POSIX TZ string the pod's C library needs, e.g. "STD8DST,M3.2.0,M11.1.0" for
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

/// One voice turn the pod streamed, kept by the server (webui/api/voice_recordings.py).
struct JarvisPodRecording: Identifiable, Equatable, Sendable {
    let id: String
    let date: Date
    let durationMs: Int
    let transcript: String
    /// Saved after noise cancelling (the pod's setting was on).
    let cleaned: Bool

    init?(json: [String: Any]?) {
        guard let json, let id = json["id"] as? String, !id.isEmpty else { return nil }
        self.id = id
        date = Date(timeIntervalSince1970: (json["ts"] as? Double) ?? 0)
        durationMs = json["duration_ms"] as? Int ?? 0
        transcript = (json["transcript"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = json["cleaned"] as? Bool ?? false
    }

    var durationText: String {
        let s = max(1, Int((Double(durationMs) / 1000).rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// The chat and model a pod talks to, kept on the server (so it can be set while the
/// pod is offline). Empty fields are the voice defaults: the Voice chat, and "Auto".
struct JarvisPodVoice: Equatable, Sendable {
    var sessionID = ""
    var model = ""
    var provider = ""

    init(sessionID: String = "", model: String = "", provider: String = "") {
        self.sessionID = sessionID
        self.model = model
        self.provider = provider
    }

    init(json: [String: Any]) {
        sessionID = json["session_id"] as? String ?? ""
        model = json["model"] as? String ?? ""
        provider = json["provider"] as? String ?? ""
    }

    func body(podID: String) -> [String: Any] {
        ["device_id": podID, "session_id": sessionID, "model": model, "provider": provider]
    }
}

struct JarvisPodAPI: Sendable {
    func pods() async throws -> [JarvisPodDevice] {
        let list = try await JarvisAPI.shared.get("/api/devices").array(key: "devices")
        return JarvisPodDevice.from(devices: list.compactMap { $0 as? [String: Any] })
    }

    func invoke(_ deviceID: String, _ skill: String, _ args: [String: Any] = [:]) async throws -> [String: Any] {
        let obj = try await JarvisAPI.shared.post("/api/devices/skills/invoke",
                                                  json: ["device_id": deviceID, "skill": skill, "args": args, "timeout": 20],
                                                  timeout: 30).object()
        if obj["ok"] as? Bool == false {
            throw APIError.badResponse(obj["error"] as? String ?? "the pod didn't answer")
        }
        return obj["result"] as? [String: Any] ?? [:]
    }

    func status(_ id: String) async throws -> JarvisPodStatus { JarvisPodStatus(json: try await invoke(id, "pod_status")) }
    func settings(_ id: String) async throws -> JarvisPodSettings { JarvisPodSettings(json: try await invoke(id, "pod_settings_get")) }
    func homes(_ id: String) async throws -> [JarvisPodHome] { JarvisPodHome.list(try await invoke(id, "pod_home_list")) }

    @discardableResult
    func setSettings(_ id: String, _ changes: [String: Any]) async throws -> JarvisPodSettings {
        JarvisPodSettings(json: try await invoke(id, "pod_settings_set", changes))
    }

    func deleteHome(_ id: String, home: String) async throws { _ = try await invoke(id, "pod_home_delete", ["id": home]) }

    /// What the pod's screen shows right now, as JPEG bytes.
    func snapshot(_ id: String) async throws -> Data? {
        let o = try await invoke(id, "pod_snapshot")
        guard let uri = o["image"] as? String, let comma = uri.firstIndex(of: ",") else { return nil }
        return Data(base64Encoded: String(uri[uri.index(after: comma)...]))
    }
    func reboot(_ id: String) async throws { _ = try await invoke(id, "pod_reboot") }

    // Recordings live on the server, so they work while the pod is offline.
    func recordings(_ id: String) async throws -> [JarvisPodRecording] {
        try await JarvisAPI.shared.get("/api/devices/pod/recordings", query: ["device_id": id])
            .array(key: "recordings").compactMap { JarvisPodRecording(json: $0 as? [String: Any]) }
    }

    func recordingAudio(_ id: String, _ recordingID: String) async throws -> Data {
        try await JarvisAPI.shared.get("/api/devices/pod/recordings/audio",
                                       query: ["device_id": id, "id": recordingID]).data
    }

    /// The pod's name lives on its server device record.
    func rename(_ id: String, to name: String) async throws {
        _ = try await JarvisAPI.shared.post("/api/devices/\(id)/rename", json: ["name": name])
    }

    func voice(_ id: String) async throws -> JarvisPodVoice {
        JarvisPodVoice(json: try await JarvisAPI.shared.get("/api/devices/pod/voice", query: ["device_id": id]).object())
    }

    @discardableResult
    func setVoice(_ id: String, _ voice: JarvisPodVoice) async throws -> JarvisPodVoice {
        JarvisPodVoice(json: try await JarvisAPI.shared.post("/api/devices/pod/voice", json: voice.body(podID: id)).object())
    }

    func deleteRecording(_ id: String, _ recordingID: String) async throws {
        _ = try await JarvisAPI.shared.post("/api/devices/pod/recordings/delete",
                                            json: ["device_id": id, "id": recordingID])
    }
}

// MARK: - Server side of setup

struct PodPairing: Equatable, Sendable {
    var code: String
    var cfID: String
    var cfSecret: String
}

protocol PodServerTalking: Sendable {
    func serverURL() async -> String
    func pairStart(label: String) async throws -> PodPairing
    /// True once the server lists `name` as a freshly paired pod holding its bridge.
    func podOnline(name: String, since: Date) async -> Bool
}

struct JarvisPodServer: PodServerTalking {
    func serverURL() async -> String { await MainActor.run { BridgeClient.shared.serverURL } }

    func pairStart(label: String) async throws -> PodPairing {
        let obj = try await JarvisAPI.shared.post("/api/devices/pair/start", json: ["label": label, "ttl": 600], timeout: 30).object()
        guard let code = obj["code"] as? String, !code.isEmpty else {
            throw APIError.badResponse("the server returned no pairing code")
        }
        let cf = obj["cf_access"] as? [String: Any]
        let fallback = await MainActor.run { BridgeClient.shared.cfAccessToken }
        let id = (cf?["client_id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallback?.id ?? ""
        let secret = (cf?["client_secret"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallback?.secret ?? ""
        return PodPairing(code: code, cfID: id, cfSecret: secret)
    }

    func podOnline(name: String, since: Date) async -> Bool {
        guard let pods = try? await JarvisPodAPI().pods() else { return false }
        return pods.contains { $0.name == name && $0.bridgeConnected && ($0.pairedAt ?? .distantFuture) >= since.addingTimeInterval(-30) }
    }
}

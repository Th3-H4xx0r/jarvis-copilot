import Foundation

// The server's `speech:` settings over `/api/speech/*`: which engine turns speech
// into text for Voice (phone, Mac, web, Jarvis Pod), Live and uploads, and every
// Soniox option. One source of truth with the web's Settings → Speech block —
// nothing here is stored on the phone. The Soniox key only ever goes up: the
// server answers with whether one is saved and its last four characters.
//
// Under `Voice/` so the Mac client (which shares this directory) can pick the
// engine for its own voice panel.

struct SpeechEngineInfo: Equatable, Sendable, Identifiable {
    var id: String { name }
    let name: String
    let label: String
    let streams: Bool
    let available: Bool
    /// Why it cannot run right now ("no SONIOX_API_KEY", …); empty when it can.
    let reason: String
}

struct SpeechLanguage: Equatable, Sendable, Identifiable {
    var id: String { code }
    let code: String
    let name: String
}

struct SpeechSoniox: Equatable, Sendable {
    var model = "stt-rt-v5"
    var languageHints: [String] = []
    var speakerLabels = true
    var languageID = true
    var customWords: [String] = []
    var endpointLatencyLevel = 2
    var endpointSensitivity = 0.3
    var maxEndpointDelayMs = 2000
    var liveQuietCloseS = 60
}

struct SpeechSettings: Equatable, Sendable {
    /// `live` also takes this: the phone transcribes itself (today's lane).
    static let edge = "edge"

    var voice = "local"
    /// The Jarvis Pod's turns (its own choice; the server defaults it to Soniox).
    var pod = "soniox"
    var live = SpeechSettings.edge
    var upload = "local"
    var soniox = SpeechSoniox()
    var engines: [SpeechEngineInfo] = []
    var languages: [SpeechLanguage] = []
    var keySet = false
    var keyHint = ""
    var todaySeconds = 0
    var monthSeconds = 0
    var monthUSD = 0.0

    static func from(_ d: [String: Any]) -> SpeechSettings {
        var out = SpeechSettings()
        out.apply(config: d.dict("config") ?? [:])
        out.engines = d.list("engines").map {
            SpeechEngineInfo(name: $0.string("name") ?? "", label: $0.string("label") ?? $0.string("name") ?? "",
                             streams: $0.bool("streams") ?? false, available: $0.bool("available") ?? false,
                             reason: $0.string("reason") ?? "")
        }.filter { !$0.name.isEmpty }
        out.languages = d.list("languages").compactMap {
            guard let code = $0.string("code"), !code.isEmpty else { return nil }
            return SpeechLanguage(code: code, name: $0.string("name") ?? code)
        }
        let key = d.dict("soniox_key") ?? [:]
        out.keySet = key.bool("set") ?? false
        out.keyHint = key.string("hint") ?? ""
        let usage = d.dict("usage") ?? [:]
        out.todaySeconds = usage.int("today_s") ?? 0
        out.monthSeconds = usage.int("month_s") ?? 0
        out.monthUSD = usage.double("est_usd") ?? 0
        return out
    }

    /// The `config` part of a GET or of a PUT's reply.
    mutating func apply(config c: [String: Any]) {
        let surfaces = c.dict("surfaces") ?? [:]
        if let v = surfaces.string("voice"), !v.isEmpty { voice = v }
        if let v = surfaces.string("pod"), !v.isEmpty { pod = v }
        if let v = surfaces.string("live"), !v.isEmpty { live = v }
        if let v = surfaces.string("upload"), !v.isEmpty { upload = v }
        let s = c.dict("soniox") ?? [:]
        if let v = s.string("model"), !v.isEmpty { soniox.model = v }
        if let v = s["language_hints"] as? [Any] { soniox.languageHints = v.compactMap { $0 as? String } }
        if let v = s.bool("speaker_labels") { soniox.speakerLabels = v }
        if let v = s.bool("language_id") { soniox.languageID = v }
        if let v = s["custom_words"] as? [Any] { soniox.customWords = v.compactMap { $0 as? String } }
        if let v = s.int("endpoint_latency_level") { soniox.endpointLatencyLevel = v }
        if let v = s.double("endpoint_sensitivity") { soniox.endpointSensitivity = v }
        if let v = s.int("max_endpoint_delay_ms") { soniox.maxEndpointDelayMs = v }
        if let v = s.int("live_quiet_close_s") { soniox.liveQuietCloseS = v }
    }

    func engine(_ name: String) -> SpeechEngineInfo? { engines.first { $0.name == name } }

    var streamingEngines: [SpeechEngineInfo] { engines.filter(\.streams) }

    func label(for name: String) -> String {
        name == Self.edge ? "On this phone (Apple)" : (engine(name)?.label ?? name)
    }

    func languageName(_ code: String) -> String {
        languages.first { $0.code == code }?.name ?? code
    }

    func surface(_ name: String) -> String {
        switch name {
        case "voice": return voice
        case "pod": return pod
        case "live": return live
        default: return upload
        }
    }

    mutating func setSurface(_ name: String, _ engine: String) {
        switch name {
        case "voice": voice = engine
        case "pod": pod = engine
        case "live": live = engine
        default: upload = engine
        }
    }
}

struct SpeechEngineAPI: Sendable {
    let api: JarvisAPI

    init(api: JarvisAPI = .shared) {
        self.api = api
    }

    func load() async throws -> SpeechSettings {
        SpeechSettings.from(try await api.get("/api/speech/config").object())
    }

    /// PUT a patch (just the keys that changed); the reply's `config` is the
    /// server's effective settings. POST on a 404/405, like Live's config.
    func save(_ patch: [String: Any]) async throws -> [String: Any] {
        do {
            return try await api.put("/api/speech/config", json: patch).object().dict("config") ?? [:]
        } catch APIError.http(let status, _) where status == 404 || status == 405 {
            return try await api.post("/api/speech/config", json: patch).object().dict("config") ?? [:]
        }
    }

    /// Save ("" removes) the Soniox key. Returns what the server now says about it.
    func saveKey(_ key: String) async throws -> (set: Bool, hint: String) {
        let reply = try await api.post("/api/speech/soniox-key", json: ["api_key": key]).object()
        let status = reply.dict("soniox_key") ?? [:]
        return (status.bool("set") ?? false, status.string("hint") ?? "")
    }

    /// One tiny session with the saved key.
    func test() async throws -> (ok: Bool, message: String) {
        let reply = try await api.post("/api/speech/test", json: [String: Any](), timeout: 20).object()
        return (reply.bool("ok") ?? false, reply.string("message") ?? "")
    }
}

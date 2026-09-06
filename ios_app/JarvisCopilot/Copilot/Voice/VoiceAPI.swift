import Foundation

// MARK: - Models

/// One TTS engine from `GET /api/voice/engines`.
struct VoiceEngine: Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let requiresKey: Bool
    /// How the engine names a voice: "preset" (a list), "model" (a local file),
    /// "custom" (a free-form id, e.g. a Fish Audio model).
    let voiceKind: String
    /// The engine can run end-to-end with the server's current settings.
    let configured: Bool
    /// The engine the server is currently synthesizing with.
    let active: Bool
    let hasAPIKey: Bool
    /// Voice **ids** — what `/api/voice/synthesize` wants.
    let voices: [String]
    /// Voice id → human label, for a picker that wants to read "Ryan (en-GB,
    /// male)" rather than "en-GB-RyanNeural".
    let voiceLabels: [String: String]
    /// Only for `voiceKind == "custom"`.
    let voiceID: String?
    let voiceIDHint: String?

    static func from(_ d: [String: Any]) -> VoiceEngine {
        let (ids, labels) = parseVoices(d["voices"])
        return VoiceEngine(
            id: d.string("id") ?? "",
            name: d.string("name") ?? (d.string("id") ?? ""),
            requiresKey: d.bool("requires_key") ?? false,
            voiceKind: d.string("voice_kind") ?? "preset",
            configured: d.bool("configured") ?? false,
            active: d.bool("active") ?? false,
            hasAPIKey: d.bool("has_api_key") ?? false,
            voices: ids,
            voiceLabels: labels,
            voiceID: d.string("voice_id"),
            voiceIDHint: d.string("voice_id_hint"))
    }

    /// The server sends `voices` as objects — `[{"id": "en-GB-RyanNeural",
    /// "name": "Ryan (en-GB, male)"}, …]` (voice.py `_BUILTIN_VOICES`). Reading
    /// it as `[String]` matched nothing, so every engine looked like it had no
    /// voices and the picker could never offer one. A plain string array is
    /// still accepted for older servers.
    static func parseVoices(_ raw: Any?) -> (ids: [String], labels: [String: String]) {
        guard let list = raw as? [Any] else { return ([], [:]) }
        var ids: [String] = []
        var labels: [String: String] = [:]
        for item in list {
            if let id = item as? String, !id.isEmpty {
                ids.append(id)
            } else if let object = item as? [String: Any] {
                guard let id = object.string("id"), !id.isEmpty else { continue }
                ids.append(id)
                if let name = object.string("name"), !name.isEmpty { labels[id] = name }
            }
        }
        return (ids, labels)
    }
}

struct VoiceEngineList: Equatable, Sendable {
    var engines: [VoiceEngine] = []
    /// Id of the engine the server is using, or "" when unset.
    var active: String = ""

    /// Only engines that can actually speak — the picker must not offer one that
    /// will 500 for a missing API key.
    var usable: [VoiceEngine] { engines.filter(\.configured) }
}

/// One NDJSON frame from `POST /api/voice/quality-turn`.
struct VoiceQualityEvent: Equatable, Sendable {
    /// `transcript` | `segment` | `error` | `done`
    let type: String
    /// `text` | `tool`, for `segment`.
    let kind: String?
    let text: String?
    let name: String?
    let status: String?
    /// Decoded `audio_base64` (MP3).
    let audio: Data?
    let error: String?

    static func from(_ d: [String: Any]) -> VoiceQualityEvent {
        var audio: Data?
        if let b64 = d.string("audio_base64"), !b64.isEmpty {
            audio = Data(base64Encoded: b64)
        }
        return VoiceQualityEvent(
            type: d.string("type") ?? "",
            kind: d.string("kind"),
            text: d.string("text"),
            name: d.string("name"),
            status: d.string("status"),
            audio: audio,
            error: d.string("error"))
    }
}

// MARK: - Client

/// Voice endpoints: engine list, the dedicated voice session, one-shot TTS, the
/// push-to-talk NDJSON turn, and the URL of the realtime WebSocket.
/// Port of `api/voice.dart`.
struct VoiceAPI: Sendable {
    let api: JarvisAPI

    init(api: JarvisAPI = .shared) { self.api = api }

    func listEngines() async throws -> VoiceEngineList {
        let obj = try await api.get("/api/voice/engines").object()
        return VoiceEngineList(engines: obj.list("engines").map(VoiceEngine.from),
                               active: obj.string("active") ?? "")
    }

    /// The server's dedicated, persistent "Voice" chat session id (get-or-created
    /// server-side with a valid model/provider). Voice turns route here instead
    /// of the user's most-recent chat — which could be a coding/CLI/Telegram
    /// channel wired to a provider+model voice can't run.
    func voiceSessionID() async throws -> String {
        let obj = try await api.get("/api/voice/session").object()
        return obj.string("session_id") ?? ""
    }

    /// Synthesize `text` to raw audio bytes in the JARVIS voice. The reply body
    /// is the audio itself (audio/mpeg or audio/wav), not JSON.
    func synthesize(text: String, format: String = "mp3",
                    voice: String? = nil, engine: String? = nil) async throws -> Data {
        var body: [String: Any] = ["text": text, "format": format]
        if let voice, !voice.isEmpty { body["voice"] = voice }
        if let engine, !engine.isEmpty { body["engine"] = engine }
        return try await api.post("/api/voice/synthesize", json: body, timeout: 120).data
    }

    /// Same, but never throws — returns empty so the caller can fall back to text
    /// or to the local synthesizer (Dart's `ttsBytes`, used when offline).
    func synthesizeOrEmpty(text: String, format: String = "mp3",
                           voice: String? = nil, engine: String? = nil) async -> Data {
        do { return try await synthesize(text: text, format: format, voice: voice, engine: engine) }
        catch {
            // The caller decides what to show; without this line a silent reply
            // is indistinguishable from a device with the volume down.
            JcLog.dropped(JcLog.voice, "synthesize", error)
            return Data()
        }
    }

    /// Push-to-talk: one clip in, transcript + text + MP3 segments streaming back.
    ///
    /// `audio` is RAW mono PCM16-LE at `sampleRate` — not a WAV; the server
    /// base64-decodes it straight into its own container. `extra` carries the
    /// surface's `model` / `model_provider` when one is picked.
    func qualityTurn(audio: Data, sessionID: String, sampleRate: Int = 16000,
                     extra: [String: Any] = [:]) -> AsyncThrowingStream<VoiceQualityEvent, Error> {
        var body: [String: Any] = [
            "audio_base64": audio.base64EncodedString(),
            "sample_rate": sampleRate,
            "session_id": sessionID,
        ]
        for (key, value) in extra { body[key] = value }
        let raw = api.streamNDJSON("/api/voice/quality-turn", method: "POST", json: body)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await obj in raw { continuation.yield(VoiceQualityEvent.from(obj)) }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// `ws(s)://host/api/voice/s2s/ws` — derived from the API base URL, not from
    /// a stored server URL, so the voice socket follows the LAN-direct
    /// preference too instead of always taking the tunnel.
    func realtimeURL(params: [String: String] = [:]) throws -> URL {
        guard let base = api.credentials.baseURL else { throw APIError.notPaired }
        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw APIError.badResponse("bad base URL")
        }
        switch comps.scheme?.lowercased() {
        case "https", "wss": comps.scheme = "wss"
        case "http", "ws": comps.scheme = "ws"
        default: throw APIError.badResponse("serverUrl must be http(s)://…")
        }
        let root = comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path
        comps.path = root + "/api/voice/s2s/ws"
        if !params.isEmpty {
            comps.queryItems = params.keys.sorted().map { URLQueryItem(name: $0, value: params[$0]) }
        }
        guard let url = comps.url else { throw APIError.badResponse("bad URL") }
        return url
    }

    /// Cancel any stream the server still has running for `sessionID`. Called
    /// before starting a turn so a previously-orphaned turn (the app was
    /// backgrounded mid-reply) doesn't block us with "session already has an
    /// active stream". Best effort — if it fails we still try the turn.
    func cancelActiveStream(sessionID: String) async {
        do {
            let body = try await api.get("/api/session",
                                         query: ["session_id": sessionID, "messages": "0"]).object()
            let session = body.dict("session") ?? body
            let streamID = session.string("active_stream_id") ?? ""
            guard !streamID.isEmpty else { return }
            _ = try await api.get("/api/chat/cancel", query: ["stream_id": streamID])
        } catch {
            // Best effort: the turn still runs, it may just hit "session already
            // has an active stream".
            JcLog.dropped(JcLog.voice, "cancel active stream", error)
        }
    }
}

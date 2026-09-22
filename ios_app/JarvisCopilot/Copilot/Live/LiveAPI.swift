import Foundation

// MARK: - Config

/// The `live:` section of `config.yaml`, over `GET/PUT /api/live/config`.
///
/// One source of truth shared with the web client (design §6), so every key the
/// contract names is present here even when this screen is not the obvious place
/// to edit it — a client that silently omits a key on PUT would erase whatever the
/// web popup set.
struct LiveConfig: Equatable, Sendable {
    var enabled = true
    /// How often the monitor watcher runs.
    var windowSeconds = 120
    /// Below this many new words a window is skipped, so silence is free.
    var minWindowWords = 25
    var monitor = true
    var factCheck = true
    var translate = true
    var memoryExtraction = true
    var artifacts = true
    /// `"text"` | `"spoken"`.
    var replyMode = "text"
    /// BCP-47, e.g. `en-US`.
    var primaryLanguage = "en-US"
    /// The canonical embedding-model id (design §5.3). Read-only from the phone:
    /// the interlock is the server's to declare, and a client that edited it could
    /// silently corrupt speaker identity.
    var embedModel = ""
    /// When a live session rolls over into a new one: once its transcript
    /// reaches this share of the model's context window. 0.05...1.0.
    ///
    /// The DECISION is the server's and only the server's — it is the one place
    /// that knows the model, counts the tokens, and can answer the same way for
    /// every device. This is the knob, not the rule.
    var sessionRolloverFraction = 0.5
    /// An explicit token ceiling that wins over the fraction when non-zero, for
    /// naming the number rather than trusting a context lookup. 0 = use the
    /// fraction.
    var sessionRolloverTokens = 0
    /// How much of the recent conversation a fact-check reads, in tokens.
    ///
    /// Mirrors the server's `live.fact_check_tokens` default rather than being a
    /// second opinion about it: the value the user sees is whatever
    /// `/api/live/config` sends, and this is only what a struct built before the
    /// first GET says.
    var factCheckTokens = 1000

    static func from(_ d: [String: Any]) -> LiveConfig {
        // The server may nest it under `config`, or return it flat.
        let d = d.dict("config") ?? d
        var out = LiveConfig()
        if let v = d.bool("enabled") { out.enabled = v }
        if let v = d.int("window_seconds") { out.windowSeconds = v }
        if let v = d.int("min_window_words") { out.minWindowWords = v }
        if let v = d.bool("monitor") { out.monitor = v }
        if let v = d.bool("fact_check") { out.factCheck = v }
        if let v = d.bool("translate") { out.translate = v }
        if let v = d.bool("memory_extraction") { out.memoryExtraction = v }
        if let v = d.bool("artifacts") { out.artifacts = v }
        if let v = d.string("reply_mode"), !v.isEmpty { out.replyMode = v }
        if let v = d.string("primary_language"), !v.isEmpty { out.primaryLanguage = v }
        if let v = d.string("embed_model") { out.embedModel = v }
        if let v = d.double("session_rollover_fraction") { out.sessionRolloverFraction = v }
        if let v = d.int("session_rollover_tokens") { out.sessionRolloverTokens = v }
        if let v = d.int("fact_check_tokens") { out.factCheckTokens = v }
        return out
    }

    /// Every key, always — see the type comment.
    var payload: [String: Any] {
        ["enabled": enabled,
         "window_seconds": windowSeconds,
         "min_window_words": minWindowWords,
         "monitor": monitor,
         "fact_check": factCheck,
         "translate": translate,
         "memory_extraction": memoryExtraction,
         "artifacts": artifacts,
         "reply_mode": replyMode,
         "primary_language": primaryLanguage,
         "embed_model": embedModel,
         "session_rollover_fraction": sessionRolloverFraction,
         "session_rollover_tokens": sessionRolloverTokens,
         "fact_check_tokens": factCheckTokens]
    }

    /// How the rollover point reads in a sentence.
    var rolloverText: String {
        sessionRolloverTokens > 0
            ? "\(sessionRolloverTokens) tokens"
            : "\(Int((sessionRolloverFraction * 100).rounded()))% of the model's context"
    }

    var spokenReplies: Bool { replyMode.lowercased() == "spoken" }
}

// MARK: - Sessions

/// One Live conversation, from `GET /api/live/sessions` (a row of
/// `live_session`).
struct LiveSessionSummary: Equatable, Sendable, Identifiable {
    var id = ""
    var title = ""
    var startedAt: Double = 0
    var endedAt: Double?
    var sourceLabel = ""
    var chatSessionID = ""
    var lastSeq = 0
    /// `recording` | `ended`.
    var state = "ended"

    var isRecording: Bool { state.lowercased() == "recording" && endedAt == nil }

    /// Never blank: an untitled conversation still has to be pickable.
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled conversation" : trimmed
    }

    /// "12 Sep, 14:02 · 48 lines".
    var subtitle: String {
        var parts: [String] = []
        if startedAt > 0 {
            let formatter = DateFormatter()
            formatter.dateFormat = "d MMM, HH:mm"
            parts.append(formatter.string(from: Date(timeIntervalSince1970: startedAt)))
        }
        parts.append(lastSeq == 1 ? "1 line" : "\(lastSeq) lines")
        if !sourceLabel.isEmpty { parts.append(sourceLabel) }
        return parts.joined(separator: " · ")
    }

    static func from(_ d: [String: Any]) -> LiveSessionSummary {
        LiveSessionSummary(
            id: d.string("id") ?? d.string("live_session_id") ?? "",
            title: d.string("title") ?? "",
            startedAt: d.double("started_at") ?? 0,
            endedAt: d.double("ended_at"),
            sourceLabel: d.string("source_label") ?? "",
            chatSessionID: d.string("chat_session_id") ?? "",
            lastSeq: d.int("last_seq") ?? 0,
            state: d.string("state") ?? "ended")
    }
}

// MARK: - Speakers

/// One voice, from `GET /api/live/speakers`.
struct LiveSpeaker: Equatable, Sendable, Identifiable {
    var id = ""
    /// `me` | `other`.
    var kind = "other"
    var name = ""
    var segmentCount = 0
    var speechMs = 0
    var audioBytes = 0
    var lastHeardAt = ""
    /// A few utterances so the user can tell whose voice this is before naming it.
    var samples: [String] = []

    var displayName: String { LiveFormat.speakerLabel(id: id, name: name.isEmpty ? nil : name) }

    static func from(_ d: [String: Any]) -> LiveSpeaker {
        LiveSpeaker(id: d.string("id") ?? d.string("speaker_id") ?? "",
                    kind: d.string("kind") ?? "other",
                    name: d.string("name") ?? "",
                    segmentCount: d.int("segment_count") ?? 0,
                    speechMs: d.int("speech_ms") ?? 0,
                    audioBytes: d.int("audio_bytes") ?? 0,
                    lastHeardAt: d.string("last_heard_at") ?? "",
                    samples: samples(from: d["samples"]))
    }

    /// Samples arrive either as plain strings or as rows with a `text` field,
    /// depending on whether the server joined the transcript. Both are read.
    private static func samples(from raw: Any?) -> [String] {
        guard let list = raw as? [Any] else { return [] }
        return list.compactMap { item in
            if let s = item as? String { return s.isEmpty ? nil : s }
            if let d = item as? [String: Any] { return d.string("text") }
            return nil
        }
    }
}

// MARK: - Storage

/// One line in the storage panel.
struct LiveStorageRow: Equatable, Sendable, Identifiable {
    var id = ""
    var label = ""
    var bytes = 0
    /// True for per-speaker rows: a chunk holds several people, so bytes are
    /// apportioned by speech time and can only ever be approximate (design §3.1).
    var approximate = false
    var detail: String?
}

/// `GET /api/live/storage`.
struct LiveStorage: Equatable, Sendable {
    var totalBytes = 0
    /// The server's own explanation of the numbers. Rendered VERBATIM — it is the
    /// server that knows how it apportioned bytes, and paraphrasing it here would
    /// be this client inventing an accounting claim.
    var note = ""
    var sessions: [LiveStorageRow] = []
    var days: [LiveStorageRow] = []
    var speakers: [LiveStorageRow] = []

    /// Both spellings of every list are read.
    ///
    /// The contract says `sessions` / `days` / `speakers`; `live_store.storage_summary`
    /// returns `per_session` / `per_day` / `per_speaker_approx`. Reading only the
    /// contract's names left this screen showing a total with NO rows under it — and
    /// silently, because an empty list and an absent one look the same. The id keys
    /// differ the same way (`live_session_id`, `day`), and the id is what a delete is
    /// addressed by, so getting it from the wrong key would mean a delete button that
    /// sends a title to an endpoint expecting a hex id.
    static func from(_ d: [String: Any]) -> LiveStorage {
        var out = LiveStorage()
        out.totalBytes = d.int("total_bytes") ?? d.int("total") ?? 0
        out.note = d.string("note") ?? ""
        out.sessions = rows(either(d, "sessions", "per_session"),
                            labelKeys: ["title", "label", "id"],
                            detailKeys: ["source_label", "day"],
                            idKeys: ["id", "live_session_id"])
        out.days = rows(either(d, "days", "per_day"),
                        labelKeys: ["day", "date", "label"], detailKeys: [],
                        idKeys: ["id", "day", "date"])
        out.speakers = rows(either(d, "speakers", "per_speaker_approx"),
                            labelKeys: ["name", "label", "id"],
                            detailKeys: ["kind"],
                            idKeys: ["id", "speaker_id"],
                            approximate: true)
        return out
    }

    private static func either(_ d: [String: Any], _ first: String,
                               _ second: String) -> [[String: Any]] {
        let rows = d.list(first)
        return rows.isEmpty ? d.list(second) : rows
    }

    /// Sorted by size, biggest first — §3.1 asks for the panel that way, and it is
    /// the only order in which a storage screen answers "what is using the space".
    private static func rows(_ list: [[String: Any]],
                             labelKeys: [String],
                             detailKeys: [String],
                             idKeys: [String],
                             approximate: Bool = false) -> [LiveStorageRow] {
        list.map { d in
            let label = labelKeys.compactMap { key -> String? in
                guard let v = d.string(key), !v.isEmpty else { return nil }
                return v
            }.first ?? "(untitled)"
            let detail = detailKeys.compactMap { d.string($0) }.first { !$0.isEmpty }
            // The label is the LAST resort for an id, not the first: it is a title a
            // user typed and no delete endpoint accepts one.
            let id = idKeys.compactMap { key -> String? in
                guard let v = d.string(key), !v.isEmpty else { return nil }
                return v
            }.first ?? label
            return LiveStorageRow(id: id,
                                  label: label,
                                  bytes: d.int("bytes") ?? d.int("audio_bytes")
                                      ?? d.int("approx_bytes") ?? 0,
                                  approximate: approximate && (d.bool("exact") != true),
                                  detail: detail)
        }
        .sorted { $0.bytes > $1.bytes }
    }
}

/// What a delete takes with it.
enum LiveDeleteKind: String, Equatable, Sendable {
    /// A whole live session: its segments and its chunks. Exact.
    case session
    /// Every session recorded on one LOCAL calendar day, `YYYY-MM-DD` — the id the
    /// storage panel's day rows already carry. The server deletes each session in
    /// turn, so it is exact in the same way `session` is; what it is not is
    /// reversible.
    case day
    /// Forget a voice: the voiceprint and that speaker's transcript rows. Audio
    /// stays, so other people's recordings are untouched.
    case speakerForget = "speaker_forget"
    /// Every recording this voice appears in — whole CHUNKS, which takes other
    /// speakers' audio with them. The dialog has to say so.
    case speakerAudio = "speaker_audio"
}

// MARK: - Client

/// `/api/live/*`. Dictionary-in, tolerant-`from(_:)`-out, matching the house style
/// in `VoiceAPI` and `DevicesModels` — and doubly appropriate here because the
/// server half is being built in parallel.
struct LiveAPI: Sendable {
    let api: JarvisAPI
    /// Borrowed purely for `socketURL(path:)`, so the live socket's URL is derived
    /// by exactly the same code as the voice socket's.
    private let voice: VoiceAPI

    init(api: JarvisAPI = .shared) {
        self.api = api
        self.voice = VoiceAPI(api: api)
    }

    /// `ws(s)://host/api/live/ws`.
    func socketURL() throws -> URL { try voice.socketURL(path: "/api/live/ws") }

    var headers: [String: String] { api.credentials.headers }

    // MARK: Session

    /// Returns the ids the server minted. A live session also creates its paired
    /// chat session (design §4), which is why `chat_session_id` comes back.
    func startSession(deviceID: String, sourceLabel: String, title: String)
        async throws -> (liveSessionID: String, chatSessionID: String) {
        let body: [String: Any] = ["device_id": deviceID,
                                   "source_label": sourceLabel,
                                   "title": title]
        let obj = try await api.post("/api/live/session/start", json: body).object()
        return (obj.string("live_session_id") ?? obj.string("id") ?? "",
                obj.string("chat_session_id") ?? "")
    }

    func endSession(liveSessionID: String) async throws {
        _ = try await api.post("/api/live/session/end", json: ["live_session_id": liveSessionID])
    }

    /// Replay after a gap. `afterSeq` is a cursor, not a page number.
    ///
    /// Notes come back too, and they matter: a verdict, a monitor note and the
    /// wrap-up only ever existed as frames on this device, so closing the app —
    /// or a stream drop long enough to miss one — lost them from the screen
    /// while the paired chat kept them forever. The server stores every one and
    /// stamps it with the row it belongs under.
    func transcript(liveSessionID: String, afterSeq: Int) async throws -> LiveTranscriptPage {
        let obj = try await api.get("/api/live/transcript",
                                    query: ["live_session_id": liveSessionID,
                                            "after_seq": String(afterSeq)]).object()
        let rows = obj.list("segments").isEmpty ? obj.list("rows") : obj.list("segments")
        return LiveTranscriptPage(
            segments: rows.map(LiveServerFrame.segment(from:)),
            notes: obj.list("insights").map(LiveServerFrame.storedNote(from:)))
    }

    // MARK: Speakers

    func speakers() async throws -> [LiveSpeaker] {
        let obj = try await api.get("/api/live/speakers").object()
        return obj.list("speakers").map(LiveSpeaker.from)
    }

    func rename(speakerID: String, name: String) async throws {
        _ = try await api.post("/api/live/speaker/rename",
                               json: ["speaker_id": speakerID, "name": name])
    }

    /// Fold one voice into another: they were the same person all along.
    ///
    /// `fromID` stops existing; `intoID` survives and inherits its rows, its
    /// embeddings and — when the survivor has no name of its own — its name. The
    /// server relabels every past segment and publishes a `speaker` frame with
    /// `op: "merge"`, which every client applies retroactively, so this is a
    /// rewrite of history and not a note about the future.
    func merge(fromID: String, intoID: String) async throws {
        _ = try await api.post("/api/live/speaker/merge",
                               json: ["from_id": fromID, "into_id": intoID])
    }

    // MARK: Storage

    func storage() async throws -> LiveStorage {
        LiveStorage.from(try await api.get("/api/live/storage").object())
    }

    @discardableResult
    func delete(kind: LiveDeleteKind, id: String) async throws -> LiveDeleteOutcome {
        let body = try await api.post("/api/live/delete",
                                      json: ["kind": kind.rawValue, "id": id])
        // A delete that worked but answered something unparseable is still a
        // delete: the rows are gone either way, so an undecodable body means
        // "nothing more to report", not a thrown error over the deletion.
        return LiveDeleteOutcome.from((try? body.object()) ?? [:])
    }

    // MARK: Config

    func config() async throws -> LiveConfig {
        LiveConfig.from(try await api.get("/api/live/config").object())
    }

    /// PUT per the contract, falling back to POST on a 404/405.
    ///
    /// Not defensiveness for its own sake: this app's server has historically not
    /// routed PUT on some endpoints, and the failure mode without the fallback is a
    /// settings sheet whose every toggle silently does nothing.
    func saveConfig(_ config: LiveConfig) async throws {
        do {
            _ = try await api.put("/api/live/config", json: config.payload)
        } catch APIError.http(let status, _) where status == 404 || status == 405 {
            JcLog.voice.notice("live config: PUT not routed (\(status, privacy: .public)); using POST")
            _ = try await api.post("/api/live/config", json: config.payload)
        }
    }

    // MARK: Watchers on demand

    /// Check the recent conversation.
    ///
    /// No `seq`: the server reads a window of the conversation (bounded by
    /// `live.fact_check_tokens`) rather than one utterance. A `seq` is what the
    /// old per-line check sent, and per-line checking is gone — it was
    /// meaningless on a line like "Yo, one, two, three, hello".
    func factCheckConversation(liveSessionID: String) async throws {
        _ = try await api.post("/api/live/factcheck",
                               json: ["live_session_id": liveSessionID])
    }

    // MARK: Sessions

    /// Past and current Live conversations, newest first.
    func sessions() async throws -> [LiveSessionSummary] {
        let obj = try await api.get("/api/live/sessions").object()
        return obj.list("sessions").map(LiveSessionSummary.from)
    }

    /// Store a translation this device produced.
    ///
    /// The phone translates on-device for speed, and the result has to outlive
    /// the app: without this it would vanish on close and never reach the web
    /// or any other device watching the same conversation.
    func saveTranslation(liveSessionID: String, seq: Int,
                         translation: String) async throws {
        _ = try await api.post("/api/live/translation",
                               json: ["live_session_id": liveSessionID,
                                      "seq": seq, "translation": translation])
    }

    func translate(liveSessionID: String, seq: Int, target: String) async throws {
        _ = try await api.post("/api/live/translate",
                               json: ["live_session_id": liveSessionID, "seq": seq, "target": target])
    }
}

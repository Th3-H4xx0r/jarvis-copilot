import Foundation

// The Live Jarvis wire protocol (v1), client side. Pure: no networking, no
// AVFoundation, no clock — so every framing and decoding rule is unit testable.
//
// The server half is being written in parallel against the same frozen contract,
// which is why decoding here is DEFENSIVE throughout: a missing field, an
// unexpected extra field, or a name the server spells differently must degrade to
// "we understood less of that frame" and never to a dropped connection. A live
// capture that silently stops because one frame had an unexpected shape would
// lose hours of conversation, which §8 of the design ranks as the worst outcome
// in the whole feature.

// MARK: - Client → server

/// What this device can do, sent once in `hello`.
///
/// `embed` is deliberately `"none"`: the on-device embedding model is a separate,
/// unstarted phase (design §10, phase 5). Declaring `on_device` here would earn
/// the edge lane and then feed the server no vectors, so identity would silently
/// stop working. Declaring less is exactly what the lane rule is designed for.
struct LiveCaps: Equatable, Sendable {
    /// `"stream"` — audio goes up as binary frames.
    var audio = "stream"
    /// `"stream"` — finished utterances go up as `seg` frames.
    var text = "stream"
    /// `"on_device"` when Apple's transcriber is ready here, `"none"` when the
    /// server has to do it (design §8: model not downloaded → server lane).
    var stt: String
    /// Always `"none"` until the embedding spike lands.
    var embed = "none"
    var embedModel = ""
    /// What the audio frames on this socket actually are: `"opus-packets"` (bare
    /// Opus packets, one per binary frame, which the server length-prefixes and
    /// stores as `opus-packets-len32@<rate>`) or `"pcm16"` (mono little-endian).
    ///
    /// The DEFAULT is `pcm16` on purpose. `LiveStore` sets this from the encoder it
    /// managed to build, and a default of Opus would mean any caller that forgot to
    /// pass one declared a codec the phone might not be able to produce — the one
    /// mistake here that corrupts stored recordings rather than just wasting space.
    var codec = "pcm16"
    /// The rate that goes WITH `codec`: 48000 for Opus, whatever the microphone
    /// produces for PCM16. Not necessarily the capture rate.
    var rate = 16000
    /// This device can play a spoken reply.
    var speak = true

    var payload: [String: Any] {
        ["audio": audio, "text": text, "stt": stt, "embed": embed,
         "embed_model": embedModel, "codec": codec, "rate": rate, "speak": speak]
    }
}

/// Where to pick up after a drop. §8 treats a dropped socket as the NORMAL path
/// — a real iPhone loses a long-lived stream about once a minute — so resume is
/// part of the handshake rather than an error path bolted on afterwards.
struct LiveResume: Equatable, Sendable {
    var liveSessionID: String
    var afterSeq: Int

    var payload: [String: Any] {
        ["live_session_id": liveSessionID, "after_seq": afterSeq]
    }
}

/// One message this client puts on the socket.
enum LiveClientMessage: Equatable, Sendable {
    case hello(deviceID: String, caps: LiveCaps, resume: LiveResume?)
    /// A finished utterance. `partial: false` — this client does not stream
    /// interim text, because a partial that arrives after its own final would
    /// overwrite the committed row.
    case segment(startMs: Int, endMs: Int, text: String, lang: String, localLabel: String)
    /// The capture source changed mid-session (AirPods connected, route lost), so
    /// the transcript can say where the audio came from from here on.
    case source(label: String)
    case bye

    var payload: [String: Any] {
        switch self {
        case .hello(let deviceID, let caps, let resume):
            var out: [String: Any] = ["t": "hello", "device_id": deviceID,
                                      "device_kind": "ios", "caps": caps.payload]
            if let resume { out["resume"] = resume.payload }
            return out
        case .segment(let startMs, let endMs, let text, let lang, let label):
            return ["t": "seg", "partial": false,
                    "ts_start_ms": startMs, "ts_end_ms": endMs,
                    "text": text, "lang": lang, "local_label": label]
        case .source(let label):
            return ["t": "source", "source_label": label]
        case .bye:
            return ["t": "bye"]
        }
    }

    /// `.sortedKeys` so a test can compare the encoded string, and so a diagnostic
    /// line is stable between runs.
    func encoded() -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

// MARK: - Binary audio framing

/// `[4B big-endian seq][8B big-endian ts_ms][payload]`.
///
/// Big-endian, and a FIXED header rather than a second channel, because the
/// header's whole job is to keep audio timing correct across reordering and gaps
/// (design §2.2). Little-endian would have been the natural choice on both ends
/// and is exactly why the contract pins the byte order.
enum LiveAudioFrame {
    static let headerBytes = 12

    static func encode(seq: Int, tsMs: Int, payload: Data) -> Data {
        var out = Data(capacity: headerBytes + payload.count)
        // Truncated to the wire width rather than clamped: seq is a UInt32 that
        // wraps, and a session long enough to wrap it (4 billion frames) has
        // bigger problems than one ambiguous cursor.
        let seq32 = UInt32(truncatingIfNeeded: seq)
        let ts64 = UInt64(truncatingIfNeeded: max(tsMs, 0))
        for shift in stride(from: 24, through: 0, by: -8) {
            out.append(UInt8(truncatingIfNeeded: seq32 >> UInt32(shift)))
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            out.append(UInt8(truncatingIfNeeded: ts64 >> UInt64(shift)))
        }
        out.append(payload)
        return out
    }

    /// Reads a frame back. Used by the tests and by the spool's replay, which has
    /// to know a record's `seq` to report progress without re-parsing JSON.
    static func decode(_ data: Data) -> (seq: Int, tsMs: Int, payload: Data)? {
        guard data.count >= headerBytes else { return nil }
        // `Data` sliced out of a file does not start at index 0, so every read is
        // relative to `startIndex`. Indexing from 0 here crashed on replayed
        // spool records while working fine on freshly built ones.
        let base = data.startIndex
        var seq: UInt32 = 0
        for offset in 0..<4 { seq = (seq << 8) | UInt32(data[base + offset]) }
        var ts: UInt64 = 0
        for offset in 4..<12 { ts = (ts << 8) | UInt64(data[base + offset]) }
        return (Int(seq), Int(ts), data.subdata(in: (base + headerBytes)..<data.endIndex))
    }
}

// MARK: - Server → client

/// The lane the server granted. `edge` means it trusts this device's own
/// transcription and embeddings; `server` means we just stream audio.
enum LiveLane: String, Equatable, Sendable {
    case edge
    case server

    /// An unknown lane name is read as `server`: the safe side, because a device
    /// that wrongly believes it is on the edge lane stops sending the audio the
    /// server would need to do the work itself.
    static func parse(_ raw: String?) -> LiveLane {
        LiveLane(rawValue: (raw ?? "").lowercased()) ?? .server
    }
}

struct LiveReady: Equatable, Sendable {
    var liveSessionID = ""
    var chatSessionID = ""
    /// The server's cursor. Resume sends `after_seq` = this.
    var seq = 0
    var lane = LiveLane.server
    var serverSTT = false
    var serverEmbed = false
    var serverEmbedModel = ""
}

/// How sure the server is about who spoke. `provisional` rows may be relabelled
/// later; `confirmed` ones are settled.
enum LiveLabelState: String, Equatable, Sendable {
    case provisional
    case confirmed

    static func parse(_ raw: String?) -> LiveLabelState {
        LiveLabelState(rawValue: (raw ?? "").lowercased()) ?? .provisional
    }
}

/// One canonical transcript row.
struct LiveSegment: Equatable, Sendable, Identifiable {
    var seq = 0
    var startMs = 0
    var endMs = 0
    /// Nil until the server has resolved a voice.
    var speakerID: String?
    /// The server's display name when it sent one. The UI falls back to
    /// "Speaker N" derived from `speakerID`, so a row is never blank.
    var speakerName: String?
    var speakerConf: Double?
    var labelState = LiveLabelState.provisional
    var text = ""
    var lang = ""
    var translation: String?

    var id: Int { seq }
}

/// `rename` gives a voice a name; `confirm` settles a provisional label; `merge`
/// says two ids were the same person all along and RETROACTIVELY relabels rows
/// already on screen (design §5.2).
enum LiveSpeakerOp: String, Equatable, Sendable {
    case rename
    case merge
    case confirm
}

struct LiveSpeakerEvent: Equatable, Sendable {
    var op = LiveSpeakerOp.rename
    /// The surviving / target speaker.
    var speakerID = ""
    var name: String?
    /// For `merge`: the ids folded INTO `speakerID`. Every row carrying one of
    /// these must be rewritten to `speakerID`.
    var mergedFrom: [String] = []
}

/// A watcher's output: a monitor note, a fact-check verdict, a translation.
struct LiveInsight: Equatable, Sendable, Identifiable {
    var seq = 0
    /// `monitor` | `factcheck` | `translate` — free text, because the set of
    /// watchers is meant to grow without a client change.
    var kind = "monitor"
    var text = ""
    /// The transcript row this is about, when it is about one.
    var refSeq: Int?

    var id: Int { seq }
}

/// Recording state and the numbers the status line shows.
struct LiveStateFrame: Equatable, Sendable {
    var recording: Bool?
    var paused: Bool?
    /// Total stored audio for this account, as the server accounts for it.
    var storageBytes: Int?
    /// A backpressure or capacity warning to show verbatim.
    var warning: String?
}

/// One decoded frame off the socket. `unknown` is kept rather than dropped: a
/// server that starts sending a new frame type must not look like a dead socket
/// in the diagnostics.
enum LiveServerFrame: Equatable, Sendable {
    case ready(LiveReady)
    case segment(LiveSegment)
    case speaker(LiveSpeakerEvent)
    case insight(LiveInsight)
    case speak(text: String)
    case state(LiveStateFrame)
    case error(String)
    case unknown(String)

    static func decode(text: String) -> LiveServerFrame? {
        guard let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return decode(object: object)
    }

    static func decode(object d: [String: Any]) -> LiveServerFrame {
        // `t` is the contract's discriminator; `type` is accepted too because the
        // rest of this app's sockets spell it that way and a mismatch would
        // otherwise read as an unknown frame.
        switch (d.string("t") ?? d.string("type") ?? "").lowercased() {
        case "ready":
            let caps = d.dict("server_caps") ?? [:]
            return .ready(LiveReady(
                liveSessionID: d.string("live_session_id") ?? "",
                chatSessionID: d.string("chat_session_id") ?? "",
                seq: d.int("seq") ?? 0,
                lane: LiveLane.parse(d.string("lane")),
                serverSTT: caps.bool("stt") ?? false,
                serverEmbed: caps.bool("embed") ?? false,
                serverEmbedModel: caps.string("embed_model") ?? ""))
        case "seg", "segment":
            return .segment(segment(from: d))
        case "speaker":
            return .speaker(speakerEvent(from: d))
        case "insight":
            return .insight(LiveInsight(
                seq: d.int("seq") ?? 0,
                kind: d.string("kind") ?? "monitor",
                text: d.string("text") ?? "",
                refSeq: d.int("ref_seq")))
        case "speak":
            return .speak(text: d.string("text") ?? "")
        case "state":
            return .state(LiveStateFrame(
                recording: d.bool("recording"),
                paused: d.bool("paused"),
                storageBytes: d.int("storage_bytes") ?? d.int("storage"),
                // NOT `nonEmpty`: present-and-empty is how the server WITHDRAWS a
                // warning, and absent is "unchanged". Collapsing the two left an amber
                // banner up for the rest of a session after its cause had gone.
                warning: d.string("warning")))
        case "error":
            return .error(d.string("error") ?? d.string("message") ?? "Live Jarvis reported an error")
        case let other:
            return .unknown(other.isEmpty ? "(no type)" : other)
        }
    }

    /// Shared by the socket and by `GET /api/live/transcript`, which returns rows
    /// in the same shape — one decoder so a field the server renames cannot be
    /// read correctly live and wrongly on replay.
    static func segment(from d: [String: Any]) -> LiveSegment {
        LiveSegment(
            seq: d.int("seq") ?? 0,
            startMs: d.int("ts_start_ms") ?? 0,
            endMs: d.int("ts_end_ms") ?? 0,
            speakerID: nonEmpty(d.string("speaker_id")),
            speakerName: nonEmpty(d.string("speaker_name") ?? d.string("name")),
            speakerConf: d.double("speaker_conf"),
            labelState: LiveLabelState.parse(d.string("label_state")),
            text: d.string("text") ?? "",
            lang: d.string("lang") ?? "",
            translation: nonEmpty(d.string("translation")))
    }

    private static func speakerEvent(from d: [String: Any]) -> LiveSpeakerEvent {
        // The target is `speaker_id`, or `into` on a merge. Both spellings are
        // read for both ops so a server that only sends one still works.
        let target = nonEmpty(d.string("speaker_id")) ?? nonEmpty(d.string("into")) ?? ""
        var merged: [String] = []
        if let list = d["from"] as? [Any] {
            merged = list.compactMap { $0 as? String }.filter { !$0.isEmpty }
        } else if let one = nonEmpty(d.string("from")) {
            merged = [one]
        }
        // `ids` minus the survivor is the other way a merge can be expressed.
        if merged.isEmpty, let list = d["ids"] as? [Any] {
            merged = list.compactMap { $0 as? String }.filter { !$0.isEmpty && $0 != target }
        }
        return LiveSpeakerEvent(op: LiveSpeakerOp(rawValue: (d.string("op") ?? "").lowercased()) ?? .rename,
                                speakerID: target,
                                name: nonEmpty(d.string("name")),
                                mergedFrom: merged)
    }

    /// An empty string from the server means "not set". Keeping it would show an
    /// empty speaker chip or an empty translation line under every row.
    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}

// MARK: - Display helpers

enum LiveFormat {
    /// "Speaker 3" from a stable id, so an unnamed voice still reads as a person
    /// and keeps the SAME number for the whole session.
    ///
    /// The number comes from the id's own digits when it has any, and otherwise
    /// from a hash, because the alternative — numbering by order of appearance —
    /// renumbers everyone the moment a merge lands.
    static func speakerLabel(id: String?, name: String?, fallbackIndex: Int? = nil) -> String {
        if let name, !name.isEmpty { return name }
        guard let id, !id.isEmpty else {
            return fallbackIndex.map { "Speaker \($0)" } ?? "Unknown speaker"
        }
        let digits = id.filter(\.isNumber)
        if !digits.isEmpty, let n = Int(digits.suffix(4)) { return "Speaker \(n)" }
        return "Speaker \(abs(id.hashValue) % 99 + 1)"
    }

    /// `mm:ss` (or `h:mm:ss`) from the start of the recording — a wall clock would
    /// be wrong for a session replayed from the spool hours later.
    static func stamp(ms: Int) -> String {
        let total = max(ms, 0) / 1000
        let hours = total / 3600, minutes = (total % 3600) / 60, seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    /// Bytes as a person reads them. Used for the storage screen and the status
    /// line, so both round the same way.
    static func bytes(_ count: Int) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(max(count, 0))
        var unit = 0
        while value >= 1024, unit + 1 < units.count { value /= 1024; unit += 1 }
        if unit == 0 { return "\(Int(value)) B" }
        // Formatted without `%@`: bridging a Swift String through `String(format:)`
        // relies on NSString interop, and concatenation says the same thing.
        let rounded = value >= 100 ? String(format: "%.0f", value) : String(format: "%.1f", value)
        return rounded + " " + units[unit]
    }
}

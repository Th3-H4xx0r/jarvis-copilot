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
    /// `"on_device"` when this phone makes voiceprints the server can compare
    /// with its own (`LiveVoiceprint`), with `embedModel` naming the checkpoint;
    /// the server trusts them only when that name matches its own.
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
    /// `voiceprint` is this phone's own embedding of the utterance, when it makes
    /// them; the server then matches it instead of re-reading the audio.
    /// `translatesHere` tells the server this phone translates the line itself,
    /// so it does not translate it a second time.
    case segment(startMs: Int, endMs: Int, text: String, lang: String, localLabel: String,
                 voiceprint: [Float]? = nil, translatesHere: Bool = false)
    /// The capture source changed mid-session (AirPods connected, route lost), so
    /// the transcript can say where the audio came from from here on.
    case source(label: String)
    case bye

    var payload: [String: Any] {
        switch self {
        case .hello(let deviceID, let caps, let resume):
            var out: [String: Any] = ["t": "hello", "device_id": deviceID,
                                      "device_kind": LiveHello.deviceKind, "caps": caps.payload]
            if let resume { out["resume"] = resume.payload }
            return out
        case .segment(let startMs, let endMs, let text, let lang, let label, let voiceprint,
                      let translatesHere):
            var out: [String: Any] = ["t": "seg", "partial": false,
                                      "ts_start_ms": startMs, "ts_end_ms": endMs,
                                      "text": text, "lang": lang, "local_label": label]
            // Five decimals: ~2 KB a line instead of ~5, and the server
            // renormalises, so the rounding cannot drift the scale.
            if let voiceprint {
                out["emb"] = voiceprint.map { (Double($0) * 1e5).rounded() / 1e5 }
            }
            if translatesHere { out["translate"] = "device" }
            return out
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
    /// The server speech engine hearing this device (Soniox, …). Empty unless the
    /// lane is the server's AND an engine there actually transcribes.
    var engine = ""
}

/// Words a server speech engine is still hearing — replaced as they grow, and by
/// the finished `seg` when the line ends.
struct LivePartial: Equatable, Sendable {
    var deviceID = ""
    var text = ""
    var startMs = 0
    var speaker = ""
    var lang = ""
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
    /// A LOCAL row identity, assigned by `LiveTranscript` on insert and never
    /// read off the wire.
    ///
    /// `seq` cannot be the identity: one monitor window produces SEVERAL notes
    /// and the server stamps every one of them with the same `seq` (the last
    /// segment of the window). Keying rows on `seq` meant each note replaced
    /// the one before it, so a window that had three things to say showed one —
    /// silently, which is why it was not obvious the notes were arriving at all.
    var localID = 0

    var id: Int { localID }

    /// What makes two insights the SAME insight rather than two. Used to absorb
    /// a re-delivery (a resume replay) without turning it into a second card.
    /// A translation of one line (`translate` from the watcher, `translation`
    /// from a device), which belongs under that line rather than as a card.
    var isTranslation: Bool { kind.lowercased().hasPrefix("translat") }

    func isSameNote(as other: LiveInsight) -> Bool {
        seq == other.seq && kind == other.kind && text == other.text
    }

    /// A fact-check verdict. Both spellings, because `run_fact_check` publishes
    /// `fact_check` while the contract and the config key say `factcheck`.
    static func isFactCheck(kind: String) -> Bool {
        ["factcheck", "fact_check"].contains(kind.lowercased())
    }
}

/// What a Live delete actually did — including what it did NOT do.
///
/// The server works out which remembered facts a deletion owes, which of them
/// are only STAGED for approval (so still in MEMORY.md), and which could not be
/// tied to the voice being forgotten. A fact lives in every future agent's
/// system prompt, so a delete that says "done" while one survives is the kind
/// of quiet over-promise worth a sentence on screen.
struct LiveDeleteOutcome: Sendable {
    /// False when the server says part of what it promised did not happen.
    var ok = true
    var retracted = 0
    var staged = 0
    var unattributable = 0
    var failure = ""
    var note = ""

    static func from(_ d: [String: Any]) -> LiveDeleteOutcome {
        LiveDeleteOutcome(
            ok: d.bool("ok") ?? true,
            retracted: d.int("facts_retracted") ?? 0,
            staged: d.int("facts_retraction_staged") ?? 0,
            unattributable: d.int("facts_unattributable") ?? 0,
            failure: d.string("facts_retraction_failed") ?? "",
            note: d.string("facts_note") ?? d.string("warning") ?? "")
    }

    /// One sentence about what the delete left behind, or nil when it left
    /// nothing — silence is only correct when there is nothing to say.
    var shortfall: String? {
        var parts: [String] = []
        if staged > 0 {
            parts.append(staged == 1
                ? "1 remembered fact is still in memory until you approve its removal"
                : "\(staged) remembered facts are still in memory until you approve their removal")
        }
        if unattributable > 0 {
            parts.append(unattributable == 1
                ? "1 could not be tied to this voice and was kept"
                : "\(unattributable) could not be tied to this voice and were kept")
        }
        if !failure.isEmpty { parts.append("memory was not updated: \(failure)") }
        if !note.isEmpty { parts.append(note) }
        if parts.isEmpty && !ok { parts.append("part of the delete did not finish") }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }
}

/// One page of `/api/live/transcript`: the utterances, and the notes about them.
struct LiveTranscriptPage: Sendable {
    var segments: [LiveSegment] = []
    /// Already-decoded frames — `insight`, `factCheck` or `wrapUp` — so the
    /// caller applies them exactly as it applies a live one.
    var notes: [LiveServerFrame] = []
}

/// What came back from a fact-check of the recent conversation.
///
/// A conversation-level result, not a per-row one: checking a single utterance
/// was meaningless on lines like "Yo, one, two, three, hello", so the check now
/// reads a window of the conversation and its verdict belongs to the
/// conversation.
struct LiveFactCheckResult: Equatable, Sendable {
    /// The prose to show. Already human — never a provider's error string.
    var text = ""
    /// "true" / "false" / "mixed" / "unverified", when the server graded it.
    var verdict = ""
    var sources: [String] = []
    /// The check did NOT complete. A failure must never present as a successful
    /// check, so this drives a different card and a different word.
    var failed = false

    /// The check is RUNNING, and this is the card standing in for its answer.
    ///
    /// A local state, never decoded: the server has nothing to say yet. It exists
    /// because the request is a whole agent turn with web tools, and for those
    /// several seconds the only feedback used to be a spinner on a small tile at
    /// the bottom of the screen. The card appears on tap, where the verdict will
    /// land, and becomes the verdict in place.
    var pending = false

    /// The transcript row whose claim was judged, when the server named one.
    ///
    /// Nil when the model's quoted claim did not match any one row well enough —
    /// a verdict about a whole window genuinely belongs to no single line, and
    /// guessing one would put the card against a sentence it is not about.
    var anchorSeq: Int?

    var isEmpty: Bool { !pending && text.isEmpty && verdict.isEmpty && sources.isEmpty }

    /// Verdicts that mean "this claim is not true", and nothing else.
    ///
    /// NOT a closed set on the wire: the server's prompt asks for
    /// `"true" | "false" | "misleading" | "unverifiable"`, but the value is
    /// whatever the model wrote into its JSON, so this matches conservatively and
    /// exactly. "misleading", "mixed", "partly false" and "unverifiable" stay
    /// neutral — painting them red would tell the user something the check did
    /// not say, and a wrong red is worse than no red at all.
    static let refutedVerdicts: Set<String> = [
        "false", "incorrect", "untrue", "wrong", "debunked", "refuted", "disproven",
    ]

    /// Whether the card should read as a refutation.
    ///
    /// A FAILED check is never one. "We couldn't check" and "this is false" are
    /// different states, and conflating them would be worse than having no colour.
    var isRefuted: Bool {
        guard !failed, !pending else { return false }
        return Self.refutedVerdicts.contains(
            verdict.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// Build a result from a `fact_check` insight, turning a machine error into
    /// a sentence.
    ///
    /// The server publishes whatever its model pass returned as the verdict
    /// text, and a FAILED pass returns the transport's own words — the user was
    /// shown `API call failed after 3 retries: HTTP 404: model "" not found`.
    /// That is developer text in a user surface, and worse, it was presented as
    /// though the claim had been checked.
    static func from(insightText text: String, verdict: String,
                     sources: [String], anchorSeq: Int? = nil) -> LiveFactCheckResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !LiveFailureText.looksLikeMachineError(trimmed) else {
            // A failed check is about nothing, so it carries no anchor: pinning
            // "we couldn't check this" under one line would read as a judgement
            // on that line.
            return LiveFactCheckResult(text: LiveFailureText.humanSentence,
                                       verdict: "", sources: [], failed: true)
        }
        return LiveFactCheckResult(text: trimmed, verdict: verdict,
                                   sources: sources, failed: false,
                                   anchorSeq: anchorSeq)
    }
}

/// Telling a verdict from a stack trace.
enum LiveFailureText {
    /// What the user reads when a check did not complete. Deliberately does not
    /// guess the cause — it states what happened and, above all, that nothing
    /// was verified.
    static let humanSentence =
        "Jarvis couldn't finish the check, so nothing has been verified. "
        + "Try again in a moment — the detail is in the app's logs."

    /// High-precision markers only. A false positive would hide a real verdict,
    /// so this matches the shapes only a machine produces, not merely
    /// pessimistic-sounding prose.
    private static let markers = [
        "api call failed",
        "after 3 retries",
        "traceback (most recent call last)",
        "connection refused",
        "connection reset",
        "read timed out",
        "no such model",
        "model \"\" not found",
    ]

    static func looksLikeMachineError(_ text: String) -> Bool {
        let lower = text.lowercased()
        if markers.contains(where: lower.contains) { return true }
        // "HTTP 404", "HTTP 500: …" — a status line, which prose does not carry.
        if let range = lower.range(of: "http "),
           lower[range.upperBound...].prefix(3).allSatisfy(\.isNumber) {
            return true
        }
        return false
    }
}

/// The end-of-session wrap-up: the summary, decisions and action items the
/// `artifacts` watcher writes when a session ends.
///
/// Its own type rather than another `LiveInsight` for two reasons. It arrives
/// with `seq: null` — decoded as 0, which would file it at the very TOP of the
/// conversation it summarises — and it carries STRUCTURE (three lists) that the
/// insight card's single `text` field would flatten back into markdown the
/// screen then has to render as prose.
struct LiveWrapUp: Equatable, Sendable {
    /// The last utterance this wrap-up covered, so it can sit at that point in
    /// the conversation instead of being pinned to the bottom for ever.
    ///
    /// A recording does not end when a wrap-up is written — the user stops and
    /// starts again, and everything said afterwards belongs BELOW the summary
    /// of what came before. Rendering it after every row meant new speech
    /// appeared above it and it slid down the screen for the rest of the
    /// session.
    var afterSeq: Int?
    var summary = ""
    var decisions: [String] = []
    var actionItems: [String] = []
    /// The server's own rendered markdown, which is what goes into the paired
    /// chat. Kept as the fallback for a server that sends only `text`.
    var text = ""

    var isEmpty: Bool {
        summary.isEmpty && decisions.isEmpty && actionItems.isEmpty && text.isEmpty
    }

    /// `kind` values the artifacts watcher uses. Matched case-insensitively.
    static func isWrapUp(kind: String) -> Bool {
        ["artifacts", "artifact", "wrapup", "wrap_up", "summary"].contains(kind.lowercased())
    }
}

/// Recording state and the numbers the status line shows.
struct LiveStateFrame: Equatable, Sendable {
    var recording: Bool?
    var paused: Bool?
    /// Total stored audio for this account, as the server accounts for it.
    var storageBytes: Int?
    /// A backpressure or capacity warning to show verbatim.
    var warning: String?
    /// The sentence that goes with a warning code (`speech_engine`, …), when the
    /// server sends one; shown instead of the code.
    var message: String? = nil
}

/// One decoded frame off the socket. `unknown` is kept rather than dropped: a
/// server that starts sending a new frame type must not look like a dead socket
/// in the diagnostics.
enum LiveServerFrame: Equatable, Sendable {
    case ready(LiveReady)
    case segment(LiveSegment)
    case speaker(LiveSpeakerEvent)
    case insight(LiveInsight)
    /// The end-of-session wrap-up. Arrives as an `insight` frame whose `kind`
    /// is `artifacts`, and is split out here because it belongs at the end of
    /// the transcript rather than at `seq` 0.
    case wrapUp(LiveWrapUp)
    /// A fact-check verdict. Also an `insight` frame; split out because the
    /// check now reads a window of the CONVERSATION, so its answer belongs at
    /// the end of the transcript rather than against one utterance.
    case factCheck(LiveFactCheckResult)
    case speak(text: String)
    case state(LiveStateFrame)
    case partial(LivePartial)
    case error(String)
    case unknown(String)

    static func decode(text: String) -> LiveServerFrame? {
        guard let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return decode(object: object)
    }

    /// One row of `/api/live/transcript`'s `insights`, as the frame it was when
    /// it was live.
    ///
    /// The stored row is the frame minus its `t` — the table has no column for
    /// a discriminator it never varies — so putting it back is all that stands
    /// between a saved note and the decoder that already knows every shape it
    /// can take. Anything else would be a second decoder to keep in step with
    /// this one.
    static func storedNote(from d: [String: Any]) -> LiveServerFrame {
        var frame = d
        frame["t"] = "insight"
        return decode(object: frame)
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
                serverEmbedModel: caps.string("embed_model") ?? "",
                engine: d.string("engine") ?? ""))
        case "partial":
            return .partial(LivePartial(
                deviceID: d.string("device_id") ?? "",
                text: d.string("text") ?? "",
                startMs: d.int("start_ms") ?? 0,
                speaker: d.string("speaker") ?? "",
                lang: d.string("lang") ?? ""))
        case "seg", "segment":
            return .segment(segment(from: d))
        case "speaker":
            return .speaker(speakerEvent(from: d))
        case "insight":
            let kind = d.string("kind") ?? "monitor"
            // The wrap-up rides the same frame type. Its `seq` is null on the
            // wire, so reading it as an ordinary insight put the summary of the
            // whole conversation ABOVE the conversation.
            if LiveWrapUp.isWrapUp(kind: kind) {
                return .wrapUp(LiveWrapUp(
                    // `seq_to` is the last row it read; the live frame carries
                    // it, and a stored one gets it from `_insight_frame`.
                    afterSeq: d.int("seq_to") ?? d.int("anchor_seq") ?? d.int("seq"),
                    summary: d.string("summary") ?? "",
                    decisions: stringList(d["decisions"]),
                    actionItems: stringList(d["action_items"] ?? d["actions"]),
                    text: d.string("text") ?? ""))
            }
            if LiveInsight.isFactCheck(kind: kind) {
                return .factCheck(LiveFactCheckResult.from(
                    insightText: d.string("text") ?? "",
                    verdict: d.string("verdict") ?? "",
                    sources: stringList(d["sources"]),
                    // `anchor_seq` ONLY. Absent or null means the verdict is
                    // about a window rather than a line, and the card closes the
                    // transcript instead of sitting under one.
                    //
                    // Deliberately NOT falling back to `seq`: on this frame `seq`
                    // is the last segment of the window the watcher read, which
                    // every fact-check carries, so reading it as an anchor would
                    // pin every verdict under whatever was said last — including
                    // the window-level ones the server explicitly declined to
                    // anchor.
                    anchorSeq: d.int("anchor_seq")))
            }
            return .insight(LiveInsight(
                seq: d.int("seq") ?? 0,
                kind: kind,
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
                warning: d.string("warning"),
                message: d.string("message")))
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

    /// A JSON array of strings, tolerantly: a single string is read as a
    /// one-element list, and blanks are dropped rather than rendered as empty
    /// bullets.
    private static func stringList(_ raw: Any?) -> [String] {
        if let list = raw as? [Any] {
            return list.compactMap { $0 as? String }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        if let one = raw as? String, !one.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [one.trimmingCharacters(in: .whitespacesAndNewlines)]
        }
        return []
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

enum LiveHello {
    #if os(iOS)
    static let deviceKind = "ios"
    #else
    static let deviceKind = "mac"
    #endif
}

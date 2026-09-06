import Foundation

/// A rolling, privacy-safe trace of the voice stack — the last
/// ``VoiceDiagnostics/capacity`` events, exposed as ``VoiceStore/diagnostics``
/// and mirrored to **stderr** in DEBUG builds so
/// `xcrun devicectl device process launch --console` shows a live turn without
/// attaching Console.app.
///
/// Why this exists: every failure in a voice turn is invisible from the phone.
/// `os.Logger` lines only show in Console.app, and by the time the user says
/// "voice is broken" the turn is gone. A ring buffer that the screen can show
/// turns "it didn't work" into "the socket closed after begin_turn".
///
/// **It must never carry content.** Transcripts, reply text and audio bytes stay
/// out; a line records the frame's *type* and *size* only. Everything here is a
/// pure function of its inputs so the formatting is unit-tested rather than
/// eyeballed in a log.
enum VoiceDiagnostics {

    /// Bounded so a long conversation can't grow without limit. 200 lines is
    /// roughly four full turns including every PCM-in/PCM-out frame.
    static let capacity = 200

    /// One line, timestamped. `HH:mm:ss.SSS` (not a full date): the reader is
    /// always looking at the last minute or two of a live session.
    static func stamp(_ line: String, at now: Date) -> String {
        "\(timeFormatter.string(from: now)) \(line)"
    }

    /// Trim `lines` to the ring size, dropping oldest-first.
    static func trimmed(_ lines: [String]) -> [String] {
        guard lines.count > capacity else { return lines }
        return Array(lines.suffix(capacity))
    }

    // MARK: - Frame formatting

    /// A client → server frame. Only shapes and sizes: `text` is reported as a
    /// character count because it is the user's own words.
    static func describe(sent message: VoiceClientMessage) -> String {
        switch message {
        case .beginTurn(let sampleRate, let sessionID, let model, let provider):
            return "ws→ begin_turn rate=\(sampleRate)"
                + " session=\(present(sessionID))"
                + " model=\(model ?? "-") provider=\(provider ?? "-")"
        case .endTurn(let text, _, let speechEndTs, let turnID):
            return "ws→ end_turn text=\(text.map { "\($0.count)ch" } ?? "-")"
                + " speech_end=\(speechEndTs != nil ? "y" : "n")"
                + " turn=\(turnID ?? "-")"
        case .interrupt:
            return "ws→ interrupt"
        }
    }

    /// A server → client frame.
    static func describe(received frame: VoiceServerFrame) -> String {
        switch frame {
        case .ready:
            return "ws← ready"
        case .transcript(let text):
            return "ws← transcript \(text.count)ch"
        case .assistantText(let text):
            return "ws← assistant_text \(text.count)ch"
        case .tool(let name, let status):
            return "ws← tool \(name) \(status)"
        case .audioMeta(let format, let sampleRate):
            return "ws← audio_meta \(format)@\(sampleRate)"
        case .audioEnd:
            return "ws← audio_end"
        case .endTurn(let reason):
            return "ws← end_turn reason=\(reason.isEmpty ? "-" : reason)"
        case .latency(let turnID, let spans):
            return "ws← latency turn=\(turnID) spans=\(spans.count)"
        case .escalationResult(let text):
            return "ws← escalation_result \(text.count)ch"
        case .audio(let data):
            return "ws← audio \(data.count)B"
        case .other(let type):
            // An unhandled type is exactly the thing worth seeing in a trace:
            // a server that grew a new frame we silently drop.
            return "ws← ?\(type.isEmpty ? "untyped" : type)"
        }
    }

    /// The outbound mic stream, summarised per burst rather than per frame —
    /// one line every ~40 ms would push everything else out of the ring.
    static func describe(micFrames count: Int, bytes: Int) -> String {
        "ws→ pcm \(count) frame(s) \(bytes)B"
    }

    /// The state-machine event, without its payload (an `endTurn` reason is
    /// fine, a `showError` message is already logged separately).
    static func name(of event: VoiceTurnEvent) -> String {
        switch event {
        case .startRequested: return "startRequested"
        case .connected: return "connected"
        case .endOfSpeech: return "endOfSpeech"
        case .serverOutput: return "serverOutput"
        case .playbackStarted: return "playbackStarted"
        case .playbackDrained: return "playbackDrained"
        case .resumeGraceElapsed: return "resumeGraceElapsed"
        case .bargeIn: return "bargeIn"
        case .interruptRequested: return "interruptRequested"
        case .turnEnded(let reason, let produced):
            return "turnEnded(reason=\(reason.isEmpty ? "-" : reason), reply=\(produced))"
        case .failed: return "failed"
        case .stopRequested: return "stopRequested"
        case .qualityStreamDone(let busy): return "qualityStreamDone(busy=\(busy))"
        }
    }

    // MARK: - stderr mirror

    /// DEBUG only. `fputs` to `stderr` rather than `print`, so the line survives
    /// stdout buffering and lands in `devicectl --console` in real time.
    static func mirror(_ line: String) {
        #if DEBUG
        fputs("[voice] \(line)\n", stderr)
        #endif
    }

    // MARK: - Private

    private static func present(_ value: String?) -> String {
        (value?.isEmpty ?? true) ? "n" : "y"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

// MARK: - Store wiring

extension VoiceStore {

    /// Record one event. Cheap enough to call from every frame handler; the mic
    /// stream is batched by ``noteMicFrame(bytes:)`` so it can't flood the ring.
    func note(_ line: String) {
        let stamped = VoiceDiagnostics.stamp(line, at: clock.now)
        diagnostics.append(stamped)
        diagnostics = VoiceDiagnostics.trimmed(diagnostics)
        VoiceDiagnostics.mirror(stamped)
    }

    /// Coalesce the outbound PCM stream into one line per `micLogBatch` frames.
    /// Logging each one would evict everything else from a 200-line ring inside
    /// a single utterance.
    func noteMicFrame(bytes: Int) {
        micFramesSent += 1
        micBytesSent += bytes
        guard micFramesSent % Self.micLogBatch == 0 else { return }
        note(VoiceDiagnostics.describe(micFrames: Self.micLogBatch, bytes: micBytesSent))
        micBytesSent = 0
    }
}

/// The Voice screen reads the trace through this (see `VoiceModelSelection.swift`),
/// so the sheet compiles whether or not the store has it yet.
extension VoiceStore: VoiceDiagnosticsProviding {}

/// "Try on server", likewise declared by the Voice UI and adopted here.
extension VoiceStore: VoiceServerRetrying {}

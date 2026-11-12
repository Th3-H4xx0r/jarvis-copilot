import Foundation

/// The GO3's AI-note wire ("FastSpeedNote", message type CONVERSATION_RECORD 12,
/// lens app 5), as the official INMO app drives it — measured from its own
/// traffic, see docs/glasses/go3-ai-notes.md. Like the official app, these carry
/// no VERSION field.
enum GlassesNoteWire {
    /// SWITCHAPP id of the notes app on the lens.
    static let module = 5
    /// AUDIO header type of the notes microphone stream.
    static let audioType: UInt64 = 3

    private static func note(_ payload: Data) -> Data { InmoCommand.envelope(type: 12, field: 15, payload: payload) }
    private static func online(_ content: Data) -> Data { note(InmoWireCodec.uint(1, 2) + InmoWireCodec.bytes(4, content)) }

    /// The four messages that start a note, in the official order: network state,
    /// "speech recognition connected" (1000), open the lens app, and the note's
    /// start time — which is also its id, and the prefix of every photo name.
    static func start(audioTimeMs: UInt64) -> [Data] {
        [InmoCommand.envelope(type: 17, field: 20, payload: InmoWireCodec.bytes(8, Data())),
         exception(1000),
         InmoCommand.openModule(module),
         online(InmoWireCodec.uint(1, 1) + InmoWireCodec.uint(4, audioTimeMs))]
    }
    static func exception(_ code: UInt64) -> Data {
        note(InmoWireCodec.uint(1, 4) + InmoWireCodec.bytes(6, InmoWireCodec.uint(1, code)))
    }
    /// The lens timer: whole seconds since the start, once a second.
    static func elapsed(seconds: Int) -> Data {
        note(InmoWireCodec.uint(1, 5) + InmoWireCodec.bytes(7, InmoWireCodec.uint(1, UInt64(max(0, seconds)))))
    }
    /// The sentence being spoken, re-sent whole as it grows; `final` on its last version.
    static func transcript(_ text: String, final: Bool) -> Data {
        note(InmoWireCodec.uint(1, 1) + InmoWireCodec.bytes(3, InmoWireCodec.string(1, text) + InmoWireCodec.uint(2, final ? 1 : 0)))
    }
    static func photoReceived() -> Data { online(InmoWireCodec.uint(5, 1)) }
    static func phonePhotoCount(_ count: Int) -> Data { online(InmoWireCodec.uint(6, UInt64(max(0, count)))) }
    /// STOP, then close the lens app.
    static func stop() -> [Data] { [note(InmoWireCodec.uint(2, 1)), InmoCommand.closeModule(module)] }

    enum Event: Equatable {
        /// The lens notes app opened / closed (the glasses also echo ours).
        case opened, closed
        /// The glasses asked to start, or to stop (STOP, 1-hour timeout, out of memory).
        case startRequested, stopRequested
        /// A shutter press on the glasses: a small JPEG preview, named
        /// "<note start ms>_<ms into the note>". The full-size file waits on the glasses.
        case photo(jpeg: Data, name: String)
        /// Opus packets of the speech stream (the first of the two interleaved streams).
        case audio([Data])
    }

    static func parse(type: Int, fields: [InmoWireField]) throws -> Event? {
        switch type {
        case 15:
            guard let app = try fields.firstField(18)?.nested(), app.firstField(1)?.varint == UInt64(module) else { return nil }
            return (app.firstField(2)?.varint ?? 0) == 1 ? .closed : .opened
        case 12:
            guard let note = try fields.firstField(15)?.nested() else { return nil }
            if let command = note.firstField(2)?.varint {
                switch command {
                case 0: return .startRequested
                case 1, 2, 3: return .stopRequested
                default: return nil
                }
            }
            if let content = try note.firstField(4)?.nested(), let jpeg = content.firstField(2)?.bytes, !jpeg.isEmpty {
                let name = content.firstField(3)?.bytes.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                return .photo(jpeg: jpeg, name: name)
            }
            return nil
        case 0:
            guard let audio = try fields.firstField(3)?.nested(),
                  let header = try audio.firstField(1)?.nested(),
                  header.firstField(4)?.varint == audioType else { return nil }
            let (data, lengths) = try InmoAIChannel.audioPayload(audio, audioType: audioType)
            var packets: [Data] = []
            var offset = 0
            for length in lengths where length > 0 {
                packets.append(data.subdata(in: offset ..< offset + length))
                offset += length
            }
            return .audio(packets)
        default:
            return nil
        }
    }

    /// Milliseconds into the note from a glasses photo name ("1790549761235_11995" → 11995).
    static func photoOffsetMs(_ name: String) -> Int? {
        guard let underscore = name.lastIndex(of: "_") else { return nil }
        let digits = name[name.index(after: underscore)...].prefix { $0.isNumber }
        return Int(digits)
    }
}

/// The new SageNote wire (firmware 3.0.x moved "AI Notes" here from the dead
/// CONVERSATION_RECORD/openModule(5) path). All values verified against SagenoteProto.java
/// and manager/SagenoteProbufProcessManager.java. On the lens this app is INMEET. The phone opens
/// it with STARTING_APPLICATION switchApp 15, waits briefly for the glasses to start,
/// and falls back to sending START_MEETING itself. `Message{msg_type(2): SAGENOTE(43),
/// sagenote(46): Sagenote{msg_type(1): SagenoteMessageType, command_id(2), session_id(3),
/// timestamp_ms(4), <payload>}}`, no version field, proto3 zero values omitted.
enum GlassesSageNoteWire {
    // SagenoteMessageType values: COMMAND=0, COMMAND_ACK=1, STATE=3, ASR=4, PANEL=8, MARKER=9.
    // Payload field numbers: command=10, command_ack=11, state=13, asr=14, panel=18, marker=19.
    // SagenoteCommandType: START_MEETING=0, STOP_MEETING=1, NOTIFY_STARTED=2, NOTIFY_STOPPED=3,
    //   PAUSE=4, RESUME=5. SagenoteCommandSource: PHONE=0, GLASSES=1, SYSTEM=2.
    private static func sagenote(_ body: Data) -> Data { InmoCommand.envelope(type: 43, field: 46, payload: body) }
    private static func envelope(msgType: Int, commandId: String, sessionId: String, nowMs: UInt64, payloadField: Int, _ payload: Data) -> Data {
        sagenote((msgType == 0 ? Data() : InmoWireCodec.uint(1, UInt64(msgType)))
            + (commandId.isEmpty ? Data() : InmoWireCodec.bytes(2, Data(commandId.utf8)))
            + (sessionId.isEmpty ? Data() : InmoWireCodec.bytes(3, Data(sessionId.utf8)))
            + InmoWireCodec.uint(4, nowMs)
            + InmoWireCodec.bytes(payloadField, payload))
    }

    /// Open / close INMEET (SageNote) on the lens. This is STARTING_APPLICATION, not the AI-assistant
    /// app-switch: the official app's sendSagenoteApplicationSwitch → switchApplication(SWITCHPP_SAGENOTE=15)
    /// = `Message{STARTING_APPLICATION(15), switchApp(18): {msgType: 15, openOrClose}}`, and the call
    /// capture shows the glasses open/close INMEET with exactly `15 18{1=15}` / `18{1=15 2=1}`.
    /// The AI_ASSISTANT aiSwitchApp path makes the lens say "update the app, feature not installed".
    static let module = 15
    static func open() -> Data { InmoCommand.openModule(module) }
    static func close() -> Data { InmoCommand.closeModule(module) }

    /// The meeting config the official app sends once INMEET opens (call capture, t=133.20):
    /// SagenoteConfig{changeMask(1)=255, sourceLanguage(2), targetLanguage(3), showOriginal(5)=1,
    /// autoCallRecording(7)=1, configRevision(8), realtimeEnabled(12)=1}, msg_type CONFIG(7) / field 17.
    static func config(sessionId: String, revision: Int, language: String, nowMs: UInt64,
                       commandId: String = UUID().uuidString) -> Data {
        let lang = Data(language.utf8)
        let body = InmoWireCodec.uint(1, 255) + InmoWireCodec.bytes(2, lang) + InmoWireCodec.bytes(3, lang)
            + InmoWireCodec.uint(5, 1) + InmoWireCodec.uint(7, 1) + InmoWireCodec.uint(8, UInt64(max(1, revision)))
            + InmoWireCodec.uint(12, 1)
        return envelope(msgType: 7, commandId: commandId, sessionId: sessionId, nowMs: nowMs, payloadField: 17, body)
    }

    /// The once-a-second meeting state that drives INMEET's timer (sendState; capture
    /// `13{1=1 2=1 3=1 4=secs}`): SagenoteState{mode(1)=MEETING, recordType(2)=MEETING,
    /// captureState(3)=ACTIVE, elapsedSeconds(4)}, msg_type STATE(3) / field 13.
    static func state(sessionId: String, elapsedSeconds: Int, nowMs: UInt64) -> Data {
        let body = InmoWireCodec.uint(1, 1) + InmoWireCodec.uint(2, 1) + InmoWireCodec.uint(3, 1)
            + (elapsedSeconds > 0 ? InmoWireCodec.uint(4, UInt64(elapsedSeconds)) : Data())
        return envelope(msgType: 3, commandId: "", sessionId: sessionId, nowMs: nowMs, payloadField: 13, body)
    }

    /// INMEET opened (true) or closed (false) on the lens, from a STARTING_APPLICATION echo.
    static func appState(type: Int, fields: [InmoWireField]) -> Bool? {
        guard type == 15, let app = try? fields.firstField(18)?.nested(), app.firstField(1)?.varint == UInt64(module) else { return nil }
        return (app.firstField(2)?.varint ?? 0) != 1
    }

    /// The phone-initiated START_MEETING the app sends as a fallback when the glasses don't
    /// auto-start after the app-switch (SagenoteProbufProcessManager line 3595). cmd and source
    /// are 0 (START_MEETING / SOURCE_PHONE) so proto3 omits them; only startTimestampMs(3) rides.
    static func startMeeting(commandId: String, sessionId: String, nowMs: UInt64) -> Data {
        envelope(msgType: 0, commandId: commandId, sessionId: sessionId, nowMs: nowMs,
                 payloadField: 10, InmoWireCodec.uint(3, nowMs))
    }
    /// STOP_MEETING (cmd=1, source=PHONE=0).
    static func stopMeeting(commandId: String, sessionId: String, nowMs: UInt64) -> Data {
        envelope(msgType: 0, commandId: commandId, sessionId: sessionId, nowMs: nowMs,
                 payloadField: 10, InmoWireCodec.uint(1, 1))
    }
    /// Acknowledge a glasses-initiated command: SagenoteCommandAck{cmd(1), ok(2), errorCode(3),
    /// sessionId(5)} (sendAck, line 3082). `cmd` echoes the command being acked.
    static func ack(commandId: String, cmd: Int, sessionId: String, ok: Bool, nowMs: UInt64) -> Data {
        let ackBody = (cmd == 0 ? Data() : InmoWireCodec.uint(1, UInt64(cmd)))
            + (ok ? InmoWireCodec.uint(2, 1) : Data())
            + (sessionId.isEmpty ? Data() : InmoWireCodec.bytes(5, Data(sessionId.utf8)))
        return envelope(msgType: 1, commandId: commandId, sessionId: sessionId, nowMs: nowMs,
                        payloadField: 11, ackBody)
    }

    /// AUDIO header type of the SageNote mic/call stream (verified from the call-recording
    /// capture: `Message{audio(3):{header(1):{sampleRate(1)=16000, channels(2)=1,
    /// bitrate(3)=256000, audioType(4)=13}, dataLength(3), opusData(4)}}}`). The old note path
    /// used audioType=3; SageNote is 13.
    static let audioType: UInt64 = 13
    /// Opus packets from a glasses SageNote audio frame (msg_type 0, audioType 13), for Jarvis's
    /// own ASR. Returns nil for any other audio stream.
    static func audioPackets(_ fields: [InmoWireField]) -> [Data]? {
        guard let audio = try? fields.firstField(3)?.nested(),
              let header = try? audio.firstField(1)?.nested(),
              header.firstField(4)?.varint == audioType,
              let (data, lengths) = try? InmoAIChannel.audioPayload(audio, audioType: audioType) else { return nil }
        var packets: [Data] = []; var offset = 0
        for length in lengths where length > 0 { packets.append(data.subdata(in: offset ..< offset + length)); offset += length }
        return packets
    }
    /// Push one transcript segment to the lens (verified subtype-4 from the capture):
    /// `sagenote{msg_type(1)=4, session_id(3), timestamp_ms(4), asr(14):{is_final(1), mode(2)=1,
    /// segment(3):{segment_id(1), source_text(2)=text}}}`. is_final 0 for a growing partial.
    static func asr(sessionId: String, segmentId: Int, text: String, isFinal: Bool, nowMs: UInt64) -> Data {
        let segment = InmoWireCodec.uint(1, UInt64(max(0, segmentId))) + InmoWireCodec.bytes(2, Data(text.utf8))
        let asr = (isFinal ? InmoWireCodec.uint(1, 1) : Data()) + InmoWireCodec.uint(2, 1) + InmoWireCodec.bytes(3, segment)
        return envelope(msgType: 4, commandId: "", sessionId: sessionId, nowMs: nowMs, payloadField: 14, asr)
    }

    /// Push a running markdown summary to the lens (verified subtype-6 from the call capture:
    /// `sagenote{msg_type(1)=6, session_id(3), timestamp_ms(4), summary(16):{body(1):{revision(1),
    /// summary(2)=markdown, is_final(5)}}}`). The markdown grows and is re-sent whole with an
    /// incrementing revision. Verified against SagenoteSummary.body(1)/SagenoteSummaryBody.
    static func summary(sessionId: String, revision: Int, markdown: String, isFinal: Bool, nowMs: UInt64) -> Data {
        let body = InmoWireCodec.uint(1, UInt64(max(0, revision))) + InmoWireCodec.bytes(2, Data(markdown.utf8)) + (isFinal ? InmoWireCodec.uint(5, 1) : Data())
        return envelope(msgType: 6, commandId: "", sessionId: sessionId, nowMs: nowMs, payloadField: 16, InmoWireCodec.bytes(1, body))
    }
    /// Mark the current moment (subtype 9 / marker(19)): SagenoteMarker{action(1)=ADD(0, omit),
    /// marker_id(2), session_id(3), offset_ms(5), created_ms(6)}. ADD=0 is the proto3 default.
    static func marker(sessionId: String, markerId: String, offsetMs: UInt64, nowMs: UInt64) -> Data {
        let marker = InmoWireCodec.bytes(2, Data(markerId.utf8)) + InmoWireCodec.bytes(3, Data(sessionId.utf8))
            + InmoWireCodec.uint(5, offsetMs) + InmoWireCodec.uint(6, nowMs)
        return envelope(msgType: 9, commandId: "", sessionId: sessionId, nowMs: nowMs, payloadField: 19, marker)
    }

    /// A glasses-originated SageNote message the phone must react to.
    enum Incoming: Equatable {
        /// The glasses started a session and want an ack (cmd, commandId, sessionId).
        case command(cmd: Int, commandId: String, sessionId: String)
    }
    /// SagenoteCommandType values that begin / end a meeting.
    static func isStart(_ cmd: Int) -> Bool { cmd == 0 || cmd == 2 }   // START_MEETING, NOTIFY_STARTED
    static func isStop(_ cmd: Int) -> Bool { cmd == 1 || cmd == 3 }    // STOP_MEETING, NOTIFY_STOPPED
    /// Parse an incoming SAGENOTE(43) message. Only the COMMAND path (which needs an ack) is
    /// handled; STATE/ASR/PANEL/MARKER display handling is TODO (see GlassesNoteRecorder).
    static func parse(type: Int, fields: [InmoWireField]) throws -> Incoming? {
        guard type == 43, let note = try fields.firstField(46)?.nested() else { return nil }
        let msgType = note.firstField(1)?.varint ?? 0   // 0 = SAGENOTE_COMMAND
        guard msgType == 0, let command = try note.firstField(10)?.nested() else { return nil }
        let commandId = note.firstField(2)?.bytes.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let sessionId = note.firstField(3)?.bytes.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return .command(cmd: Int(command.firstField(1)?.varint ?? 0), commandId: commandId, sessionId: sessionId)
    }
}

/// What the lens shows while recording: the sentence being spoken, re-sent whole
/// as it grows, then once more marked final when it ends — the official app's
/// rhythm. Feed it the whole transcript so far; it returns what to send.
struct GlassesNoteLens {
    struct Line: Equatable { let text: String; let final: Bool }
    /// Characters of the transcript already sent as final sentences.
    private(set) var committed = 0
    private var lastPartial = ""
    /// The lens is small: an unpunctuated run is cut into lines of about this size.
    static let maxLine = 120

    mutating func update(_ transcript: String) -> [Line] {
        let chars = Array(transcript)
        if committed > chars.count { committed = chars.count; lastPartial = "" }
        var lines: [Line] = []
        var start = committed
        var i = committed
        while i < chars.count {
            let isEnd = ".?!".contains(chars[i]) && i + 1 < chars.count && chars[i + 1].isWhitespace
            let tooLong = i - start >= Self.maxLine && chars[i].isWhitespace
            if isEnd || tooLong {
                let sentence = String(chars[start...i]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty { lines.append(Line(text: sentence, final: true)) }
                start = i + 1
                committed = start
                lastPartial = ""
            }
            i += 1
        }
        let current = String(chars[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty, current != lastPartial {
            lines.append(Line(text: current, final: false))
            lastPartial = current
        }
        return lines
    }

    /// Everything not yet sent as final, as one final line (at the end of a note).
    mutating func finish(_ transcript: String) -> [Line] {
        let chars = Array(transcript)
        guard committed < chars.count else { return [] }
        let rest = String(chars[committed...]).trimmingCharacters(in: .whitespacesAndNewlines)
        committed = chars.count
        lastPartial = ""
        return rest.isEmpty ? [] : [Line(text: rest, final: true)]
    }
}

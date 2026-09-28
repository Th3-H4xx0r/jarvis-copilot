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

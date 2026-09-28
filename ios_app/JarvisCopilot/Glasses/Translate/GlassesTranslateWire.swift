import Foundation

/// The GO3's translation wire ("TranslationMaster", message type 8, field 11), as
/// the official INMO app drives it (captured 2026-09-27, see
/// docs/glasses/go3-translation.md). No VERSION field, like the official app.
enum GlassesTranslateWire {
    enum Mode: Int, CaseIterable {
        case simultaneous = 0, dialogue = 1, call = 2
        /// The lens app (SWITCHAPP id) for the mode.
        var module: Int { switch self { case .simultaneous: return 0; case .dialogue: return 1; case .call: return 14 } }
        init?(module: Int) {
            switch module { case 0: self = .simultaneous; case 1: self = .dialogue; case 14: self = .call; default: return nil }
        }
    }
    /// AUDIO header types: live/simultaneous (AUDIO_LIVETRANSLATE_MASTER) sends each
    /// frame as one raw 20 ms Opus packet; dialogue (AUDIO_CHATTRANSLATE_MASTER)
    /// sends the two-stream wrapper (wearer first). From the official Android
    /// app's audioByteProcess — see docs/glasses/go3-translation.md.
    static let liveAudioType: UInt64 = 8
    static let dialogueAudioType: UInt64 = 9

    private static func master(_ payload: Data) -> Data { InmoCommand.envelope(type: 8, field: 11, payload: payload) }

    /// Tells the lens app which languages it is showing (sent once the app is open).
    static func setting(mode: Mode, source: String, target: String, onlyTranslation: Bool = false) -> Data {
        var setting = InmoWireCodec.uint(1, UInt64(mode.rawValue))
        setting += InmoWireCodec.string(2, source)
        setting += InmoWireCodec.string(3, target)
        setting += InmoWireCodec.uint(4, onlyTranslation ? 1 : 0)
        setting += InmoWireCodec.uint(6, 1)
        return master(InmoWireCodec.bytes(2, setting))
    }
    /// One line on the lens: what was said and its translation so far; `finished`
    /// on its last version. Role 1 = heard by the glasses.
    static func line(original: String, translation: String, finished: Bool, role: Int = 1) -> Data {
        var content = InmoWireCodec.string(1, original)
        if !translation.isEmpty { content += InmoWireCodec.string(2, translation) }
        content += InmoWireCodec.uint(3, UInt64(role))
        content += InmoWireCodec.uint(4, finished ? 1 : 0)
        return master(InmoWireCodec.uint(1, 1) + InmoWireCodec.bytes(3, content))
    }
    /// Sent when a session ends, before closing the lens app.
    static func saved() -> Data { master(InmoWireCodec.uint(1, 5) + InmoWireCodec.bytes(5, InmoWireCodec.uint(1, 1))) }

    enum Event: Equatable {
        case opened(Mode), closed(Mode)
        case paused, resumed
        /// Opus packets of the first (speech) stream.
        case audio([Data])
    }

    static func parse(type: Int, fields: [InmoWireField]) throws -> Event? {
        switch type {
        case 15:
            // Simultaneous is app 0, which proto3 sends as an absent field.
            guard let app = try fields.firstField(18)?.nested(),
                  let mode = Mode(module: Int(app.firstField(1)?.varint ?? 0)) else { return nil }
            return (app.firstField(2)?.varint ?? 0) == 1 ? .closed(mode) : .opened(mode)
        case 8:
            guard let master = try fields.firstField(11)?.nested() else { return nil }
            switch master.firstField(1)?.varint {
            case 2: return .paused
            case 3: return .resumed
            default: return nil
            }
        case 0:
            guard let audio = try fields.firstField(3)?.nested(),
                  let header = try audio.firstField(1)?.nested(),
                  let type = header.firstField(4)?.varint,
                  type == liveAudioType || type == dialogueAudioType else { return nil }
            let (data, lengths) = try InmoAIChannel.audioPayload(audio, audioType: type, paired: type == dialogueAudioType)
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
}

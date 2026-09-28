import Foundation

/// The GO3's own Subtitles app (lens app 8, VOICE_SUBTITLE: Message type 18,
/// field 21). Jarvis uses it to show Live Jarvis's transcript on the lens.
/// Schema-derived from VoiceSubtitleProto; no VERSION, like the official app.
enum GlassesSubtitlesWire {
    static let module = 8

    private static func subtitle(_ payload: Data) -> Data {
        InmoCommand.envelope(type: 18, field: 21, payload: payload)
    }
    /// msg_type COMMAND (0, omitted) + command; START (0) is written explicitly.
    static func start() -> Data { subtitle(InmoWireCodec.uint(2, 0, includeZero: true)) }
    static func stop() -> Data { subtitle(InmoWireCodec.uint(2, 1)) }
    /// One caption line; `final` on its last version.
    static func line(_ text: String, final: Bool) -> Data {
        let asr = InmoWireCodec.string(1, text) + InmoWireCodec.uint(2, final ? 1 : 0)
        return subtitle(InmoWireCodec.uint(1, 1) + InmoWireCodec.bytes(3, asr))
    }

    enum Event: Equatable { case opened, closed, exception(code: UInt64) }

    static func parse(type: Int, fields: [InmoWireField]) throws -> Event? {
        switch type {
        case 15:
            guard let app = try fields.firstField(18)?.nested(), app.firstField(1)?.varint == UInt64(module) else { return nil }
            return (app.firstField(2)?.varint ?? 0) == 1 ? .closed : .opened
        case 18:
            guard let body = try fields.firstField(21)?.nested(),
                  let exception = try body.firstField(4)?.nested() else { return nil }
            return .exception(code: exception.firstField(1)?.varint ?? 0)
        default:
            return nil
        }
    }
}

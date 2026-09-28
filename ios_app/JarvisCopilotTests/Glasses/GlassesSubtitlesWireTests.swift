import XCTest
@testable import JarvisCopilot

/// Schema-derived (VoiceSubtitleProto: Message type 18, field 21) until a capture
/// of Jarvis driving app 8 replaces them with observed bytes.
@MainActor
final class GlassesSubtitlesWireTests: XCTestCase {
    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    func testStartStopAndLine() throws {
        XCTAssertEqual(hex(GlassesSubtitlesWire.start()), "1012aa01021000")      // command START (0) explicit
        XCTAssertEqual(hex(GlassesSubtitlesWire.stop()), "1012aa01021001")       // command STOP
        let line = try InmoWireCodec.decode(GlassesSubtitlesWire.line("Maya: hi", final: true))
        XCTAssertEqual(line.firstField(2)?.varint, 18)
        let subtitle = try XCTUnwrap(line.firstField(21)?.nested())
        XCTAssertEqual(subtitle.firstField(1)?.varint, 1)                        // ASR
        let asr = try XCTUnwrap(subtitle.firstField(3)?.nested())
        XCTAssertEqual(asr.firstField(1)?.bytes, Data("Maya: hi".utf8))
        XCTAssertEqual(asr.firstField(2)?.varint, 1)
        let partial = try InmoWireCodec.decode(GlassesSubtitlesWire.line("hi", final: false))
        XCTAssertNil(try partial.firstField(21)?.nested().firstField(3)?.nested().firstField(2))
    }

    func testTheGlassesSubtitlesAppOpenCloseAndExceptionParse() throws {
        func parse(_ data: Data) throws -> GlassesSubtitlesWire.Event? {
            let fields = try InmoWireCodec.decode(data)
            return try GlassesSubtitlesWire.parse(type: Int(fields.firstField(2)?.varint ?? 0), fields: fields)
        }
        XCTAssertEqual(try parse(InmoCommand.openModule(8)), .opened)
        XCTAssertEqual(try parse(InmoCommand.closeModule(8)), .closed)
        XCTAssertNil(try parse(InmoCommand.openModule(5)))
        let exception = InmoCommand.envelope(type: 18, field: 21,
            payload: InmoWireCodec.uint(1, 2) + InmoWireCodec.bytes(4, InmoWireCodec.uint(1, 1001)))
        XCTAssertEqual(try parse(exception), .exception(code: 1001))
    }
}

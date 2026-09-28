import XCTest
@testable import JarvisCopilot

/// Goldens are the official INMO app's own bytes (dialogue translation,
/// 2026-09-27 capture; docs/glasses/go3-translation.md).
@MainActor
final class GlassesTranslateWireTests: XCTestCase {
    private func data(_ hex: String) -> Data {
        let text = hex.filter { !$0.isWhitespace }; var result = Data(); var i = text.startIndex
        while i < text.endIndex { let end = text.index(i, offsetBy: 2); result.append(UInt8(text[i..<end], radix: 16)!); i = end }; return result
    }
    private func parse(_ hex: String) throws -> GlassesTranslateWire.Event? {
        let fields = try InmoWireCodec.decode(data(hex))
        return try GlassesTranslateWire.parse(type: Int(fields.firstField(2)?.varint ?? 0), fields: fields)
    }

    func testSettingMatchesTheOfficialApp() {
        XCTAssertEqual(GlassesTranslateWire.setting(mode: .dialogue, source: "en", target: "zh"),
                       data("10085a0e120c08011202656e1a027a683001"))
    }

    func testLinesMatchTheOfficialApp() {
        XCTAssertEqual(GlassesTranslateWire.line(original: "Cool.", translation: "好", finished: false),
                       data("10085a1208011a0e0a05436f6f6c2e1203e5a5bd1801"))
        XCTAssertEqual(GlassesTranslateWire.line(original: "Cool.", translation: "好的。", finished: true),
                       data("10085a1a08011a160a05436f6f6c2e1209e5a5bde79a84e3808218012001"))
        XCTAssertEqual(GlassesTranslateWire.saved(), data("10085a0608052a020801"))
    }

    func testSimultaneousModeOmitsTheDefaultsAndCanShowOnlyTheTranslation() throws {
        let setting = try InmoWireCodec.decode(GlassesTranslateWire.setting(mode: .simultaneous, source: "es", target: "en", onlyTranslation: true))
        let fields = try XCTUnwrap(setting.firstField(11)?.nested().firstField(2)?.nested())
        XCTAssertNil(fields.firstField(1))          // SIMULTANEOUS = 0, omitted like proto3 does
        XCTAssertEqual(fields.firstField(2)?.bytes, Data("es".utf8))
        XCTAssertEqual(fields.firstField(4)?.varint, 1)
        XCTAssertEqual(fields.firstField(6)?.varint, 1)
    }

    func testLensAppOpenAndCloseParse() throws {
        XCTAssertEqual(try parse("100f9201020801"), .opened(.dialogue))
        XCTAssertEqual(try parse("100f92010408011001"), .closed(.dialogue))
        XCTAssertEqual(try parse("100f920100"), .opened(.simultaneous))
        XCTAssertEqual(try parse("100f92010408001001"), .closed(.simultaneous))
        XCTAssertEqual(try parse("100f920102080e"), .opened(.call))
        XCTAssertNil(try parse("100f9201020805"))   // the notes app, not translation
        XCTAssertEqual(InmoCommand.openModule(GlassesTranslateWire.Mode.simultaneous.module), data("100f920100"))
    }

    func testTranslationAudioKeepsTheFirstStream() throws {
        func framed(_ packet: [UInt8]) -> Data { Data([0, 0, 0, UInt8(packet.count)]) + Data([1, 0, 0, 0]) + Data(packet) }
        let speech: [UInt8] = [0xb0, 0x44, 0x55]
        let frame = framed(speech) + framed([0xb0, 0xff, 0xfe])
        let header = InmoWireCodec.uint(1, 16000) + InmoWireCodec.uint(2, 1) + InmoWireCodec.uint(4, 9)
        let audio = InmoWireCodec.bytes(1, header) + InmoWireCodec.uint(3, UInt64(frame.count))
            + InmoWireCodec.bytes(4, frame) + InmoWireCodec.bytes(5, InmoWireCodec.varint(UInt64(frame.count)))
        let fields = try InmoWireCodec.decode(InmoWireCodec.uint(1, 1) + InmoWireCodec.bytes(3, audio))
        XCTAssertEqual(try GlassesTranslateWire.parse(type: 0, fields: fields), .audio([Data(speech)]))
        // Notes audio (type 3) is not translation audio.
        XCTAssertNil(try GlassesNoteWire.parse(type: 0, fields: fields))
    }

    func testLanguageCodesGoOnTheWireWithoutTheirScript() {
        XCTAssertEqual(GlassesTranslator.base("zh-Hans"), "zh")
        XCTAssertEqual(GlassesTranslator.base("es"), "es")
    }
}

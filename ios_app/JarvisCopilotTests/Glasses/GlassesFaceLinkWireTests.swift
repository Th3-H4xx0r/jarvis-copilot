import XCTest
@testable import JarvisCopilot

/// Goldens are the official INMO iPhone app's own bytes (Face Link capture,
/// 2026-09-27; docs/glasses/go3-face-link.md).
@MainActor
final class GlassesFaceLinkWireTests: XCTestCase {
    private func data(_ hex: String) -> Data {
        let text = hex.filter { !$0.isWhitespace }; var result = Data(); var i = text.startIndex
        while i < text.endIndex { let end = text.index(i, offsetBy: 2); result.append(UInt8(text[i..<end], radix: 16)!); i = end }; return result
    }
    private func parse(_ hex: String) throws -> GlassesFaceLinkWire.Event? {
        let fields = try InmoWireCodec.decode(data(hex))
        return try GlassesFaceLinkWire.parse(type: Int(fields.firstField(2)?.varint ?? 0), fields: fields)
    }

    /// The official app's "not ready" is exactly this; Jarvis answers ready.
    func testReadinessAnswers() {
        XCTAssertEqual(GlassesFaceLinkWire.prepared(false), data("101cfa01021200"))
        XCTAssertEqual(GlassesFaceLinkWire.prepared(true), data("101cfa0104120208 01"))
    }

    func testTheGlassesRequestsParse() throws {
        XCTAssertEqual(try parse("100f9201020806"), .opened)
        XCTAssertEqual(try parse("100f92010408061001"), .closed)
        XCTAssertEqual(try parse("101cfa0100"), .prepareRequested)
        XCTAssertNil(try parse("101cfa01021200"))   // our own answer is not a request
    }

    func testAnImageParses() throws {
        let jpeg = Data([0xff, 0xd8, 0xff, 0xe0, 0xff, 0xd9])
        let image = InmoWireCodec.uint(1, 42) + InmoWireCodec.uint(2, 640) + InmoWireCodec.uint(3, 480) + InmoWireCodec.bytes(4, jpeg)
        let fields = try InmoWireCodec.decode(InmoCommand.envelope(type: 1, field: 4, payload: image))
        XCTAssertEqual(try GlassesFaceLinkWire.parse(type: 1, fields: fields),
                       .image(.init(timestamp: 42, width: 640, height: 480, data: jpeg, kind: 0)))
    }

    func testTheCardCarriesNameJobCompanyAndSimilarity() throws {
        let fields = try InmoWireCodec.decode(GlassesFaceLinkWire.identified(name: "Ana", job: "Designer", company: "Acme", similarity: 0.9))
        XCTAssertEqual(fields.firstField(2)?.varint, 13)
        let card = try XCTUnwrap(fields.firstField(16)?.nested())
        XCTAssertEqual(card.firstField(1)?.bytes, Data("Ana".utf8))
        XCTAssertEqual(card.firstField(3)?.bytes, Data("Acme".utf8))
        XCTAssertNil(card.firstField(4))            // AR_SUCCESS is the default
        XCTAssertEqual(try InmoWireCodec.decode(GlassesFaceLinkWire.notIdentified(.noMatch)).firstField(16)?.nested().firstField(4)?.varint, 3)
    }
}

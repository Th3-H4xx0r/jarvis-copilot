import XCTest
@testable import JarvisCopilot

final class InmoMediaTests: XCTestCase {
    func testObservedAcceptanceAndSplitCoalescedFrames() throws {
        let bytes = Data([0xaa,0x55,0x0b,0,1,0,0,0,1,0,0,0x5a,0xf4])
        var parser = InmoMediaFrameParser()
        XCTAssertTrue(try parser.append(bytes.prefix(5)).isEmpty)
        let frames = try parser.append(Data(bytes.dropFirst(5)) + bytes)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].sub, 1)
        XCTAssertEqual(try frames[0].encoded(), bytes)
    }
    func testCorruptionAndImpossibleDimensionsFail() throws {
        var data = try InmoMediaFrame(payload: Data([1,2,3])).encoded()
        data[11] ^= 1
        var parser = InmoMediaFrameParser()
        XCTAssertThrowsError(try parser.append(data))
        XCTAssertThrowsError(try InmoMediaFrame(total: 0).encoded())
    }
    func testPathTraversalFails() {
        for name in ["../photo.jpg", "..\\photo.jpg", "/tmp/photo.jpg", "photo\u{0}.jpg"] {
            XCTAssertThrowsError(try InmoMediaItem(name: name, directory: "D:\\Photos", size: 3).validate())
        }
    }
    func testFileIntegrityChangingIDsAndDuplicates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let item = InmoMediaItem(name: "test.jpg", directory: "D:\\Photos", size: 8195)
        let sink = try InmoMediaFileSink(item: item, directory: root)
        let first = InmoMediaFrame(id: 255, total: 2, payload: Data(repeating: 1, count: 8192))
        try sink.append(first)
        try sink.append(first)
        XCTAssertThrowsError(try sink.checksum())
        try sink.append(InmoMediaFrame(id: 0, total: 2, index: 1, payload: Data([2,3,4])))
        XCTAssertEqual(try sink.checksum().count, 16)
        let url = try sink.publish(to: root)
        XCTAssertEqual(try Data(contentsOf: url), first.payload + Data([2,3,4]))
    }
    func testCancelledPartialRemovedAndConflictingDuplicateRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var sink: InmoMediaFileSink? = try InmoMediaFileSink(item: InmoMediaItem(name: "test.mp4", directory: "D:\\Video", size: 8193), directory: root)
        let url = try XCTUnwrap(sink?.temporaryURL)
        try sink?.append(InmoMediaFrame(total: 2, payload: Data(repeating: 1, count: 8192)))
        XCTAssertThrowsError(try sink?.append(InmoMediaFrame(total: 2, payload: Data(repeating: 2, count: 8192))))
        sink = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}

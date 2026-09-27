import CryptoKit
import Foundation
import XCTest
@testable import JarvisCopilot

final class InmoTraceTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func pcap() -> Data {
        Data([0xd4,0xc3,0xb2,0xa1, 2,0,4,0, 0,0,0,0, 0,0,0,0,
              0xff,0xff,0,0, 1,0,0,0, 1,0,0,0, 0x20,0xa1,7,0,
              3,0,0,0, 3,0,0,0, 0xaa,0x55,0x01])
    }

    func testPcapSummaryAndTruncatedRecord() throws {
        let url = try directory().appendingPathComponent("capture.pcap")
        try pcap().write(to: url)
        let summary = try InmoTraceInspector.inspect(url)
        XCTAssertEqual(summary.format, "PCAP")
        XCTAssertEqual(summary.packetCount, 1)
        XCTAssertEqual(summary.firstPacketAt?.timeIntervalSince1970 ?? 0, 1.5, accuracy: 0.000001)
        XCTAssertEqual(summary.previews.first?.hex, "aa 55 01")
        var broken = pcap(); broken.removeLast()
        try broken.write(to: url)
        XCTAssertThrowsError(try InmoTraceInspector.inspect(url))
    }

    func testPcapngValidatesTrailingBlockLength() throws {
        let url = try directory().appendingPathComponent("trace.pcapng")
        var data = Data([0x0a,0x0d,0x0d,0x0a, 28,0,0,0, 0x4d,0x3c,0x2b,0x1a,
                         1,0,0,0, 0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff, 28,0,0,0])
        try data.write(to: url)
        XCTAssertEqual(try InmoTraceInspector.inspect(url).packetCount, 0)
        data[24] = 24
        try data.write(to: url)
        XCTAssertThrowsError(try InmoTraceInspector.inspect(url))
    }

    func testOpaqueBluetoothTraceIsNotReportedAsDecodedPackets() throws {
        let url = try directory().appendingPathComponent("trace.pklg")
        try Data([0,1,2,3]).write(to: url)
        let result = try InmoTraceInspector.inspect(url)
        XCTAssertNil(result.packetCount)
        XCTAssertFalse(result.notice.isEmpty)
        XCTAssertEqual(result.format, "PacketLogger (opaque)")
    }

    func testImportPreservesBytesNotesAndDuplicateNamesAcrossReload() async throws {
        let root = try directory(), file = root.appendingPathComponent("same.pcap")
        let original = pcap(); try original.write(to: file)
        let storeRoot = root.appendingPathComponent("store")
        let store = InmoTraceStore(root: storeRoot)
        let session = try await store.create(title: "Brightness experiment")
        _ = try await store.importFile(file, into: session.id, source: .network)
        let result = try await store.importFile(file, into: session.id, source: .network)
        XCTAssertEqual(result.attachments.count, 2)
        XCTAssertNotEqual(result.attachments[0].storedName, result.attachments[1].storedName)
        for attachment in result.attachments {
            XCTAssertEqual(try Data(contentsOf: storeRoot.appendingPathComponent(session.id.uuidString).appendingPathComponent(attachment.storedName)), original)
            XCTAssertEqual(attachment.sha256, SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined())
        }
        _ = try await store.addNote("Changed brightness in INMO at 12:30", to: session.id)
        let reopened = InmoTraceStore(root: storeRoot)
        let loaded = try await reopened.sessions()
        XCTAssertEqual(loaded.first?.notes.first?.text, "Changed brightness in INMO at 12:30")
        XCTAssertEqual(loaded.first?.attachments.count, 2)
        let archive = try await reopened.export(session.id)
        let signature = try Data(contentsOf: archive).prefix(4)
        XCTAssertEqual(Array(signature), [0x50,0x4b,0x03,0x04])
        try? FileManager.default.removeItem(at: archive.deletingLastPathComponent())
    }

    func testInvalidAndOversizeImportLeavesSessionUnchanged() async throws {
        let root = try directory(), file = root.appendingPathComponent("bad.pcap")
        let store = InmoTraceStore(root: root.appendingPathComponent("store"), byteLimit: 40)
        let session = try await store.create(title: "test")
        try pcap().write(to: file)
        do { _ = try await store.importFile(file, into: session.id, source: .network); XCTFail("Must enforce cap") } catch {}
        try Data([1,2,3]).write(to: file)
        do { _ = try await store.importFile(file, into: session.id, source: .network); XCTFail("Must validate PCAP") } catch {}
        let loaded = try await store.sessions()
        XCTAssertEqual(loaded.first?.attachments.count, 0)
        let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("store").appendingPathComponent(session.id.uuidString).path)
        XCTAssertEqual(files, ["manifest.json"])
    }
    func testHelperMetadataMustHaveExpectedSchema() throws {
        let url = try directory().appendingPathComponent("capture.json")
        try Data("{\"schema\":\"inmo-rvi-capture/v1\",\"status\":\"duration_finished\"}".utf8).write(to: url)
        XCTAssertEqual(try InmoTraceInspector.inspect(url).format, "Capture metadata")
        try Data("{\"schema\":\"unrelated\"}".utf8).write(to: url)
        XCTAssertThrowsError(try InmoTraceInspector.inspect(url))
    }

    func testHugeDeclaredPacketLengthDoesNotReadPastFile() throws {
        let url = try directory().appendingPathComponent("huge.pcap")
        var data = pcap()
        for offset in 16..<20 { data[offset] = 0xff }
        for offset in 32..<40 { data[offset] = 0xff }
        try data.write(to: url)
        XCTAssertThrowsError(try InmoTraceInspector.inspect(url))
    }

    func testPcapngPacketPreview() throws {
        let url = try directory().appendingPathComponent("trace.pcapng")
        let section: [UInt8] = [0x0a,0x0d,0x0d,0x0a,28,0,0,0,0x4d,0x3c,0x2b,0x1a,
                              1,0,0,0,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,28,0,0,0]
        let iface: [UInt8] = [1,0,0,0,20,0,0,0,1,0,0,0,0xff,0xff,0,0,20,0,0,0]
        let packet: [UInt8] = [6,0,0,0,36,0,0,0,0,0,0,0,0,0,0,0,1,0,0,0,
                              3,0,0,0,3,0,0,0,0xaa,0x55,1,0,36,0,0,0]
        try Data(section + iface + packet).write(to: url)
        let summary = try InmoTraceInspector.inspect(url)
        XCTAssertEqual(summary.packetCount, 1)
        XCTAssertEqual(summary.linkTypes, [1])
        XCTAssertEqual(summary.previews.first?.hex, "aa 55 01")
        XCTAssertNil(summary.firstPacketAt)
    }

    func testExportRejectsModifiedOriginal() async throws {
        let root = try directory(), file = root.appendingPathComponent("capture.pcap")
        try pcap().write(to: file)
        let storeRoot = root.appendingPathComponent("store")
        let store = InmoTraceStore(root: storeRoot)
        let session = try await store.create(title: "Integrity")
        let imported = try await store.importFile(file, into: session.id, source: .network)
        let stored = storeRoot.appendingPathComponent(session.id.uuidString).appendingPathComponent(imported.attachments[0].storedName)
        try Data([1,2,3]).write(to: stored)
        do { _ = try await store.export(session.id); XCTFail("Must reject changed evidence") } catch {}
    }

}

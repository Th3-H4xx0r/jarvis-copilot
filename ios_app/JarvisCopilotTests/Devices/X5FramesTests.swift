import XCTest
@testable import JarvisCopilot

/// Splitting X5 notifications into frames: the ring packs several history entries — and the
/// `<op> FF` end marker — into one notification, and sends its live packet without a checksum.
/// Every packet below is a worked example from the vendor's protocol sheet.
@MainActor
final class X5FramesTests: XCTestCase {

    private func data(_ hex: String) -> Data {
        Data(hex.split(separator: " ").map { UInt8($0, radix: 16)! })
    }

    /// 15 bytes in, checksum appended.
    private func framed(_ hex: String) -> Data {
        var bytes = [UInt8](data(hex))
        bytes += [UInt8](repeating: 0, count: max(0, 15 - bytes.count))
        bytes.append(RingProtocol.checksum(bytes))
        return Data(bytes)
    }

    private func split(_ d: Data) -> [RingInbound] { X5Frames.split(d).map(\.inbound) }

    func testDayTotalsEntryAndEndMarkerInOnePacket() {
        let frames = split(data("51 00 24 08 27 2E 00 00 00 11 00 00 00 03 00 00 00 93 00 00 00 00 00 00 00 00 00 51 FF"))
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].cmd, 0x51)
        XCTAssertEqual(frames[0].payload.count, 26)
        XCTAssertFalse(X5Frames.isEnd(frames[0]))
        XCTAssertTrue(X5Frames.isEnd(frames[1]))
    }

    func testTwoStepBlocksAndTheEndMarker() {
        let frames = split(data("52 00 00 24 08 08 23 58 19 1D 00 25 00 00 00 0A 13 00 00 00 00 00 00 00 00 "
                                + "52 02 00 24 08 08 23 43 19 0D 00 19 00 01 00 0D 00 00 00 00 00 00 00 00 00 52 FF"))
        XCTAssertEqual(frames.map(\.cmd), [0x52, 0x52, 0x52])
        XCTAssertEqual(Array(frames[1].payload.prefix(2)), [0x02, 0x00])
        XCTAssertTrue(X5Frames.isEnd(frames[2]))
    }

    func testSleepChunkIs130Bytes() {
        var hex = "53 00 00 24 08 23 13 36 00 36"
        for i in 0..<120 { hex += i < 4 ? " 05" : (i < 54 ? " 02" : " 00") }
        let frames = split(data(hex + " 53 FF"))
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].payload.count, 129)
        XCTAssertTrue(X5Frames.isEnd(frames[1]))
    }

    func testEveryOtherHistoryKindSplitsByItsEntryLength() {
        let cases: [(String, Int)] = [
            ("54 00 00 24 08 08 22 59 27 4C 4E 00 00 00 00 00 00 00 00 00 00 00 00 00 "
             + "54 01 00 24 08 08 22 58 12 4C 49 4A 4D 50 51 50 4F 4E 4F 4C 4B 4B 4C 4C 54 FF", 3),
            ("55 00 00 24 08 27 09 01 30 46 55 FF", 2),
            ("56 00 00 24 08 09 00 59 30 40 00 4D 1E 75 3E 56 01 00 24 08 08 22 59 30 32 00 4E 38 76 3F 56 FF", 3),
            ("62 00 00 24 08 09 00 59 59 5A 01 62 0A 00 24 08 27 08 56 59 D9 00 62 FF", 3),
            ("66 00 00 24 08 09 00 00 23 61 66 01 00 24 08 27 09 00 19 62 66 FF", 3),
            ("60 00 00 24 08 09 00 00 23 61 60 FF", 2),
            ("5C 00 00 24 09 03 10 36 47 00 8A 43 00 75 00 00 00 54 2A 0E 40 80 E3 6B 3D 5C FF", 2),
        ]
        for (hex, count) in cases {
            let frames = split(data(hex))
            XCTAssertEqual(frames.count, count, hex)
            XCTAssertTrue(frames.last.map(X5Frames.isEnd) ?? false, hex)
            XCTAssertFalse(frames.dropLast().contains(where: X5Frames.isEnd), hex)
        }
    }

    func testALoneEndMarkerIsOneEndFrame() {
        let frames = split(data("56 FF"))
        XCTAssertEqual(frames.count, 1)
        XCTAssertTrue(X5Frames.isEnd(frames[0]))
    }

    func testAnEntryWithIdFFIsNotTheEndMarker() {
        let frames = split(data("55 FF 00 24 08 27 09 01 30 46"))
        XCTAssertEqual(frames.count, 1)
        XCTAssertFalse(X5Frames.isEnd(frames[0]))
        XCTAssertEqual(frames[0].payload.count, 9)
    }

    func testCommandFramesKeepTheirChecksumRule() {
        let good = split(framed("41 24 08 08 08 10 47 06 F4"))
        XCTAssertEqual(good, [.command(cmd: 0x41, isError: false,
                                       payload: [0x24, 0x08, 0x08, 0x08, 0x10, 0x47, 0x06, 0xF4, 0, 0, 0, 0, 0, 0])])
        var corrupt = [UInt8](framed("41 24 08 08 08 10 47 06 F4"))
        corrupt[15] &+= 1
        XCTAssertEqual(split(Data(corrupt)), [])
    }

    func testFailureRepliesSetTheErrorFlagButUnbindDoesNot() {
        XCTAssertEqual(split(framed("C1")), [.command(cmd: 0x41, isError: true, payload: [UInt8](repeating: 0, count: 14))])
        XCTAssertEqual(split(framed("87")), [.command(cmd: 0x87, isError: false, payload: [UInt8](repeating: 0, count: 14))])
    }

    func testLivePacketHasNoChecksum() {
        let live = data("09 66 00 00 00 19 01 00 00 05 00 00 00 25 00 00 00 00 00 00 00 00 5A 01 00 00 00 00 00 00 00 00")
        let frames = split(live)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].cmd, 0x09)
        XCTAssertEqual(frames[0].payload.count, 31)
    }

    func testWorkoutTickHasNoChecksum() {
        let frames = split(data("18 48 64 00 00 00 00 00 20 41 3C 00 00 00 00 00 80 3F 00 00 00"))
        XCTAssertEqual(frames.map(\.cmd), [0x18])
        XCTAssertEqual(frames[0].payload.count, 20)
    }

    func testDeliverCompletesAPagedTransaction() async throws {
        let transport = RingTransport()
        let link = DeliveringLink()
        link.transport = transport
        transport.link = link
        link.reply = data("55 00 00 24 08 27 09 01 30 46 55 01 00 24 08 27 09 05 30 48 55 FF")
        let frames = try await transport.perform(.x5History(.singleHR, after: nil), until: .packets(X5Frames.isEnd))
        XCTAssertEqual(frames.count, 3)
        XCTAssertTrue(X5Frames.isEnd(frames[2]))
    }
}

/// Answers every write with one notification, split the way the X5 manager splits them.
@MainActor
private final class DeliveringLink: RingLink {
    var isLinkReady = true
    var hasBigDataChannel = false
    weak var transport: RingTransport?
    var reply = Data()

    func send(_ data: Data, on channel: RingChannel) {
        let reply = self.reply
        Task { @MainActor [weak self] in
            for frame in X5Frames.split(reply) { self?.transport?.deliver(frame.inbound, note: frame.note) }
        }
    }
}

import XCTest
@testable import JarvisCopilot

/// The OTA frame sequence and the pre-flight gates must match the ring's own receiver
/// (decompiled in qring-re/fw) and the reference uploader (qring-re/fw/patch/ota_flash.py).
/// A regression here means the ring rejects the image — or, worse, we start a transfer it
/// would reject.
final class RingFirmwareUpdateTests: XCTestCase {

    /// A minimal image that passes every receiver gate: magic, model string, image_id,
    /// size in range, and a wrapper checksum over file[0x50:] at 0x0C.
    private func validImage(size: Int = 0x3000, fill: UInt8 = 0xA5) -> [UInt8] {
        var img = [UInt8](repeating: fill, count: size)
        img[0] = 0xE5; img[1] = 0xC3; img[2] = 0xBD; img[3] = 0x81                 // magic 0x81BDC3E5 LE
        for (i, b) in Array("RT12_V3.1".utf8).enumerated() { img[0x30 + i] = b }    // model string
        img[0x54] = 0x93; img[0x55] = 0x27                                          // image_id 0x2793 LE
        return fixChecksum(img)
    }

    func testPreconditionAcceptsAValidImage() {
        XCTAssertNil(RingFirmwareUpdate.precondition(validImage()))
    }

    func testPreconditionRejectsTheObviousDefects() {
        var badMagic = validImage(); badMagic[0] = 0
        XCTAssertEqual(RingFirmwareUpdate.precondition(badMagic), .badMagic)

        XCTAssertEqual(RingFirmwareUpdate.precondition([0xE5, 0xC3, 0xBD, 0x81]), .tooShort)

        var badID = validImage(); badID[0x54] = 0; badID[0x55] = 0
        // image_id is checked before the checksum, so the id failure is what surfaces.
        XCTAssertEqual(RingFirmwareUpdate.precondition(fixChecksum(badID)), .badImageID(0))

        var corrupt = validImage(); corrupt[0x100] ^= 0xFF     // body byte changed, checksum now stale
        XCTAssertEqual(RingFirmwareUpdate.precondition(corrupt), .wrapperChecksum)
    }

    func testStepsMatchTheDfuSequence() {
        let img = validImage(size: 0x900)                       // 3 pockets of 1024/1024/256
        let steps = RingFirmwareUpdate.steps(for: img)
        XCTAssertEqual(steps.first?.cmd, 1)
        XCTAssertEqual(steps.first?.payload, [])
        XCTAssertEqual(steps.last?.cmd, 5)
        XCTAssertEqual(steps[steps.count - 2].cmd, 4)

        // init (cmd 2): [01][len u32 LE][crc16 u16 LE][bytesum u16 LE]
        let initStep = steps[1]
        XCTAssertEqual(initStep.cmd, 2)
        let crc = RingProtocol.crc16(img)
        let sum = img.reduce(UInt16(0)) { $0 &+ UInt16($1) }
        var expected: [UInt8] = [0x01]
        expected += [UInt8(img.count & 0xFF), UInt8((img.count >> 8) & 0xFF), 0, 0]
        expected += [UInt8(crc & 0xFF), UInt8(crc >> 8)]
        expected += [UInt8(sum & 0xFF), UInt8(sum >> 8)]
        XCTAssertEqual(initStep.payload, expected)

        // three data pockets, each tagged with a 1-based little-endian sequence number
        let data = steps.filter { $0.cmd == 3 }
        XCTAssertEqual(data.count, 3)
        XCTAssertEqual(RingFirmwareUpdate.pocketCount(img), 3)
        XCTAssertEqual(Array(data[0].payload.prefix(2)), [1, 0])
        XCTAssertEqual(data[0].payload.count, 2 + 1024)
        XCTAssertEqual(Array(data[2].payload.prefix(2)), [3, 0])
        XCTAssertEqual(data[2].payload.count, 2 + 256)
    }

    func testRunSendsEveryStepAndReportsProgress() async throws {
        let img = validImage(size: 0x900)
        var sentCmds: [UInt8] = []
        var lastProgress = (0, 0)
        try await RingFirmwareUpdate.run(
            image: img,
            send: { cmd, _ in sentCmds.append(cmd); return [.bigData(cmd: cmd, payload: [0])] },
            progress: { lastProgress = ($0, $1) })
        XCTAssertEqual(sentCmds, [1, 2, 3, 3, 3, 4, 5])
        XCTAssertEqual(lastProgress.0, 3)
        XCTAssertEqual(lastProgress.1, 3)
    }

    func testRunStopsWhenTheRingNaksAPocket() async {
        let img = validImage(size: 0x900)
        do {
            try await RingFirmwareUpdate.run(image: img, send: { cmd, _ in
                [.bigData(cmd: cmd, payload: [cmd == 3 ? 1 : 0])]    // NAK the first data pocket
            })
            XCTFail("expected the NAK to abort the update")
        } catch let failure as RingFirmwareUpdate.Failure {
            XCTAssertEqual(failure, .ringRejected(cmd: 3, status: 1))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    private func fixChecksum(_ image: [UInt8]) -> [UInt8] {
        var img = image
        var sum: UInt32 = 0
        for b in img[0x50...] { sum = (sum &+ UInt32(b)) & 0xFFFF_FFFF }
        img[0x0C] = UInt8(sum & 0xFF); img[0x0D] = UInt8((sum >> 8) & 0xFF)
        img[0x0E] = UInt8((sum >> 16) & 0xFF); img[0x0F] = UInt8((sum >> 24) & 0xFF)
        return img
    }
}

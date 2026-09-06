import Foundation

@main
enum ScaleProtocolTests {
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }

    static func main() {
        // 0xA161, a stable 75.0 kg reading with 500 Ω impedance, in kilograms.
        var frame: [UInt8] = [
            0xA5, 0x12, 0x00, 0x10, 0x00, 0x00, 0x01, 0x61, 0xA1, 0x00,
            0xF8, 0x24, 0x01, 0xF4, 0x01, 0x00, 0x00, 0x00, 0x00, 0x01,
            0x01, 0x00,
        ]
        frame[5] = ScaleProtocol.checksum(frame)

        let reading = ScaleProtocol.parse(frame)
        expect(reading?.isStable == true, "stable flag must decode")
        expect(reading?.hasImpedance == true, "impedance flag must decode")
        expect(abs((reading?.weightKg ?? 0) - 75.0) < 0.001, "weight must normalize to kg")
        expect(reading?.impedanceOhms == 500, "impedance must be little-endian")
        expect(ScaleProtocol.parse(Array(frame.prefix(8))) == nil, "short frames must be rejected")

        // The physical ESF551 can report a few hundred grams of unloaded sensor drift.
        // VeSync turns that into zero so its weighing screen exits; Jarvis must expose
        // the same zero transition instead of keeping a phantom 0.2 kg session alive.
        var unloaded = frame
        unloaded[10] = 0xC8 // 200 g
        unloaded[11] = 0
        unloaded[12] = 0
        unloaded[19] = 0
        unloaded[20] = 0
        unloaded[5] = 0
        unloaded[5] = ScaleProtocol.checksum(unloaded)
        expect(ScaleProtocol.parse(unloaded)?.weightKg == 0,
               "sub-1 kg unloaded drift must normalize to a zero transition")

        var accumulator = VsV2FrameAccumulator()
        expect(accumulator.append(Array(frame.prefix(20))).isEmpty,
               "a partial ATT notification must not be decoded early")
        let completed = accumulator.append(Array(frame.dropFirst(20)))
        expect(completed.count == 1 && ScaleProtocol.parse(completed[0]) != nil,
               "split live packets must be reassembled")
        let batched = accumulator.append(frame + frame)
        expect(batched.count == 2 && batched.allSatisfy { ScaleProtocol.parse($0) != nil },
               "two packets in one notification must both be surfaced")

        let timeSync = ScaleProtocol.makeTimeSyncFrame(
            date: Date(timeIntervalSince1970: 1_700_000_000),
            timeZone: TimeZone(secondsFromGMT: -21_600)!, sequence: 7)
        expect(timeSync.count == 15 && timeSync[0] == 0xA5 && timeSync[1] == 0x22,
               "time synchronization must use the VeSync VsV2 request envelope")
        expect(timeSync[6] == 1 && timeSync[7] == 0x81 && timeSync[8] == 0xA0,
               "time synchronization command must be 0xA081 on channel 1")
        expect(timeSync.reduce(0, { $0 + Int($1) }) & 0xFF == 0xFF,
               "outbound frame checksum must complement the full frame")

        var badChecksum = frame
        badChecksum[10] ^= 0x01
        expect(ScaleProtocol.parse(badChecksum) == nil, "invalid checksums must be rejected")
    }
}

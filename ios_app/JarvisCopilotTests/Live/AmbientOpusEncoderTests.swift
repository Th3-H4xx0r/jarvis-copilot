import AVFoundation
import XCTest
@testable import JarvisCopilot

/// Does CoreAudio on a REAL device encode Opus through `AVAudioConverter`?
///
/// This is the gate in front of the whole Opus change, and it is deliberately a
/// measurement rather than a mock. `kAudioFormatOpus` exists in CoreAudioTypes on
/// every recent OS, but "the constant exists" and "this device's converter will
/// produce packets" are different claims, and only the second one justifies
/// labelling the uplink `opus-packets`. A simulator answer would not settle it
/// either: the simulator's audio codecs are the host Mac's.
///
/// So the failure mode this file exists to prevent is not a crash. It is a build
/// that quietly falls back to PCM16 while `hello` says Opus, which would make
/// every stored recording undecodable by the thing that reads its codec label.
@MainActor
final class AmbientOpusEncoderTests: XCTestCase {

    /// Bytes of 16 kHz mono PCM16 that a bitrate-limited encoder cannot trivially
    /// flatter: two tones plus a rasp, rather than a pure sine (which Opus can
    /// encode almost for free, and which would make the size assertion below pass
    /// even on a broken build).
    private func speechLikePCM(ms: Int, rate: Int = 16000) -> Data {
        let frames = rate * ms / 1000
        var out = Data(capacity: frames * 2)
        var noise = UInt64(0x2545_F491_4F6C_DD1D)
        for index in 0..<frames {
            let t = Double(index) / Double(rate)
            // A 180 Hz "voice" with a third harmonic, amplitude-modulated at 4 Hz
            // the way syllables are.
            let envelope = 0.55 + 0.45 * sin(2 * .pi * 4 * t)
            var value = 0.5 * sin(2 * .pi * 180 * t) + 0.25 * sin(2 * .pi * 540 * t)
            // xorshift, so the "noise" is identical on every run and a failure is
            // reproducible.
            noise ^= noise << 13; noise ^= noise >> 7; noise ^= noise << 17
            value += 0.08 * (Double(noise % 2000) / 1000 - 1)
            let sample = Int16(max(-1, min(1, value * envelope)) * 32000)
            out.append(UInt8(truncatingIfNeeded: sample))
            out.append(UInt8(truncatingIfNeeded: sample >> 8))
        }
        return out
    }

    /// ~85 ms at 16 kHz — the chunk `AmbientAudioInput` actually delivers, so the
    /// encoder is driven with the packet-misaligned sizes it will see in the field
    /// rather than with tidy 20 ms multiples.
    private static let tapChunkBytes = 2720

    // MARK: - The device question

    func testCoreAudioEncodesOpusOnThisDevice() throws {
        let encoder = try XCTUnwrap(
            AmbientOpusEncoder.make(sourceRate: 16000),
            "CoreAudio refused to build the encoder: \(AmbientOpusEncoder.lastError)")

        let pcm = speechLikePCM(ms: 1000)
        var payload = Data()
        for start in stride(from: 0, to: pcm.count, by: Self.tapChunkBytes) {
            let end = min(start + Self.tapChunkBytes, pcm.count)
            let out = try XCTUnwrap(
                encoder.encode(pcm.subdata(in: start..<end)),
                "the encoder errored mid-stream: \(AmbientOpusEncoder.lastError)")
            payload.append(out)
        }
        payload.append(encoder.flush())

        XCTAssertFalse(payload.isEmpty,
                       "no bytes came out of the encoder: \(AmbientOpusEncoder.lastError)")

        let packets = try XCTUnwrap(AmbientOpusEncoder.packets(in: payload),
                                    "the length framing did not parse back")
        // 1 s of audio at 20 ms a packet is ~50; the floor is loose because the
        // remainder handling may hold the last partial packet until `flush`.
        XCTAssertGreaterThanOrEqual(packets.count, 40, "got \(packets.count) packets")
        for packet in packets {
            XCTAssertGreaterThan(packet.count, 0, "an empty packet is not a packet")
            XCTAssertLessThanOrEqual(packet.count, AmbientOpusEncoder.maxPacketBytes)
        }

        // **The claim that matters.** 24 kbps is 3 kB for this second of audio
        // against 32 kB of PCM16. A converter that handed the samples straight
        // back — the silent-passthrough failure — could not pass this.
        let encodedBytes = packets.reduce(0) { $0 + $1.count }
        XCTAssertLessThan(encodedBytes, pcm.count / 4,
                          "\(encodedBytes)B out of \(pcm.count)B in is not compression")
        XCTAssertNil(payload.range(of: pcm.prefix(128)),
                     "the input samples appear verbatim in the output")
    }

    /// The tail of an utterance must not sit in the encoder. `flush` pads to a
    /// packet boundary and gives it up.
    func testFlushGivesUpABufferedTail() throws {
        let encoder = try XCTUnwrap(
            AmbientOpusEncoder.make(sourceRate: 16000),
            "CoreAudio refused to build the encoder: \(AmbientOpusEncoder.lastError)")
        // 10 ms: half a packet, so `encode` has nothing to emit yet.
        let out = try XCTUnwrap(encoder.encode(speechLikePCM(ms: 10)))
        XCTAssertTrue(out.isEmpty, "half a packet is not a packet")
        XCTAssertFalse(encoder.flush().isEmpty, "the tail has to come out")
    }

    /// The rate the phone declares has to be the rate the packets are at, or a
    /// decoder reading `opus-packets-len32@<rate>` resamples the archive wrongly.
    func testTheDeclaredRateIsTheOpusRate() {
        XCTAssertEqual(AmbientOpusEncoder.rate, 48000)
        XCTAssertEqual(AmbientOpusEncoder.wireRate, 48000)
    }

    // MARK: - Framing (pure — no CoreAudio)

    /// The server prefixes each payload it receives with its own 4-byte length, so
    /// the phone must hand it ONE packet per frame. This is the helper that turns
    /// the encoder's blob into those packets, and it has to be exact: a
    /// mis-splitting here would store one "packet" that is really several.
    func testLengthPrefixedPayloadSplitsBackIntoExactPackets() throws {
        let first = Data([1, 2, 3])
        let second = Data(repeating: 9, count: 200)
        var blob = Data()
        blob.append(AmbientOpusEncoder.bigEndian32(UInt32(first.count)))
        blob.append(first)
        blob.append(AmbientOpusEncoder.bigEndian32(UInt32(second.count)))
        blob.append(second)

        let packets = try XCTUnwrap(AmbientOpusEncoder.packets(in: blob))
        XCTAssertEqual(packets, [first, second])
    }

    /// A truncated payload is reported, not half-read. Guessing would send a
    /// partial packet up as if it were whole.
    func testATruncatedPayloadIsRefused() {
        var blob = AmbientOpusEncoder.bigEndian32(50)
        blob.append(Data(repeating: 7, count: 10))
        XCTAssertNil(AmbientOpusEncoder.packets(in: blob))
    }

    func testTheLengthPrefixIsBigEndian() {
        XCTAssertEqual(Array(AmbientOpusEncoder.bigEndian32(0x0102_0304)), [1, 2, 3, 4])
    }
}

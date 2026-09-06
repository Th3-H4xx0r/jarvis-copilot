import XCTest
@testable import JarvisCopilot

private let rate = 24000 // the realtime reply rate the server sends

private func pcm(_ ms: Int, seed: Int = 0) -> Data {
    let samples = rate * ms / 1000
    var out = Data(count: samples * 2)
    for i in 0..<out.count { out[i] = UInt8((seed + i) & 0xFF) }
    return out
}

/// Case-for-case port of `mobile_client/test/voice/pcm_chunker_test.dart`.
final class PcmChunkerTests: XCTestCase {

    // MARK: - Emits playable chunks as audio arrives

    func testHoldsBackUntilTheFirstChunkIsWorthPlaying() {
        let c = PcmChunker(sampleRate: rate)
        XCTAssertTrue(c.add(pcm(50), tag: 0).isEmpty)
        let out = c.add(pcm(150), tag: 0)
        XCTAssertEqual(out.count, 1)
        XCTAssertGreaterThanOrEqual(out[0].durationMs, PcmChunker.firstChunkMs)
    }

    func testTheFirstChunkIsMuchShorterThanTheSteadyStateChunk() {
        // The whole point of plan 1.7: the first audible sample must not wait
        // for a whole segment.
        XCTAssertLessThan(PcmChunker.firstChunkMs, PcmChunker.chunkMs)
        XCTAssertLessThanOrEqual(PcmChunker.firstChunkMs, 250)
    }

    func testLaterChunksUseTheLargerSteadyStateSize() {
        let c = PcmChunker(sampleRate: rate)
        _ = c.add(pcm(PcmChunker.firstChunkMs), tag: 0) // first chunk out
        XCTAssertTrue(c.add(pcm(PcmChunker.chunkMs - 60), tag: 0).isEmpty)
        let out = c.add(pcm(120), tag: 0)
        XCTAssertEqual(out.count, 1)
        XCTAssertGreaterThanOrEqual(out[0].durationMs, PcmChunker.chunkMs)
    }

    func testPreservesByteOrderExactlyAcrossChunkBoundaries() {
        let c = PcmChunker(sampleRate: rate)
        var input = Data()
        var emitted = Data()
        for i in 0..<12 {
            let block = pcm(90, seed: i * 7)
            input.append(block)
            for chunk in c.add(block, tag: 0) { emitted.append(chunk.bytes) }
        }
        for chunk in c.flush(tag: 0) { emitted.append(chunk.bytes) }
        XCTAssertEqual(emitted, input)
    }

    func testNeverSplitsA16BitSample() {
        let c = PcmChunker(sampleRate: rate)
        // Odd-length feeds: the dangling byte must be carried over, not emitted.
        for _ in 0..<30 {
            for chunk in c.add(Data(count: 2401), tag: 0) {
                XCTAssertTrue(chunk.bytes.count % 2 == 0)
            }
        }
    }

    // MARK: - Segment accounting drives the karaoke schedule

    func testReportsTheRunningTotalDurationForTheSegment() throws {
        let c = PcmChunker(sampleRate: rate)
        let a = try XCTUnwrap(c.add(pcm(300), tag: 4).first)
        let b = try XCTUnwrap(c.add(pcm(600), tag: 4).first)
        XCTAssertEqual(a.segmentMsSoFar, a.durationMs)
        XCTAssertEqual(b.segmentMsSoFar, a.durationMs + b.durationMs)
        XCTAssertEqual(b.tag, 4)
    }

    func testFlushEndsTheSegmentAndEmitsTheRemainder() {
        let c = PcmChunker(sampleRate: rate)
        _ = c.add(pcm(200), tag: 1)
        let rest = c.flush(tag: 1)
        XCTAssertEqual(rest.count, 1)
        XCTAssertTrue(rest[0].isSegmentEnd)
    }

    func testFlushWithNothingBufferedEmitsNothing() {
        let c = PcmChunker(sampleRate: rate)
        _ = c.add(pcm(200), tag: 1)
        _ = c.flush(tag: 1)
        XCTAssertTrue(c.flush(tag: 1).isEmpty)
    }

    func testANewTagRestartsTheFirstChunkFastStartAndTheTotals() throws {
        let c = PcmChunker(sampleRate: rate)
        _ = c.add(pcm(500), tag: 0)
        _ = c.flush(tag: 0)
        let first = c.add(pcm(PcmChunker.firstChunkMs + 10), tag: 1)
        XCTAssertEqual(first.count, 1)
        let only = try XCTUnwrap(first.first)
        XCTAssertEqual(only.segmentMsSoFar, only.durationMs)
    }

    // MARK: - Interruption

    func testResetDropsBufferedAudioSoABargeInNeverPlaysLate() {
        let c = PcmChunker(sampleRate: rate)
        _ = c.add(pcm(100), tag: 0) // below the first-chunk threshold, still buffered
        c.reset()
        XCTAssertTrue(c.flush(tag: 0).isEmpty)
        XCTAssertEqual(c.bufferedBytes, 0)
    }
}

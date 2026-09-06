import XCTest
@testable import JarvisCopilot

/// Ordering, drain and flush for `AudioQueue` — the three things you would
/// actually hear if they broke. No Flutter test existed for this.
@MainActor
final class AudioQueueTests: XCTestCase {

    private func make() -> (AudioQueue, MockAudioOutput, TestVoiceClock) {
        let output = MockAudioOutput()
        let clock = TestVoiceClock()
        return (AudioQueue(output: output, clock: clock), output, clock)
    }

    // MARK: - Clip queue ordering

    func testMp3ClipsPlayOneAtATimeInFifoOrder() async {
        let (queue, output, _) = make()
        queue.enqueueMp3(Data([1]), tag: 0)
        queue.enqueueMp3(Data([2]), tag: 1)
        queue.enqueueMp3(Data([3]), tag: 2)
        await queue.settle()

        XCTAssertEqual(output.played.map { Array($0.bytes) }, [[1]],
                       "only the first clip starts; the rest wait")
        output.finishClip()
        await queue.settle()
        XCTAssertEqual(output.played.map { Array($0.bytes) }, [[1], [2]])
        output.finishClip()
        await queue.settle()
        XCTAssertEqual(output.played.map { Array($0.bytes) }, [[1], [2], [3]])
        XCTAssertEqual(output.played.map(\.ext), ["mp3", "mp3", "mp3"])
    }

    func testEmptyClipsAreIgnored() async {
        let (queue, output, _) = make()
        queue.enqueueMp3(Data())
        queue.enqueuePcm(Data())
        await queue.settle()
        XCTAssertTrue(output.played.isEmpty)
        XCTAssertFalse(queue.isBusy)
    }

    // MARK: - Drain

    func testDrainingFiresIdleOnceAndZeroesTheAmplitude() async {
        let (queue, output, _) = make()
        var idleCount = 0
        var amplitudes: [Double] = []
        queue.onIdle = { idleCount += 1 }
        queue.onAmplitude = { amplitudes.append($0) }

        queue.enqueueMp3(Data([1]))
        await queue.settle()
        XCTAssertTrue(queue.isBusy)
        XCTAssertEqual(idleCount, 0)

        output.finishClip() // queue is now empty
        await queue.settle()
        XCTAssertEqual(idleCount, 1)
        XCTAssertFalse(queue.isBusy)
        XCTAssertEqual(amplitudes.last, 0)
        XCTAssertTrue(amplitudes.contains(0.6), "a coarse speaking pulse drives the orb")
    }

    func testABadClipIsSkippedRatherThanWedgingTheQueue() async {
        let (queue, output, _) = make()
        var idleCount = 0
        queue.onIdle = { idleCount += 1 }
        output.playSucceeds = false

        queue.enqueueMp3(Data([1]))
        queue.enqueueMp3(Data([2]))
        await queue.settle()

        XCTAssertTrue(output.played.isEmpty)
        XCTAssertFalse(queue.isBusy, "the queue drained instead of hanging")
        XCTAssertEqual(idleCount, 1)
    }

    // MARK: - Interruption

    func testStopClearsTheQueueAndDoesNotFireIdle() async {
        let (queue, output, _) = make()
        var idleCount = 0
        queue.onIdle = { idleCount += 1 }

        queue.enqueueMp3(Data([1]))
        queue.enqueueMp3(Data([2]))
        await queue.settle()
        await queue.stop()
        await queue.settle()

        XCTAssertEqual(idleCount, 0, "barge-in must not look like a finished reply")
        XCTAssertFalse(queue.isBusy)
        XCTAssertGreaterThan(output.stopClipCount, 0)
        // The clip that was already playing is the only one that ever started.
        XCTAssertEqual(output.played.count, 1)
    }

    // MARK: - WAV wrapping

    func testEnqueuePcmWrapsAValidWavHeader() async {
        let (queue, output, _) = make()
        let pcm = replyPcm(ms: 100)
        queue.enqueuePcm(pcm, sampleRate: 24000, tag: 0)
        await queue.settle()

        let clip = try? XCTUnwrap(output.played.first)
        let bytes = clip?.bytes ?? Data()
        XCTAssertEqual(clip?.ext, "wav")
        XCTAssertEqual(bytes.count, 44 + pcm.count)
        XCTAssertEqual(String(decoding: bytes[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: bytes[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(String(decoding: bytes[36..<40], as: UTF8.self), "data")
        XCTAssertEqual(le32(bytes, 24), 24000, "sample rate")
        XCTAssertEqual(le32(bytes, 40), pcm.count, "data length")
        XCTAssertEqual(le32(bytes, 4), 36 + pcm.count, "RIFF size")
        XCTAssertEqual(Data(bytes.dropFirst(44)), pcm)
    }

    func testEnqueuePcmReportsTheExactDuration() async {
        let (queue, _, _) = make()
        var starts: [(Int?, Int)] = []
        queue.onClipStart = { starts.append(($0, $1)) }
        queue.enqueuePcm(replyPcm(ms: 250), sampleRate: 24000, tag: 3)
        await queue.settle()
        XCTAssertEqual(starts.count, 1)
        XCTAssertEqual(starts.first?.0, 3)
        XCTAssertEqual(starts.first?.1, 250)
    }

    func testMp3StartsOnAnEstimateThenCorrectsToTheRealDuration() async {
        let (queue, output, _) = make()
        output.clipDuration = 1.25
        var starts: [(Int?, Int)] = []
        queue.onClipStart = { starts.append(($0, $1)) }
        queue.enqueueMp3(Data([9]), tag: 2)
        await queue.settle()
        // 0 tells the reply model "not known yet"; the real duration follows.
        XCTAssertEqual(starts.map(\.1), [0, 1250])
        XCTAssertEqual(starts.map(\.0), [2, 2])
    }

    func testClipPositionsAreOffsetByTheSegmentAudioAlreadyPlayed() async {
        let (queue, output, _) = make()
        output.isStreamAvailable = false // force the split-clip fallback path
        var positions: [(Int?, Int)] = []
        queue.onPosition = { positions.append(($0, $1)) }

        // Two chunks of one segment: the second must report positions continuing
        // from where the first left off, or the highlight resets mid-sentence.
        queue.appendPcm(replyPcm(ms: PcmChunker.firstChunkMs), sampleRate: 24000, tag: 0)
        await queue.settle()
        output.report(position: 0.05)
        queue.appendPcm(replyPcm(ms: PcmChunker.chunkMs), sampleRate: 24000, tag: 0)
        output.finishClip()
        await queue.settle()
        output.report(position: 0.05)

        XCTAssertEqual(positions.map(\.1), [50, PcmChunker.firstChunkMs + 50])
    }

    // MARK: - Gapless stream path

    func testAppendPcmOpensOneStreamAndFeedsInByteOrder() async {
        let (queue, output, _) = make()
        var starts: [(Int?, Int)] = []
        var playbackStarts = 0
        queue.onClipStart = { starts.append(($0, $1)) }
        queue.onPlaybackStart = { playbackStarts += 1 }

        let a = replyPcm(ms: 100, seed: 1)
        let b = replyPcm(ms: 100, seed: 200)
        queue.appendPcm(a, sampleRate: 24000, tag: 0)
        queue.appendPcm(b, sampleRate: 24000, tag: 0)
        await queue.settle()

        XCTAssertEqual(output.startedStreams, [24000], "one continuous stream, no seams")
        XCTAssertEqual(output.fed, a + b)
        XCTAssertTrue(output.played.isEmpty, "nothing goes through the clip player")
        XCTAssertEqual(playbackStarts, 1)
        // Running segment total, so the karaoke schedule stretches as the
        // sentence arrives instead of restarting per chunk.
        XCTAssertEqual(starts.map(\.1), [100, 200])
        XCTAssertTrue(queue.isBusy)
        XCTAssertTrue(queue.hasPendingPcm)
    }

    func testANewTagRebasesTheSegmentPositionsWithinOneStream() async {
        let (queue, output, _) = make()
        var starts: [(Int?, Int)] = []
        queue.onClipStart = { starts.append(($0, $1)) }

        queue.appendPcm(replyPcm(ms: 200), sampleRate: 24000, tag: 0)
        queue.appendPcm(replyPcm(ms: 150), sampleRate: 24000, tag: 1)
        await queue.settle()

        XCTAssertEqual(output.startedStreams.count, 1)
        XCTAssertEqual(starts.map(\.0), [0, 1])
        XCTAssertEqual(starts.map(\.1), [200, 150], "the next sentence restarts at its own base")
    }

    func testEndPcmSegmentGoesIdleOnceTheFedAudioHasPlayedOut() async {
        let (queue, _, clock) = make()
        var idleCount = 0
        queue.onIdle = { idleCount += 1 }

        queue.appendPcm(replyPcm(ms: 200), sampleRate: 24000, tag: 0)
        await queue.settle()
        queue.endPcmSegment(tag: 0)
        await queue.settle()

        clock.advance(ms: 200) // still inside the fed audio
        XCTAssertEqual(idleCount, 0)
        clock.advance(ms: 200 + AudioQueue.nativeIdleGraceMs)
        XCTAssertEqual(idleCount, 1)
        XCTAssertFalse(queue.isBusy)
    }

    func testAStreamWithNoAudioEndIdlesAfterTheStallWindow() async {
        let (queue, _, clock) = make()
        var idleCount = 0
        queue.onIdle = { idleCount += 1 }

        queue.appendPcm(replyPcm(ms: 200), sampleRate: 24000, tag: 0)
        await queue.settle()

        clock.advance(ms: 200 + AudioQueue.nativeStallIdleMs - 200)
        XCTAssertEqual(idleCount, 0, "not stalled yet")
        clock.advance(ms: 400)
        XCTAssertEqual(idleCount, 1, "safety net: a dropped audio_end must not hang the turn")
    }

    func testStreamPositionsAdvanceWithTheClock() async {
        let (queue, _, clock) = make()
        var positions: [(Int?, Int)] = []
        queue.onPosition = { positions.append(($0, $1)) }

        queue.appendPcm(replyPcm(ms: 500), sampleRate: 24000, tag: 7)
        await queue.settle()
        clock.advance(ms: AudioQueue.nativeTickMs)
        XCTAssertEqual(positions.map(\.0), [7])
        XCTAssertEqual(positions.map(\.1), [AudioQueue.nativeTickMs])
    }

    func testStopDuringAStreamFlushesAndDoesNotFireIdle() async {
        let (queue, output, clock) = make()
        var idleCount = 0
        queue.onIdle = { idleCount += 1 }

        queue.appendPcm(replyPcm(ms: 300), sampleRate: 24000, tag: 0)
        await queue.settle()
        await queue.stop()
        await queue.settle()

        XCTAssertEqual(output.flushCount, 1, "drop queued audio, keep the barge-in silent")
        XCTAssertEqual(idleCount, 0)
        XCTAssertFalse(queue.isBusy)
        XCTAssertFalse(queue.hasPendingPcm)
        // The tick is gone, so a later clock advance can't resurrect the stream.
        clock.advance(ms: 5000)
        XCTAssertEqual(idleCount, 0)
    }

    /// swift-correctness M18: `stop()` drops the per-frame task chain, so a
    /// barge-in can't keep feeding the sentence the user interrupted (and the
    /// last task isn't retained until the next one replaces it).
    func testStopDropsWorkStillQueuedOnTheChain() async {
        let (queue, output, _) = make()
        for i in 0..<6 { queue.appendPcm(replyPcm(ms: 100, seed: i), sampleRate: 24000, tag: 0) }

        await queue.stop()
        let fedAtStop = output.fed.count
        await queue.settle()
        await settleVoiceTasks(10)

        XCTAssertEqual(output.fed.count, fedAtStop,
                       "audio queued before the barge-in must never reach the speaker")
        XCTAssertFalse(queue.isBusy)
    }

    // MARK: - Fallback (no render stream available)

    func testWithoutAStreamPcmIsCutIntoWavClipsInByteOrder() async {
        let (queue, output, _) = make()
        output.isStreamAvailable = false

        var input = Data()
        for i in 0..<8 {
            let block = replyPcm(ms: 90, seed: i * 11)
            input.append(block)
            queue.appendPcm(block, sampleRate: 24000, tag: 0)
            await queue.settle()
            // Let each queued clip play so the next one starts.
            while queue.isBusy && !output.played.isEmpty {
                output.finishClip()
                await queue.settle()
                if !queue.isBusy { break }
            }
        }
        queue.endPcmSegment(tag: 0)
        await queue.settle()
        while queue.isBusy {
            output.finishClip()
            await queue.settle()
        }

        XCTAssertTrue(output.startedStreams.isEmpty)
        XCTAssertEqual(output.playedPcm, input, "every byte, exactly once, in order")
    }

    func testAStreamThatRefusesToStartFallsBackToClips() async {
        let (queue, output, _) = make()
        output.streamStartSucceeds = false // available, but start() says no

        queue.appendPcm(replyPcm(ms: PcmChunker.firstChunkMs + 20), sampleRate: 24000, tag: 0)
        await queue.settle()

        XCTAssertEqual(output.played.count, 1)
        XCTAssertEqual(output.played.first?.ext, "wav")
    }

    // MARK: - Dispose

    func testDisposeStopsEverythingAndIgnoresLaterWork() async {
        let (queue, output, _) = make()
        var idleCount = 0
        queue.onIdle = { idleCount += 1 }
        await queue.dispose()

        queue.enqueueMp3(Data([1]))
        queue.appendPcm(replyPcm(ms: 200), tag: 0)
        await queue.settle()

        XCTAssertTrue(output.played.isEmpty)
        XCTAssertTrue(output.startedStreams.isEmpty)
        XCTAssertEqual(idleCount, 0)
    }

    // MARK: - Helper

    private func le32(_ d: Data, _ offset: Int) -> Int {
        Int(d[offset]) | Int(d[offset + 1]) << 8 | Int(d[offset + 2]) << 16 | Int(d[offset + 3]) << 24
    }
}

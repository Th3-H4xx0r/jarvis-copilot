import AVFoundation
import XCTest
@testable import JarvisCopilot

/// "Both" plays the front and rear clips as one: one bar seeks, plays and pauses the two, and the rear
/// stays on the front's moment, lined up by when each clip started.
@MainActor
final class DashcamDualPlaybackTests: XCTestCase {

    /// A plain grey MP4 of `seconds` at 10 fps, small enough to write in a moment.
    private func video(seconds: Int) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dual-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 36,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 36,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(seconds * 10) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let b = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(b, [])
            memset(CVPixelBufferGetBaseAddress(b), Int32(frame % 255), CVPixelBufferGetDataSize(b))
            CVPixelBufferUnlockBaseAddress(b, [])
            adaptor.append(b, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
        return url
    }

    private func ready(_ player: AVPlayer) async throws {
        for _ in 0..<100 where player.currentItem?.status != .readyToPlay { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(player.currentItem?.status, .readyToPlay)
    }

    private func wait(_ seconds: Double) async throws { try await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }

    func testOneBarSeeksPlaysAndPausesBothOnTheSameMoment() async throws {
        let front = AVPlayer(url: try await video(seconds: 8))
        let rear = AVPlayer(url: try await video(seconds: 8))
        try await ready(front)
        try await ready(rear)
        rear.play()                                         // the rear's own load started it: the clock takes over
        let clock = DashcamDualClock()
        // The front file started 1 s after the rear: at front 0:03 the rear is at 0:04.
        clock.attach(lead: front, follow: rear, offset: 1, fallbackDuration: 8)
        XCTAssertEqual(rear.rate, 0, "attached paused: the rear stops with the front")
        XCTAssertEqual(clock.duration, 8, accuracy: 0.2)

        clock.seek(to: 3)
        try await wait(0.4)
        XCTAssertEqual(front.currentTime().seconds, 3, accuracy: 0.15)
        XCTAssertEqual(rear.currentTime().seconds, 4, accuracy: 0.15)

        clock.toggle()                                      // play both
        try await wait(1.5)
        XCTAssertTrue(clock.playing)
        XCTAssertGreaterThan(rear.rate, 0)
        let drift = rear.currentTime().seconds - (front.currentTime().seconds + 1)
        XCTAssertLessThan(abs(drift), DashcamDualClock.maxDrift + 0.1, "rear drifted \(drift) s")

        clock.scrub(true)                                   // holding the seek bar: both hold still
        XCTAssertEqual(front.rate, 0)
        XCTAssertEqual(rear.rate, 0)
        clock.seek(to: 1)
        clock.scrub(false)                                  // let go: both go on from there
        try await wait(0.5)
        XCTAssertGreaterThan(front.rate, 0)
        XCTAssertGreaterThan(rear.rate, 0)
        XCTAssertLessThan(abs(rear.currentTime().seconds - (front.currentTime().seconds + 1)), 0.35)

        clock.toggle()                                      // pause both
        XCTAssertEqual(front.rate, 0)
        XCTAssertEqual(rear.rate, 0)
        clock.detach()
    }

    func testTheRearWaitsAtItsStartUntilItsClipBegins() async throws {
        let front = AVPlayer(url: try await video(seconds: 6))
        let rear = AVPlayer(url: try await video(seconds: 6))
        try await ready(front)
        try await ready(rear)
        let clock = DashcamDualClock()
        // The rear file started 2 s after the front: for the front's first 2 s there's no rear yet.
        clock.attach(lead: front, follow: rear, offset: -2, fallbackDuration: 6)
        clock.seek(to: 0.5)
        clock.toggle()
        try await wait(0.5)
        XCTAssertEqual(rear.rate, 0)
        XCTAssertEqual(rear.currentTime().seconds, 0, accuracy: 0.1)
        clock.seek(to: 3)                                   // past its start: it plays, 2 s behind
        try await wait(0.8)
        XCTAssertGreaterThan(rear.rate, 0)
        XCTAssertLessThan(abs(rear.currentTime().seconds - (front.currentTime().seconds - 2)), 0.35)
        clock.detach()
    }

    func testTheBarReadsMinutesAndSeconds() {
        XCTAssertEqual(DashcamDualControls.clock(7.9), "0:07")
        XCTAssertEqual(DashcamDualControls.clock(60), "1:00")
        XCTAssertEqual(DashcamDualControls.clock(.nan), "0:00")
    }
}

import XCTest
@testable import JarvisCopilot

/// The sound half of barge-in, frame by frame, with no mic or audio stack.
final class BargeInDetectorTests: XCTestCase {
    private let frameMs = 100
    private var speech: Double { VoiceStore.bargeInSpeechAmp * 3 }
    private var echo: Double { VoiceStore.bargeInSpeechAmp / 4 }

    func testSpeechThatLastsTriggers() {
        var detector = VoiceStore.BargeInDetector()
        var fired = false
        for _ in 0..<(VoiceStore.bargeInSustainMs / frameMs) {
            fired = detector.feed(speech, frameMs: frameMs, learning: true)
        }
        XCTAssertTrue(fired)
        XCTAssertTrue(detector.lastVoiced)
    }

    func testASingleSpikeNeverTriggers() {
        var detector = VoiceStore.BargeInDetector()
        XCTAssertFalse(detector.feed(speech, frameMs: frameMs, learning: true))
        for _ in 0..<10 { XCTAssertFalse(detector.feed(echo, frameMs: frameMs, learning: true)) }
    }

    func testTheReplysOwnEchoRaisesTheBar() {
        var detector = VoiceStore.BargeInDetector()
        let loudEcho = VoiceStore.bargeInSpeechAmp * 2
        for _ in 0..<(VoiceStore.bargeInEchoWindowMs / frameMs) { detector.noteEcho(loudEcho, frameMs: frameMs) }
        XCTAssertGreaterThan(detector.bar, VoiceStore.bargeInSpeechAmp)
        // Speech at the old bar is now under the echo-lifted one.
        var fired = false
        for _ in 0..<10 { fired = detector.feed(VoiceStore.bargeInSpeechAmp * 1.1, frameMs: frameMs, learning: false) || fired }
        XCTAssertFalse(fired)
    }

    func testNotLearningLeavesTheEchoLevelAlone() {
        var detector = VoiceStore.BargeInDetector()
        for _ in 0..<20 { _ = detector.feed(echo, frameMs: frameMs, learning: false) }
        XCTAssertTrue(detector.echoFrames.isEmpty)
        XCTAssertEqual(detector.echoFloor, 0)
    }

    func testResetForgetsTheWindowAndTheEcho() {
        var detector = VoiceStore.BargeInDetector()
        for _ in 0..<5 { _ = detector.feed(speech, frameMs: frameMs, learning: true) }
        detector.noteEcho(echo, frameMs: frameMs)
        detector.reset()
        XCTAssertEqual(detector.voicedMs, 0)
        XCTAssertTrue(detector.echoFrames.isEmpty)
    }
}

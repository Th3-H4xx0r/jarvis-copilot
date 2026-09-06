import XCTest
@testable import JarvisCopilot

/// Feed `ms` of audio at amplitude `amp` in 20 ms frames, returning the first
/// non-`.none` event (and stopping there) or `.none`.
/// Ported from `test/voice/endpointer_test.dart`'s `_feed`.
private func feed(_ ep: Endpointer, _ amp: Double, _ ms: Int, frameMs: Int = 20) -> EndpointEvent {
    var left = ms
    while left > 0 {
        let dt = left < frameMs ? left : frameMs
        left -= dt
        let ev = ep.update(amp, dt)
        if ev != .none { return ev }
    }
    return .none
}

/// Case-for-case port of `mobile_client/test/voice/endpointer_test.dart`.
final class EndpointerTests: XCTestCase {

    // MARK: - VAD hysteresis

    func testDoesNotStartATurnBelowTheSpeechThreshold() {
        let ep = Endpointer()
        XCTAssertEqual(feed(ep, Endpointer.speechThreshold - 0.01, 2000), .none)
        XCTAssertFalse(ep.speaking)
    }

    func testStartsATurnOnceTheSpeechThresholdIsCrossed() {
        let ep = Endpointer()
        _ = feed(ep, 0.30, 300)
        XCTAssertTrue(ep.speaking)
    }

    func testEnergyBetweenTheTwoThresholdsKeepsTheTurnOpen() {
        let ep = Endpointer()
        _ = feed(ep, 0.30, 1000)
        // Between silence(0.04) and speech(0.08): still "voiced" — the silence
        // timer must not run.
        let mid = (Endpointer.speechThreshold + Endpointer.silenceThreshold) / 2
        XCTAssertEqual(feed(ep, mid, 3000), .none)
        XCTAssertEqual(ep.silenceMs, 0)
    }

    // MARK: - Silence budgets

    func testEndsANormalUtteranceAfterTheBaseSilenceWindow() {
        let ep = Endpointer()
        _ = feed(ep, 0.30, 1500) // long, steady utterance → base budget
        XCTAssertEqual(ep.requiredSilenceMs, Endpointer.baseSilenceMs)
        XCTAssertEqual(feed(ep, 0.0, Endpointer.baseSilenceMs - 40), .none)
        XCTAssertEqual(feed(ep, 0.0, 80), .endOfTurn)
    }

    func testAShortUtteranceWaitsTheExtendedSilenceWindow() {
        let ep = Endpointer()
        // 400 ms of speech — under `shortUtteranceMs` → extended budget.
        _ = feed(ep, 0.30, 400)
        XCTAssertEqual(ep.requiredSilenceMs, Endpointer.extendedSilenceMs)
        XCTAssertEqual(feed(ep, 0.0, Endpointer.baseSilenceMs + 100), .none)
        XCTAssertEqual(
            feed(ep, 0.0, Endpointer.extendedSilenceMs - Endpointer.baseSilenceMs - 100 + 40),
            .endOfTurn)
    }

    func testARisingEnergyTailWaitsTheExtendedSilenceWindow() {
        let ep = Endpointer()
        _ = feed(ep, 0.15, 1000) // quiet body
        _ = feed(ep, 0.60, 200)  // getting louder right before the pause
        XCTAssertEqual(ep.requiredSilenceMs, Endpointer.extendedSilenceMs)
        XCTAssertEqual(feed(ep, 0.0, Endpointer.baseSilenceMs + 100), .none)
    }

    func testAFallingEnergyTailUsesTheBaseSilenceWindow() {
        let ep = Endpointer()
        _ = feed(ep, 0.60, 1000) // loud body
        _ = feed(ep, 0.15, 200)  // trailing off
        XCTAssertEqual(ep.requiredSilenceMs, Endpointer.baseSilenceMs)
        XCTAssertEqual(feed(ep, 0.0, Endpointer.baseSilenceMs + 40), .endOfTurn)
    }

    func testSpeechResumingInsideTheSilenceWindowCancelsTheEndpoint() {
        let ep = Endpointer()
        _ = feed(ep, 0.30, 1000)
        XCTAssertEqual(feed(ep, 0.0, 300), .none)
        _ = feed(ep, 0.30, 200) // picked back up
        XCTAssertEqual(ep.silenceMs, 0)
        XCTAssertEqual(feed(ep, 0.0, 300), .none) // budget restarted
    }

    // MARK: - Guards

    func testASubMinimumBlipNeverEndsATurnAndResetsTheDetector() {
        let ep = Endpointer()
        // 100 ms of noise — under `minUtteranceMs`.
        _ = feed(ep, 0.50, 100)
        XCTAssertTrue(ep.speaking)
        XCTAssertEqual(feed(ep, 0.0, 5000), .none)
        XCTAssertFalse(ep.speaking, "blip is discarded, not endpointed")
    }

    func testEndsTheTurnAtTheMaxUtteranceLengthEvenWithoutSilence() {
        let ep = Endpointer()
        XCTAssertEqual(feed(ep, 0.50, Endpointer.maxUtteranceMs - 200), .none)
        XCTAssertEqual(feed(ep, 0.50, 400), .endOfTurn)
    }

    func testResetReturnsTheDetectorToThePreSpeechState() {
        let ep = Endpointer()
        _ = feed(ep, 0.30, 1000)
        _ = feed(ep, 0.0, 100)
        ep.reset()
        XCTAssertFalse(ep.speaking)
        XCTAssertEqual(ep.speechMs, 0)
        XCTAssertEqual(ep.silenceMs, 0)
    }

    func testVoicedMsExcludesTheTrailingSilence() {
        let ep = Endpointer()
        _ = feed(ep, 0.30, 1000)
        _ = feed(ep, 0.0, 200)
        XCTAssertEqual(ep.voicedMs, 1000)
        XCTAssertEqual(ep.speechMs, 1200)
    }

    func testNegativeOrZeroFrameDurationsAreIgnored() {
        let ep = Endpointer()
        XCTAssertEqual(ep.update(0.5, -50), .none)
        XCTAssertEqual(ep.speechMs, 0)
    }

    // MARK: - frameMsForPcm16

    func testConvertsAPcm16MonoByteCountToMilliseconds() {
        XCTAssertEqual(Endpointer.frameMsForPcm16(byteLength: 3200, sampleRate: 16000), 100)
        XCTAssertEqual(Endpointer.frameMsForPcm16(byteLength: 2048, sampleRate: 16000), 64)
        XCTAssertEqual(Endpointer.frameMsForPcm16(byteLength: 0, sampleRate: 16000), 0)
    }

    // MARK: - Faster than the old fixed 1500 ms

    func testANormalUtteranceEndpointsWellUnderTheLegacyConstant() {
        let ep = Endpointer()
        _ = feed(ep, 0.30, 1200)
        var silence = 0
        while silence < 1500 {
            if ep.update(0.0, 20) == .endOfTurn { break }
            silence += 20
        }
        XCTAssertLessThan(silence, 1500)
        XCTAssertLessThanOrEqual(silence, Endpointer.baseSilenceMs)
    }
}

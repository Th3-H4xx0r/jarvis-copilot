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

/// Feed 100 ms frames cycling through `amps` (the phone's real frame size) for
/// `ms`, returning the ms fed when the first non-`.none` event came, or nil.
private func feedCycle(_ ep: Endpointer, _ amps: [Double], _ ms: Int) -> Int? {
    var fed = 0, i = 0
    while fed < ms {
        fed += 100
        if ep.update(amps[i % amps.count], 100) != .none { return fed }
        i += 1
    }
    return nil
}

/// His car on CarPlay (2026-10-16 log): a quiet talker through the car's mic,
/// and road/fan noise that never drops under `silenceThreshold`.
private let carSpeech = [0.03, 0.045, 0.012, 0.04, 0.035, 0.02, 0.045]
private let carNoise = [0.005, 0.0096, 0.007, 0.009, 0.006, 0.0085]

final class EndpointerTests: XCTestCase {

    // MARK: - VAD hysteresis

    func testQuietPhoneSpeechEndsAfterAPause() {
        let ep = Endpointer()
        _ = feed(ep, 0.025, 1600)
        XCTAssertTrue(ep.speaking)
        XCTAssertEqual(feed(ep, 0.002, 1200), .endOfTurn)
    }

    /// A noisy room — a Mac's fans, its voice processing's gain — sits above
    /// `silenceThreshold` the whole time, so no pause was ever silent and the
    /// turn ran to the 30 s cap. A pause far below how loud the turn was ends it.
    func testANoisyRoomStillEndsTheTurn() {
        let ep = Endpointer()
        _ = feed(ep, 0.02, 500)          // the room, loud enough to count as speech
        _ = feed(ep, 0.3, 1500)          // the person
        XCTAssertEqual(feed(ep, 0.02, 1500), .endOfTurn)
    }

    func testQuietRoomNoiseDoesNotCreateATurn() {
        let ep = Endpointer()
        XCTAssertEqual(feed(ep, 0.003, 5000), .none)
        XCTAssertFalse(ep.speaking)
    }

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
        // A QUIET speaker: after loud speech the same level is the room going
        // quiet, and ends the turn (testANoisyRoomStillEndsTheTurn).
        _ = feed(ep, 0.025, 1000)
        // Between silence and speech: still "voiced" — the silence timer must
        // not run.
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

    // MARK: - Steady background noise (a car)

    /// The noise after his last word stayed between 0.005 and 0.0096 — over the
    /// fixed silence level, under the 15% relative one — so no pause counted and
    /// a finished turn stayed open for seconds. Steady and far below the turn is
    /// a pause.
    func testSteadyCarNoiseAfterAQuietTalkerEndsTheTurn() throws {
        let ep = Endpointer()
        XCTAssertNil(feedCycle(ep, carNoise, 1000), "the car alone is not a turn")
        XCTAssertNil(feedCycle(ep, carSpeech, 2100))
        XCTAssertTrue(ep.speaking)
        let waited = try XCTUnwrap(feedCycle(ep, carNoise, 3000), "the turn must end in the car's noise")
        XCTAssertLessThanOrEqual(waited, Endpointer.extendedSilenceMs + 200)
    }

    /// Speech is never steady: a soft syllable is next to a loud one.
    func testAQuietTalkerInTheCarIsNotCutOffMidSentence() {
        let ep = Endpointer()
        _ = feedCycle(ep, carNoise, 1000)
        XCTAssertNil(feedCycle(ep, carSpeech, 8000))
    }

    /// A breath in the car is not the end: the steady rule waits the long window.
    func testABreathInTheCarDoesNotEndTheTurn() {
        let ep = Endpointer()
        _ = feedCycle(ep, carSpeech, 2100)
        XCTAssertNil(feedCycle(ep, carNoise, Endpointer.extendedSilenceMs - 200))
        XCTAssertNil(feedCycle(ep, carSpeech, 1400), "he carried on talking")
        XCTAssertTrue(ep.speaking)
    }

    /// Noise as loud as the turn itself (the turn opened on it) is not "far
    /// below" it — nothing here may end a turn that has no speech in it.
    func testLoudSteadyNoiseAloneIsNotEndedEarly() {
        let ep = Endpointer()
        XCTAssertNil(feedCycle(ep, [0.02, 0.026, 0.022], 5000))
    }
}

import XCTest
@testable import Jarvis

/// "Hey Jarvis": the phrase matcher, the voice-activity gate, the window
/// backoff, the rebuild limiter and when the spotter may listen at all.
final class VoiceTests: XCTestCase {

    // MARK: wake phrase

    func testTheWakePhrasesMatch() {
        for heard in ["Hey Jarvis", "hey jarvis", "OK, Jarvis.", "Okay Jarvis open my mail", "ok jarvis",
                      "Hey Jervis", "hey, jarvis!", "so I said hey jarvis", "Hey Jar vis", "O.K. Jarvis"] {
            XCTAssertTrue(WakePhrase.matches(heard), heard)
        }
    }

    func testOtherWordsDoNotWakeIt() {
        for heard in ["Jarvis", "jarvis can you", "hey Travis", "they jarvis", "hey", "okay", "",
                      "hey there jarvis", "Jarvis hey", "hey jarvisland"] {
            XCTAssertFalse(WakePhrase.matches(heard), heard)
        }
    }

    func testNormaliseStripsPunctuationAndCase() {
        XCTAssertEqual(WakePhrase.normalise("  Hey, JARVIS! "), "hey jarvis")
    }

    // MARK: voice activity

    private func calibrated(_ vad: inout EnergyVAD, at power: Double = 1e-6) {
        for _ in 0..<EnergyVAD.calibFrames { XCTAssertEqual(vad.feed(power), .none) }
    }

    func testVADStartsOnSpeechAndEndsAfterSilence() {
        var vad = EnergyVAD()
        calibrated(&vad)
        XCTAssertEqual(vad.feed(1e-6), .none)
        XCTAssertEqual(vad.feed(1e-3), .start)
        XCTAssertTrue(vad.isActive)
        for _ in 0..<(EnergyVAD.silenceFrames - 1) { XCTAssertEqual(vad.feed(1e-6), .none) }
        XCTAssertEqual(vad.feed(1e-6), .end)
        XCTAssertFalse(vad.isActive)
    }

    func testVADNeverTriggersWhileCalibrating() {
        var vad = EnergyVAD()
        for _ in 0..<EnergyVAD.calibFrames { XCTAssertEqual(vad.feed(1.0), .none) }
    }

    func testVADForcesAnEndOnEndlessNoise() {
        var vad = EnergyVAD()
        calibrated(&vad)
        XCTAssertEqual(vad.feed(1e-2), .start)
        var ended = false
        for _ in 0..<EnergyVAD.maxActiveFrames where vad.feed(1e-2) == .end { ended = true; break }
        XCTAssertTrue(ended)
        // The noise became the floor: the same level no longer starts a segment.
        XCTAssertEqual(vad.feed(1e-2), .none)
    }

    func testVADKeepsItsDurationsAtAnotherBufferRate() {
        var vad = EnergyVAD()
        vad.setFrameRate(10)   // 100 ms buffers: 0.8 s of silence is 8 buffers
        for _ in 0..<5 { _ = vad.feed(1e-6) }   // 0.5 s calibration
        XCTAssertEqual(vad.feed(1e-3), .start)
        for _ in 0..<7 { XCTAssertEqual(vad.feed(1e-6), .none) }
        XCTAssertEqual(vad.feed(1e-6), .end)
    }

    func testVADResetKeepsTheNoiseFloor() {
        var vad = EnergyVAD()
        calibrated(&vad)
        XCTAssertEqual(vad.feed(1e-3), .start)
        vad.reset()
        XCTAssertFalse(vad.isActive)
        XCTAssertEqual(vad.feed(1e-3), .start, "no new calibration after a reset")
    }

    // MARK: backoff

    func testFastFailsBackOffThenStop() {
        var b = WakeBackoff()
        XCTAssertEqual(b.windowEnded(elapsed: 0.2, wasError: true), .delay(0.5))
        XCTAssertEqual(b.windowEnded(elapsed: 0.2, wasError: true), .delay(1.0))
        XCTAssertEqual(b.windowEnded(elapsed: 0.2, wasError: false), .stop)
        b.reset()
        XCTAssertEqual(b.windowEnded(elapsed: 0.2, wasError: false), .delay(0.5))
    }

    func testANormalWindowReopensAtOnceAndClearsTheStreak() {
        var b = WakeBackoff()
        _ = b.windowEnded(elapsed: 0.1, wasError: true)
        XCTAssertEqual(b.windowEnded(elapsed: 5, wasError: false), .open)
        XCTAssertEqual(b.streak, 0)
    }

    func testBackoffIsCapped() {
        var b = WakeBackoff(fastThreshold: 1, maxFastFails: 10, base: 1, maxDelay: 3)
        var last: WakeBackoff.Action = .open
        for _ in 0..<6 { last = b.windowEnded(elapsed: 0, wasError: true) }
        XCTAssertEqual(last, .delay(3))
    }

    // MARK: rebuild limiter

    func testRebuildsAreSpacedAndCappedPerMinute() {
        var l = RebuildLimiter()
        XCTAssertTrue(l.allow(at: 0))
        XCTAssertFalse(l.allow(at: 3), "less than 5 s after the last one")
        XCTAssertTrue(l.allow(at: 6))
        XCTAssertTrue(l.allow(at: 12))
        XCTAssertTrue(l.allow(at: 18))
        XCTAssertTrue(l.allow(at: 24))
        XCTAssertFalse(l.allow(at: 30), "five in this minute already")
        XCTAssertTrue(l.allow(at: 61), "a new minute")
    }

    // MARK: when it listens

    func testOffByDefault() {
        XCTAssertEqual(WakeConditions().status, .off)
        XCTAssertFalse(WakeConditions().shouldRun)
    }

    func testPermissionsComeFirst() {
        var c = WakeConditions(enabled: true)
        c.micAllowed = false
        XCTAssertEqual(c.status, .needsPermission(.microphone))
        c.micAllowed = true
        c.speechAllowed = false
        XCTAssertEqual(c.status, .needsPermission(.speech))
        c.speechAllowed = true
        c.recognizerAvailable = false
        XCTAssertEqual(c.status, .unavailable)
    }

    func testEveryPauseReasonPausesIt() {
        let base = WakeConditions(enabled: true)
        XCTAssertEqual(base.status, .listening)
        XCTAssertTrue(base.shouldRun)
        let paths: [WritableKeyPath<WakeConditions, Bool>] = [\.locked, \.asleep, \.lowPower, \.dictating,
                                                               \.recordingNote, \.voiceOpen]
        for path in paths {
            var c = base
            c[keyPath: path] = true
            guard case .paused(let why) = c.status else { return XCTFail("\(path) did not pause") }
            XCTAssertFalse(why.isEmpty)
            XCTAssertFalse(c.shouldRun)
        }
    }

    func testAWakeIsIgnoredWhileSomethingNeedsYou() {
        XCTAssertNotNil(WakeFilter.blocked(pending: true, typing: false))
        XCTAssertNotNil(WakeFilter.blocked(pending: false, typing: true))
        XCTAssertNil(WakeFilter.blocked(pending: false, typing: false))
    }

    func testStaleRecognitionCallbacksAreDropped() {
        var g = SpotterGeneration()
        let first = g.bump()
        XCTAssertTrue(g.isValid(first))
        g.bump()
        XCTAssertFalse(g.isValid(first))
    }
}

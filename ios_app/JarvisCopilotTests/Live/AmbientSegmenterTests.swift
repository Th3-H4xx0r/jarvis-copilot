import XCTest
@testable import JarvisCopilot

/// Ambient segmentation policy. The thing these pin is that the ambient path is
/// tuned for a ROOM, not for a phone held to a face — and that its timestamps come
/// from the audio, never a wall clock.
final class AmbientSegmenterTests: XCTestCase {

    /// One 20 ms frame's worth of "duration", so the arithmetic in these tests is
    /// easy to follow.
    private let dt = 20

    private func feed(_ segmenter: AmbientSegmenter, amp: Double, ms: Int) -> [AmbientSegmentEvent] {
        var events: [AmbientSegmentEvent] = []
        for _ in 0..<(ms / dt) {
            let event = segmenter.update(amp, dt)
            if event != .none { events.append(event) }
        }
        return events
    }

    private var loud: Double { AmbientSegmenter.speechThreshold * 3 }
    private var quiet: Double { AmbientSegmenter.silenceThreshold / 2 }

    // MARK: - The reason this type exists

    /// The core claim of design §5.1: ambient capture runs without Apple's voice
    /// processing, so a distant talker arrives far quieter than the voice turn's
    /// endpointer expects. If these gates were not well below `Endpointer`'s, a room
    /// full of conversation would never open a single utterance.
    func testAmbientGatesAreFarBelowTheNearFieldVoiceTurnsGates() {
        XCTAssertLessThan(AmbientSegmenter.speechThreshold, Endpointer.speechThreshold / 2)
        XCTAssertLessThan(AmbientSegmenter.silenceThreshold, Endpointer.silenceThreshold / 2)
        XCTAssertLessThan(AmbientSegmenter.silenceThreshold, AmbientSegmenter.speechThreshold,
                          "the closing gate must be the lower one, or a voice on the boundary chatters")
    }

    /// A room has more blips than a phone at your mouth, so the "that was not
    /// speech" floor has to be higher than the voice turn's.
    func testTheBlipFloorIsHigherThanTheVoiceTurns() {
        XCTAssertGreaterThan(AmbientSegmenter.minUtteranceMs, Endpointer.minUtteranceMs)
    }

    // MARK: - Segmentation

    func testSpeechOpensAnUtteranceAndSilenceClosesIt() {
        let segmenter = AmbientSegmenter()
        let opening = feed(segmenter, amp: loud, ms: 1000)
        XCTAssertEqual(opening.count, 1)
        guard case .started = opening[0] else { return XCTFail("expected started, got \(opening[0])") }
        XCTAssertTrue(segmenter.speaking)

        let closing = feed(segmenter, amp: quiet, ms: AmbientSegmenter.silenceMs + 100)
        XCTAssertEqual(closing.count, 1)
        guard case .ended(let startMs, let endMs) = closing[0] else {
            return XCTFail("expected ended, got \(closing[0])")
        }
        XCTAssertLessThan(startMs, endMs)
        XCTAssertFalse(segmenter.speaking)
    }

    /// The reported end is where the VOICE stopped, not where the silent wait
    /// finished — otherwise every row's duration includes 800 ms of dead air.
    func testTheReportedEndIsWhereTheVoiceStoppedNotWhereTheWaitEnded() {
        let segmenter = AmbientSegmenter()
        _ = feed(segmenter, amp: loud, ms: 1000)
        let voiceStoppedAt = segmenter.elapsedMs

        let closing = feed(segmenter, amp: quiet, ms: AmbientSegmenter.silenceMs + 200)
        guard case .ended(_, let endMs)? = closing.first else { return XCTFail("expected ended") }

        XCTAssertEqual(Double(endMs), Double(voiceStoppedAt), accuracy: Double(dt * 2),
                       "the end must be the last voiced frame, not the end of the silence")
        XCTAssertLessThan(endMs, segmenter.elapsedMs - AmbientSegmenter.silenceMs / 2)
    }

    /// The opening consonant sits in the frame before the one that crossed the gate.
    func testTheStartIsBackdatedSoTheFirstSoundIsNotClipped() {
        let segmenter = AmbientSegmenter()
        // Ten quiet frames first, so there is room to backdate into.
        _ = feed(segmenter, amp: quiet, ms: 200)
        let before = segmenter.elapsedMs
        let events = feed(segmenter, amp: loud, ms: 100)
        guard case .started(let atMs)? = events.first else { return XCTFail("expected started") }
        XCTAssertLessThan(atMs, before, "the start must be backdated before the gate opened")
        XCTAssertGreaterThanOrEqual(atMs, before - AmbientSegmenter.leadInMs - dt)
    }

    /// A door, a cup, a cough. It must not become an empty transcript row, and the
    /// detector must not be left wedged open either.
    func testABlipIsDiscardedAndLeavesTheDetectorReady() {
        let segmenter = AmbientSegmenter()
        let blip = feed(segmenter, amp: loud, ms: AmbientSegmenter.minUtteranceMs - 100)
        XCTAssertEqual(blip.count, 1, "it opens")
        let after = feed(segmenter, amp: quiet, ms: AmbientSegmenter.silenceMs + 100)
        XCTAssertTrue(after.isEmpty, "a blip must not be reported as an utterance")
        XCTAssertFalse(segmenter.speaking, "and must not leave the detector wedged open")

        // A real utterance right after it still works.
        _ = feed(segmenter, amp: loud, ms: 1000)
        let real = feed(segmenter, amp: quiet, ms: AmbientSegmenter.silenceMs + 100)
        XCTAssertEqual(real.count, 1)
    }

    /// Hysteresis: audio between the two gates is still "talking", so a voice
    /// hovering on the boundary cannot flap open and shut every frame.
    func testAudioBetweenTheTwoGatesCountsAsStillTalking() {
        let segmenter = AmbientSegmenter()
        _ = feed(segmenter, amp: loud, ms: 600)
        // The gates in force, not the constants: they are floors under gates that
        // move with the room, so the band between them moves too.
        let between = (segmenter.openGate + segmenter.closeGate) / 2
        let events = feed(segmenter, amp: between, ms: AmbientSegmenter.silenceMs * 2)
        XCTAssertTrue(events.isEmpty, "the hysteresis band must not end the utterance")
        XCTAssertTrue(segmenter.speaking)
    }

    /// The cap is a CHUNKING rule, not a safety valve: a long monologue has to reach
    /// the transcript as readable rows while it is still being spoken.
    func testAnUnbrokenMonologueIsChunkedAtTheCap() {
        let segmenter = AmbientSegmenter()
        let events = feed(segmenter, amp: loud, ms: AmbientSegmenter.maxUtteranceMs + 500)
        let ends = events.filter { if case .ended = $0 { return true } else { return false } }
        XCTAssertGreaterThanOrEqual(ends.count, 1, "a continuous talker must still produce rows")
        XCTAssertTrue(segmenter.speaking || !ends.isEmpty)
    }

    // MARK: - A real room

    /// THE regression. Measured on live session `ea492bed`, every segment spanned
    /// 15.05–15.08 s — `maxUtteranceMs` — including one holding the two words
    /// "Can you hear me?". The gates were absolute, and `voicePeakAmplitude` is a
    /// PEAK over a frame, so a single sample above 0.0022 (−53 dBFS) kept a frame
    /// "voiced"; in a real room that never stops happening, `silenceRunMs` never
    /// reached `silenceMs`, and `close()` was only ever reached by the chunking
    /// cap. The server slices identification audio out of that span, so every
    /// voiceprint was ~15 s of room tone and nobody could be told apart.
    ///
    /// So: a short burst must produce a SHORT span.
    func testAShortBurstInANoisyRoomYieldsAShortSpanNotAFixedWindow() {
        // A room the OLD absolute gate would have called speech, forever.
        let room = AmbientSegmenter.silenceThreshold * 2.5
        XCTAssertGreaterThan(room, AmbientSegmenter.silenceThreshold,
                             "this test is only meaningful in a room above the old absolute gate")
        let speech = room * 6

        let segmenter = AmbientSegmenter()
        // Long enough for the floor to learn the room it is in.
        let settling = feed(segmenter, amp: room, ms: 3000)
        XCTAssertTrue(settling.isEmpty, "room tone must not open an utterance")

        _ = feed(segmenter, amp: speech, ms: 2000)
        let closing = feed(segmenter, amp: room, ms: AmbientSegmenter.silenceMs + 200)

        guard case .ended(let startMs, let endMs)? = closing.first else {
            return XCTFail("a two-second burst never ended — the silence gate never closed")
        }
        let span = endMs - startMs
        XCTAssertEqual(Double(span), 2000, accuracy: 400,
                       "a 2 s burst must be stamped as about 2 s, got \(span) ms")
        XCTAssertLessThan(span, AmbientSegmenter.maxUtteranceMs / 3,
                          "a span at the chunking cap means the silence gate never closed")
    }

    /// The floor must not learn from the very voice it is meant to hear. If an
    /// open utterance fed the estimate, the gate would climb until the talker's
    /// own speech read as silence.
    func testTheRoomFloorDoesNotLearnFromSpeech() {
        let segmenter = AmbientSegmenter()
        _ = feed(segmenter, amp: AmbientSegmenter.silenceThreshold * 2, ms: 2000)
        let learned = segmenter.roomFloor

        _ = feed(segmenter, amp: loud * 4, ms: 5000)
        XCTAssertTrue(segmenter.speaking)
        XCTAssertEqual(segmenter.roomFloor, learned, accuracy: 1e-12,
                       "an open utterance taught the floor its own speaker's level")
    }

    /// The hysteresis holds at EVERY room level, including past both ceilings —
    /// otherwise a loud room makes a voice on the boundary flap open and shut.
    func testTheClosingGateStaysBelowTheOpeningOneAtEveryRoomLevel() {
        for step in 0...400 {
            let floor = Double(step) * 0.001
            XCTAssertLessThan(AmbientSegmenter.closeGate(forFloor: floor),
                              AmbientSegmenter.openGate(forFloor: floor),
                              "the gates crossed at room floor \(floor)")
        }
    }

    /// A silent room falls back to exactly the absolute gates that used to be the
    /// whole rule, and a deafening one is clamped rather than climbing past the
    /// level speech lives at.
    func testTheGatesAreClampedBetweenTheirFloorsAndCeilings() {
        XCTAssertEqual(AmbientSegmenter.openGate(forFloor: 0),
                       AmbientSegmenter.speechThreshold, accuracy: 1e-12)
        XCTAssertEqual(AmbientSegmenter.closeGate(forFloor: 0),
                       AmbientSegmenter.silenceThreshold, accuracy: 1e-12)
        XCTAssertEqual(AmbientSegmenter.openGate(forFloor: 1),
                       AmbientSegmenter.maxSpeechGate, accuracy: 1e-12)
        XCTAssertEqual(AmbientSegmenter.closeGate(forFloor: 1),
                       AmbientSegmenter.maxSilenceGate, accuracy: 1e-12)
    }

    /// A quiet room must behave exactly as it did before the floor existed, or
    /// this fix has traded one broken environment for another.
    func testAQuietRoomStillUsesTheAbsoluteGates() {
        let segmenter = AmbientSegmenter()
        _ = feed(segmenter, amp: 0.0002, ms: 3000)
        XCTAssertEqual(segmenter.openGate, AmbientSegmenter.speechThreshold, accuracy: 1e-12)
        XCTAssertEqual(segmenter.closeGate, AmbientSegmenter.silenceThreshold, accuracy: 1e-12)
    }

    // MARK: - The audio clock

    /// Timestamps must come from summed frame durations. A wall clock drifts against
    /// the samples and is outright wrong for anything replayed from the spool.
    func testTheClockAdvancesWithAudioNotWallTime() {
        let segmenter = AmbientSegmenter()
        _ = feed(segmenter, amp: quiet, ms: 1000)
        XCTAssertEqual(segmenter.elapsedMs, 1000)
        _ = feed(segmenter, amp: loud, ms: 500)
        XCTAssertEqual(segmenter.elapsedMs, 1500)
    }

    func testAZeroLengthFrameChangesNothing() {
        let segmenter = AmbientSegmenter()
        XCTAssertEqual(segmenter.update(loud, 0), .none)
        XCTAssertEqual(segmenter.elapsedMs, 0)
        XCTAssertFalse(segmenter.speaking)
    }

    /// Resetting an utterance must NOT rewind the session clock, or later timestamps
    /// collide with earlier ones.
    func testResetKeepsTheSessionClockRunning() {
        let segmenter = AmbientSegmenter()
        _ = feed(segmenter, amp: loud, ms: 800)
        let elapsed = segmenter.elapsedMs
        segmenter.reset()
        XCTAssertEqual(segmenter.elapsedMs, elapsed)
        XCTAssertFalse(segmenter.speaking)
    }

    /// A pause (a call, Siri) is time we did not hear. Winding the clock over it
    /// keeps everything after it lined up with wall time.
    func testSkipWindsTheClockOverAStretchWeDidNotHear() {
        let segmenter = AmbientSegmenter()
        _ = feed(segmenter, amp: quiet, ms: 100)
        segmenter.skip(ms: 30_000)
        XCTAssertEqual(segmenter.elapsedMs, 30_100)
        segmenter.skip(ms: -5)
        XCTAssertEqual(segmenter.elapsedMs, 30_100, "a negative skip must not rewind the clock")
    }

    // MARK: - Flush

    /// Stopping must not throw away the last thing anybody said.
    func testFlushReportsAnUtteranceThatWasStillOpen() {
        let segmenter = AmbientSegmenter()
        _ = feed(segmenter, amp: loud, ms: 1000)
        guard case .ended(let startMs, let endMs)? = segmenter.flush() else {
            return XCTFail("a part-spoken utterance must survive a stop")
        }
        XCTAssertLessThan(startMs, endMs)
        XCTAssertFalse(segmenter.speaking)
    }

    func testFlushReportsNothingWhenThereWasNothingWorthReporting() {
        let segmenter = AmbientSegmenter()
        XCTAssertNil(segmenter.flush())
        _ = feed(segmenter, amp: loud, ms: AmbientSegmenter.minUtteranceMs - 100)
        XCTAssertNil(segmenter.flush(), "a blip must not be flushed out as a row")
    }

    // MARK: - When the recogniser, not the level, knows where speech is

    /// A room whose noise sits above the opening gate holds a window open with no
    /// words in it. Cutting that window at the cap is what split a sentence that
    /// happened to start just before the boundary, so the caller can hold the
    /// cap off until words have actually been heard.
    func testTheCapCanBeHeldOffWhileNoWordsHaveBeenHeard() {
        let segmenter = AmbientSegmenter()
        var events: [AmbientSegmentEvent] = []
        for _ in 0..<((AmbientSegmenter.maxUtteranceMs + 5000) / dt) {
            let event = segmenter.update(loud, dt, capArmed: false)
            if event != .none { events.append(event) }
        }
        XCTAssertEqual(events.count, 1, "opened once and never cut")
        guard case .started = events.first else { return XCTFail("expected the opening") }
        XCTAssertTrue(segmenter.speaking)
    }

    /// The words are the evidence. An utterance the recogniser heard words in is
    /// ended on the caller's say-so, however little of it the level gate counted
    /// as voiced — a quiet speaker in a quiet room is exactly that case.
    func testEndingOnTheRecognisersWordReportsTheUtterance() {
        let segmenter = AmbientSegmenter()
        XCTAssertNil(segmenter.endUtterance(), "nothing open, nothing to end")
        _ = feed(segmenter, amp: loud, ms: AmbientSegmenter.minUtteranceMs / 2)
        XCTAssertTrue(segmenter.speaking)
        guard case .ended(let startMs, let endMs)? = segmenter.endUtterance() else {
            return XCTFail("an utterance with words in it must be reported")
        }
        XCTAssertLessThan(startMs, endMs)
        XCTAssertFalse(segmenter.speaking)
    }
}

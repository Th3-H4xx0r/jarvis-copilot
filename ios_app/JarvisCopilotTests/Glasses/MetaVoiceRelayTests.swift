import XCTest
@testable import JarvisCopilot

private func snap(_ state: VoiceState, heard: String = "", answer: String = "",
                  c: Int = 0, q: Int = 0, i: Int = 0, error: String? = nil) -> MetaVoiceSnapshot {
    MetaVoiceSnapshot(state: state, heard: heard, answer: answer, thinking: state == .thinking,
                      completionGeneration: c, questionGeneration: q, interruptionGeneration: i, error: error)
}

/// A whole realtime turn as VoiceStore would show it: baseline, connect, partial, final, answer
/// streaming while speaking, turn ended while still speaking, then back to listening.
@MainActor
private func scriptedTurn(question: String = "what's seven times eight",
                          answer: String = "7 times 8 is 56.") -> [MetaVoiceSnapshot] {
    [
        .idle,
        snap(.connecting),
        snap(.listening, heard: "what's"),
        snap(.thinking, heard: question, q: 1),
        snap(.speaking, heard: question, answer: "7 times", q: 1),
        snap(.speaking, heard: question, answer: answer, c: 1, q: 1),
        snap(.listening, heard: question, answer: answer, c: 1, q: 1),
    ]
}

/// The pure voice→glasses mirroring rules.
final class MetaVoiceRelayTests: XCTestCase {

    func testTranscriptPartialThenFinal() {
        var relay = MetaVoiceRelay(baseline: .idle)
        XCTAssertEqual(relay.step(snap(.listening, heard: "what's")).frames,
                       [.showTranscript(text: "what's", isFinal: false)])
        XCTAssertEqual(relay.step(snap(.listening, heard: "what's seven")).frames,
                       [.showTranscript(text: "what's seven", isFinal: false)])
        XCTAssertEqual(relay.step(snap(.thinking, heard: "what's seven times eight", q: 1)).frames,
                       [.showTranscript(text: "what's seven times eight", isFinal: true)])
        XCTAssertEqual(relay.step(snap(.thinking, heard: "what's seven times eight", q: 1)).frames, [],
                       "nothing new, nothing sent")
    }

    func testAnswerGrowthThenFinishAfterPlaybackDrains() {
        var relay = MetaVoiceRelay(baseline: .idle)
        _ = relay.step(snap(.listening, heard: "q"))
        _ = relay.step(snap(.thinking, heard: "q", q: 1))
        let speaking = relay.step(snap(.speaking, heard: "q", answer: "7 times", q: 1))
        XCTAssertEqual(speaking.frames, [.showAnswer(text: "7 times", isFinal: false), .setSpeaking(true)])

        let endedWhileSpeaking = relay.step(snap(.speaking, heard: "q", answer: "7 times 8 is 56.", c: 1, q: 1))
        XCTAssertEqual(endedWhileSpeaking.frames, [.showAnswer(text: "7 times 8 is 56.", isFinal: false)])
        XCTAssertEqual(endedWhileSpeaking.outcome, .running, "not finished while the answer is still playing")

        let drained = relay.step(snap(.listening, heard: "q", answer: "7 times 8 is 56.", c: 1, q: 1))
        XCTAssertEqual(drained.frames, [.setSpeaking(false), .showAnswer(text: "7 times 8 is 56.", isFinal: true)])
        XCTAssertEqual(drained.outcome, .finished)
        XCTAssertEqual(relay.step(snap(.listening, c: 1, q: 1)), MetaVoiceRelay.Step(frames: [], outcome: .finished),
                       "settled: later snapshots change nothing")
    }

    func testIgnoresAnswerBeforeQuestion() {
        // Text left in VoiceStore from an earlier chat must not show up as this turn's.
        var relay = MetaVoiceRelay(baseline: snap(.idle, heard: "old question", answer: "old answer"))
        XCTAssertEqual(relay.step(snap(.listening, heard: "old question", answer: "old answer")).frames, [])
        XCTAssertEqual(relay.step(snap(.thinking, heard: "new question", answer: "old answer", q: 1)).frames,
                       [.showTranscript(text: "new question", isFinal: true)])
        XCTAssertEqual(relay.step(snap(.thinking, heard: "new question", answer: "old answer", q: 1)).frames, [])
        XCTAssertEqual(relay.step(snap(.speaking, heard: "new question", answer: "Fresh", q: 1)).frames,
                       [.showAnswer(text: "Fresh", isFinal: false), .setSpeaking(true)])
    }

    func testNoSpeechTurnFinishesWithoutAnswer() {
        var relay = MetaVoiceRelay(baseline: snap(.idle, answer: "old answer"))
        _ = relay.step(snap(.listening, answer: "old answer"))
        let step = relay.step(snap(.listening, answer: "old answer", c: 1))
        XCTAssertEqual(step.outcome, .finished)
        XCTAssertFalse(step.frames.contains { if case .showAnswer = $0 { return true }; return false })
    }

    func testInterruptionResetsQuestion() {
        var relay = MetaVoiceRelay(baseline: .idle)
        _ = relay.step(snap(.thinking, heard: "first", q: 1))
        _ = relay.step(snap(.speaking, heard: "first", answer: "A1", q: 1))
        // Barge-in: a new utterance starts over; the old answer is not this question's.
        XCTAssertEqual(relay.step(snap(.listening, heard: "stop", answer: "A1", q: 1, i: 1)).frames,
                       [.showTranscript(text: "stop", isFinal: false), .setSpeaking(false)])
        XCTAssertEqual(relay.step(snap(.thinking, heard: "stop that", answer: "A1", q: 2, i: 1)).frames,
                       [.showTranscript(text: "stop that", isFinal: true)])
        XCTAssertEqual(relay.step(snap(.speaking, heard: "stop that", answer: "Okay.", q: 2, i: 1)).frames,
                       [.showAnswer(text: "Okay.", isFinal: false), .setSpeaking(true)])
    }

    func testErrorFails() {
        var relay = MetaVoiceRelay(baseline: .idle)
        XCTAssertEqual(relay.step(snap(.connecting)).outcome, .running)
        XCTAssertEqual(relay.step(snap(.error, error: "Mic blocked")).outcome, .failed("Mic blocked"))
    }

    func testIdleAfterActiveWithoutCompletionFails() {
        var relay = MetaVoiceRelay(baseline: .idle)
        XCTAssertEqual(relay.step(.idle).outcome, .running, "idle before starting is just not started yet")
        _ = relay.step(snap(.listening))
        XCTAssertEqual(relay.step(.idle).outcome, .failed("Jarvis voice stopped"))
    }
}

/// The session's watch loop: VoiceStore's turn mirrored to the glasses, then closed.
@MainActor
final class MetaGlassesSessionRelayTests: XCTestCase {

    private func waitFor(_ timeout: Duration = .seconds(2), _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now > deadline { XCTFail("timed out waiting"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testScriptedVoiceTurnRelaysFramesAndCloses() async throws {
        let transport = SimulatedGlassesTransport()
        let voice = FakeVoiceTurnController()
        voice.script = scriptedTurn()
        let session = MetaGlassesSession(transport: transport, voice: voice)
        session.pollInterval = .milliseconds(5)
        var events: [MetaSessionEvent] = []
        session.onEvent = { events.append($0) }

        try await session.start()
        transport.scriptWake()
        try await waitFor { events.contains { if case .ended = $0 { return true }; return false } }

        XCTAssertTrue(events.contains(.heard("what's seven times eight")))
        XCTAssertTrue(events.contains(.answer("7 times 8 is 56.")))
        XCTAssertTrue(events.contains(.speaking(true)))
        XCTAssertTrue(events.contains(.speaking(false)))
        XCTAssertTrue(events.contains(.closed))
        XCTAssertEqual(events.last, .ended(.finished))
        XCTAssertTrue(transport.sentFrames.contains(.showTranscript(text: "what's seven times eight", isFinal: true)))
        XCTAssertTrue(transport.sentFrames.contains(.showAnswer(text: "7 times 8 is 56.", isFinal: true)))
        XCTAssertEqual(transport.sentFrames.last, .closeAssistant)
        XCTAssertFalse(session.turnActive)
        XCTAssertEqual(session.lastOutcome, .finished)
        XCTAssertGreaterThanOrEqual(voice.cleared, 1, "glasses input released when the turn ends")
    }

    func testVoiceThatNeverStartsFailsFast() async throws {
        let transport = SimulatedGlassesTransport()
        let voice = FakeVoiceTurnController()          // stays idle: mic refused / engine down
        let session = MetaGlassesSession(transport: transport, voice: voice)
        session.pollInterval = .milliseconds(5)
        session.startTimeout = .milliseconds(50)
        var outcome: MetaVoiceRelay.Outcome?
        session.onEvent = { if case .ended(let o) = $0 { outcome = o } }

        try await session.start()
        transport.scriptWake()
        try await waitFor(.seconds(1)) { outcome != nil }
        guard case .failed(let why)? = outcome else { return XCTFail("expected a failure, got \(String(describing: outcome))") }
        XCTAssertTrue(why.contains("didn't start"), why)
        XCTAssertFalse(session.turnActive)
    }
}

@MainActor
private final class FakePromptVoice: MetaPromptSpeaking {
    func pcm16k(for text: String) async throws -> Data { Data(count: 3_200) }
}

/// The sim page's runner, against a fake voice engine.
@MainActor
final class MetaGlassesSimRunnerTests: XCTestCase {

    private func makeRunner(_ voice: FakeVoiceTurnController) -> MetaGlassesSimRunner {
        MetaGlassesSimRunner(voice: voice, speech: FakePromptVoice(), frameInterval: .milliseconds(1),
                             sessionTuning: { $0.pollInterval = .milliseconds(5) })
    }

    func testRunProducesHeardAnswerClosedRows() async throws {
        let voice = FakeVoiceTurnController()
        voice.script = scriptedTurn()
        let runner = makeRunner(voice)
        await runner.run()

        XCTAssertEqual(runner.phase, .done)
        let titles = runner.rows.map(\.title)
        for expected in ["Link ready", "Wake", "Glasses mic", "Heard", "Jarvis", "Speaking", "Assistant closed"] {
            XCTAssertTrue(titles.contains(expected), "missing row \(expected) in \(titles)")
        }
        XCTAssertEqual(runner.rows.first { $0.title == "Jarvis" }?.detail, "7 times 8 is 56.")
        XCTAssertEqual(titles.filter { $0 == "Heard" }.count, 1, "a refined transcript updates the row")
        XCTAssertNotNil(runner.wakeToAnswer)
        XCTAssertFalse(voice.capturedAudio.isEmpty, "the voiced prompt reached the voice engine as glasses audio")
        XCTAssertGreaterThanOrEqual(voice.cleared, 1)
    }

    func testRunRefusesWhileVoiceBusy() async {
        let voice = FakeVoiceTurnController()
        voice.current = snap(.listening)                 // a voice chat is already running
        let runner = makeRunner(voice)
        await runner.run()
        XCTAssertEqual(runner.phase, .failed(MetaGlassesSimRunner.busyMessage))
        XCTAssertEqual(voice.beginTurnCalls, 0, "never cuts into a live voice chat")
        XCTAssertEqual(voice.useExternalInputCalls, 0)
    }

    func testStopReleasesInputAndStopsStreaming() async throws {
        let voice = FakeVoiceTurnController()
        voice.script = [.idle, snap(.listening)]           // listens forever
        let runner = makeRunner(voice)
        let run = Task { await runner.run() }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while voice.capturedAudio.count < 5 {
            if clock.now > deadline { return XCTFail("the turn never started streaming") }
            try await Task.sleep(for: .milliseconds(5))
        }
        await runner.stop()
        await run.value

        XCTAssertEqual(runner.phase, .idle)
        XCTAssertEqual(runner.rows.last?.title, "Stopped")
        XCTAssertGreaterThanOrEqual(voice.cleared, 1, "glasses input released")
        let frames = voice.capturedAudio.count
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(voice.capturedAudio.count, frames, "no silence keeps streaming after Stop")
    }

    func testPromptVoiceProduces16kPCM() async throws {
        let pcm = try await MetaPromptVoice().pcm16k(for: "hello there, this is a test")
        try XCTSkipIf(pcm.isEmpty, "the simulator's speech synthesizer produced nothing")
        XCTAssertGreaterThanOrEqual(pcm.count, 9_600, "at least 0.3 s of 16 kHz mono PCM16")
        XCTAssertEqual(pcm.count % 2, 0, "whole Int16 samples")
    }
}

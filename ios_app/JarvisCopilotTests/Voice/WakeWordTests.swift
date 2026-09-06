import XCTest
@testable import JarvisCopilot

/// "Hey Jarvis": the listener's restart loop, and — the bug this file exists for —
/// that the wake word still works after the FIRST hit.
///
/// `onWake` marks the service suppressed so it can't fight the turn for the mic.
/// Nothing used to clear that flag, so the wake word died for the rest of the
/// launch. `WakeWordController` is the piece that gives the mic back.
@MainActor
final class WakeWordTests: XCTestCase {

    /// Explicitly `@MainActor` — a nested type does NOT inherit the test class's
    /// isolation, and every mock it builds is main-actor bound.
    @MainActor
    private final class Rig {
        let input: MockAudioInput
        let recognizer: MockSpeechRecognizing
        let clock: TestVoiceClock

        init() {
            input = MockAudioInput()
            recognizer = MockSpeechRecognizing()
            clock = TestVoiceClock()
        }
    }

    private func makeListener(_ rig: Rig,
                              phrase: String = WakeWordListener.defaultPhrase,
                              onWake: @escaping () -> Void = {}) -> WakeWordListener {
        WakeWordListener(input: rig.input, recognizer: rig.recognizer, clock: rig.clock,
                         phrase: phrase, onWake: onWake)
    }

    private func makeService(_ rig: Rig) -> WakeService {
        WakeService(input: rig.input, recognizer: rig.recognizer, clock: rig.clock,
                    settings: VoiceSettings(store: MemoryKeyValueStore()))
    }

    // MARK: - WakeWordListener (test-gaps 5)

    func testStartTakesTheMicAndArmsARecognizer() async {
        let rig = Rig()
        let listener = makeListener(rig)
        await listener.start()

        XCTAssertTrue(listener.isRunning)
        XCTAssertEqual(rig.recognizer.startCount, 1)
        XCTAssertEqual(rig.recognizer.promptFlags, [true], "the user opted in, so a sheet is expected")
        XCTAssertEqual(rig.input.startedRates, [WakeWordListener.sampleRate])
        XCTAssertNotNil(rig.input.onFrame)
    }

    func testMicFramesReachTheLiveRecognizer() async {
        let rig = Rig()
        let listener = makeListener(rig)
        await listener.start()
        rig.input.emit(amplitude: 0.4, ms: 20, sampleRate: WakeWordListener.sampleRate)

        XCTAssertGreaterThan(rig.recognizer.latest?.fedBytes ?? 0, 0)
        XCTAssertTrue(listener.isRunning)
    }

    /// Apple ends a recognition session after a pause; the loop must open a fresh
    /// one or the wake word goes deaf after the first silence.
    func testARecognizerThatEndedItselfIsReplacedAfterTheRestartDelay() async {
        let rig = Rig()
        let listener = makeListener(rig)
        await listener.start()
        rig.recognizer.latest?.endItself()

        rig.clock.advance(ms: WakeWordListener.restartDelayMs + 1)
        await settleVoiceTasks()

        XCTAssertEqual(rig.recognizer.startCount, 2)
        XCTAssertTrue(listener.isRunning)
    }

    /// …but a HEALTHY session is never replaced: restarting mid-utterance would
    /// throw away what it has already heard.
    func testARunningRecognizerIsNotReplaced() async {
        let rig = Rig()
        let listener = makeListener(rig)
        await listener.start()

        rig.clock.advance(ms: WakeWordListener.restartDelayMs * 4)
        await settleVoiceTasks()

        XCTAssertEqual(rig.recognizer.startCount, 1)
    }

    func testTheWakePhraseMatchesCaseInsensitivelyAndMidSentence() async {
        let rig = Rig()
        var wakes = 0
        let listener = makeListener(rig) { wakes += 1 }
        await listener.start()

        rig.recognizer.latest?.emitPartial("um, hey JARVIS are you there")
        await settleVoiceTasks()

        XCTAssertEqual(wakes, 1)
        XCTAssertFalse(listener.isRunning, "the listener hands the mic to the turn")
        XCTAssertNil(rig.input.onFrame)
        XCTAssertGreaterThan(rig.input.stopCount, 0)
    }

    func testUnrelatedSpeechDoesNotWake() async {
        let rig = Rig()
        var wakes = 0
        let listener = makeListener(rig) { wakes += 1 }
        await listener.start()

        rig.recognizer.latest?.emitPartial("what a lovely day")
        await settleVoiceTasks()

        XCTAssertEqual(wakes, 0)
        XCTAssertTrue(listener.isRunning)
    }

    func testStopReleasesTheMicTheFrameHookAndTheRestartTimer() async {
        let rig = Rig()
        let listener = makeListener(rig)
        await listener.start()
        await listener.stop()

        XCTAssertFalse(listener.isRunning)
        XCTAssertNil(rig.input.onFrame, "one mic tap, one onFrame — VoiceStore owns the other")
        XCTAssertGreaterThan(rig.input.stopCount, 0)
        XCTAssertEqual(rig.clock.pendingTimers, 0)
        XCTAssertGreaterThan(rig.recognizer.latest?.cancelCount ?? 0, 0)
    }

    func testADeviceWithNoOnDeviceRecognizerDoesNotSpin() async {
        let rig = Rig()
        rig.recognizer.isAvailable = false
        let listener = makeListener(rig)
        await listener.start()

        XCTAssertFalse(listener.isRunning)
        XCTAssertEqual(rig.clock.pendingTimers, 0, "no restart loop on a device that can't listen")
        XCTAssertTrue(rig.input.startedRates.isEmpty)
    }

    func testARefusedMicNeverStarts() async {
        let rig = Rig()
        rig.input.permission = false
        let listener = makeListener(rig)
        await listener.start()

        XCTAssertFalse(listener.isRunning)
        XCTAssertEqual(rig.recognizer.startCount, 0)
    }

    // MARK: - WakeService: the mic handover (test-gaps 1)

    func testASecondWakeWorksOnceTheTurnGivesTheMicBack() async {
        let rig = Rig()
        let service = makeService(rig)
        var wakes = 0
        service.onWake = { wakes += 1 }

        let enabled = await service.setEnabled(true)
        XCTAssertTrue(enabled)
        XCTAssertEqual(rig.recognizer.startCount, 1)

        rig.recognizer.latest?.emitPartial("hey jarvis")
        await settleVoiceTasks()
        XCTAssertEqual(wakes, 1)

        // The turn takes the mic…
        await service.suppress()
        XCTAssertNil(rig.input.onFrame)
        // …and gives it back. Nothing used to clear `suppressed`, which killed
        // the wake word for the rest of the launch.
        await service.resume()
        XCTAssertEqual(rig.recognizer.startCount, 2, "resume() must clear `suppressed`")

        rig.recognizer.latest?.emitPartial("jarvis, what's the time")
        await settleVoiceTasks()
        XCTAssertEqual(wakes, 2, "the wake word survives its own first hit")
    }

    func testTheWakeWordSurvivesABackgroundForegroundRoundTrip() async {
        let rig = Rig()
        let service = makeService(rig)
        var wakes = 0
        service.onWake = { wakes += 1 }
        await service.setEnabled(true)

        rig.recognizer.latest?.emitPartial("hey jarvis")
        await settleVoiceTasks()
        await service.resume() // the turn ended

        await service.setForeground(false)
        XCTAssertNil(rig.input.onFrame, "iOS suspends the mic in the background anyway")
        await service.setForeground(true)

        XCTAssertEqual(rig.recognizer.startCount, 3)
        rig.recognizer.latest?.emitPartial("jarvis")
        await settleVoiceTasks()
        XCTAssertEqual(wakes, 2)
    }

    func testAWakeWhileSuppressedIsNotRestarted() async {
        let rig = Rig()
        let service = makeService(rig)
        await service.setEnabled(true)
        await service.suppress()

        // A foreground event while a turn owns the mic must NOT re-arm us.
        await service.setForeground(true)
        XCTAssertEqual(rig.recognizer.startCount, 1)
    }

    func testTurningTheWakeWordOffStopsListening() async {
        let rig = Rig()
        let service = makeService(rig)
        await service.setEnabled(true)
        let off = await service.setEnabled(false)

        XCTAssertTrue(off)
        XCTAssertFalse(service.enabled)
        XCTAssertNil(rig.input.onFrame)
        XCTAssertGreaterThan(rig.input.stopCount, 0)
    }

    func testAWakeWordWithNoMicPermissionStaysOff() async {
        let rig = Rig()
        rig.input.permission = false
        let service = makeService(rig)
        let enabled = await service.setEnabled(true)

        XCTAssertFalse(enabled)
        XCTAssertFalse(service.enabled)
        XCTAssertEqual(rig.recognizer.startCount, 0)
    }
}

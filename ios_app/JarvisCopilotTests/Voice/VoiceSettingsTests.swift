import XCTest
@testable import JarvisCopilot

/// Engine / voice / mode / wake-word persistence.
@MainActor
final class VoiceSettingsTests: XCTestCase {

    func testDefaultsWhenNothingWasEverSaved() {
        let settings = VoiceSettings(store: MemoryKeyValueStore())
        XCTAssertNil(settings.engine, "nil = let the server use its own default")
        XCTAssertNil(settings.voice)
        XCTAssertEqual(settings.mode, .realtime)
        XCTAssertFalse(settings.wakeWordEnabled, "battery-heavy, so opt-in")
    }

    func testTheEngineSelectionSurvivesARelaunch() {
        let store = MemoryKeyValueStore()
        let first = VoiceSettings(store: store)
        first.engine = "elevenlabs"
        first.voice = "Rachel"

        XCTAssertEqual(store.string(VoiceSettings.engineKey), "elevenlabs")
        XCTAssertEqual(store.string(VoiceSettings.voiceKey), "Rachel")

        let relaunched = VoiceSettings(store: store)
        XCTAssertEqual(relaunched.engine, "elevenlabs")
        XCTAssertEqual(relaunched.voice, "Rachel")
    }

    func testTheModeSurvivesARelaunch() {
        let store = MemoryKeyValueStore()
        VoiceSettings(store: store).mode = .quality
        XCTAssertEqual(VoiceSettings(store: store).mode, .quality)
    }

    func testWakeWordOptInSurvivesARelaunch() {
        let store = MemoryKeyValueStore()
        VoiceSettings(store: store).wakeWordEnabled = true
        XCTAssertTrue(VoiceSettings(store: store).wakeWordEnabled)
    }

    func testAnEmptyOrNilSelectionIsErasedRatherThanStoredBlank() {
        let store = MemoryKeyValueStore()
        let settings = VoiceSettings(store: store)
        settings.engine = "edge"
        settings.engine = ""
        XCTAssertNil(settings.engine)
        XCTAssertNil(store.string(VoiceSettings.engineKey))

        settings.voice = "Ryan"
        settings.voice = nil
        XCTAssertNil(store.string(VoiceSettings.voiceKey))
    }

    func testAnUnknownStoredModeFallsBackToRealtime() {
        let store = MemoryKeyValueStore([VoiceSettings.modeKey: "telepathy"])
        XCTAssertEqual(VoiceSettings(store: store).mode, .realtime)
    }

    // MARK: - selectEngine

    func testSwitchingEngineDropsTheStaleVoice() {
        let settings = VoiceSettings(store: MemoryKeyValueStore())
        settings.selectEngine("elevenlabs", voice: "Rachel")
        XCTAssertEqual(settings.voice, "Rachel")

        // Voice ids are engine-specific: keeping ElevenLabs' voice on Edge would 400.
        settings.selectEngine("edge")
        XCTAssertEqual(settings.engine, "edge")
        XCTAssertNil(settings.voice)
    }

    func testReSelectingTheSameEngineKeepsTheVoice() {
        let settings = VoiceSettings(store: MemoryKeyValueStore())
        settings.selectEngine("edge", voice: "en-GB-RyanNeural")
        settings.selectEngine("edge")
        XCTAssertEqual(settings.voice, "en-GB-RyanNeural")
    }

    func testClearingTheEngineClearsTheVoice() {
        let settings = VoiceSettings(store: MemoryKeyValueStore())
        settings.selectEngine("edge", voice: "en-GB-RyanNeural")
        settings.selectEngine(nil)
        XCTAssertNil(settings.engine)
        XCTAssertNil(settings.voice)
    }

    func testKeysKeepTheirFlutterPrefixesSoAnUpgradeKeepsTheChoices() {
        XCTAssertEqual(VoiceSettings.engineKey, "jc_voice_engine")
        XCTAssertEqual(VoiceSettings.voiceKey, "jc_voice_voice")
        XCTAssertEqual(VoiceSettings.modeKey, "jc_voice_mode")
        XCTAssertEqual(VoiceSettings.wakeWordKey, "jc_voice_wake_word")
        XCTAssertEqual(VoiceSettings.pendingVoiceKey, "jc_pending_voice")
    }
}

/// The Dynamic Island snapshot: dedupe, throttle, and the two line builders.
@MainActor
final class VoiceLiveActivityTests: XCTestCase {

    private func make() -> (VoiceLiveActivityThrottle, TestVoiceClock, Box) {
        let clock = TestVoiceClock()
        let throttle = VoiceLiveActivityThrottle(clock: clock)
        let box = Box()
        throttle.onPush = { box.pushes.append($0) }
        return (throttle, clock, box)
    }

    private final class Box { var pushes: [VoiceLiveActivitySnapshot] = [] }

    private func snapshot(_ state: String, _ transcript: String = "",
                          _ activity: String = "") -> VoiceLiveActivitySnapshot {
        VoiceLiveActivitySnapshot(state: state, transcript: transcript,
                                  activity: activity, connected: true, devices: [])
    }

    func testTheFirstOfferPushesImmediately() {
        let (throttle, _, box) = make()
        throttle.offer(snapshot("listening"), terminal: false)
        XCTAssertEqual(box.pushes.count, 1)
    }

    func testIdenticalContentIsNotPushedAgain() {
        let (throttle, clock, box) = make()
        throttle.offer(snapshot("listening"), terminal: false)
        clock.advance(ms: 2000)
        throttle.offer(snapshot("listening"), terminal: false)
        XCTAssertEqual(box.pushes.count, 1, "don't churn the activity")
    }

    func testRapidChangesAreThrottledToTheTrailingEdge() {
        let (throttle, clock, box) = make()
        throttle.offer(snapshot("listening"), terminal: false)
        throttle.offer(snapshot("thinking"), terminal: false)
        throttle.offer(snapshot("thinking", "hello"), terminal: false)
        XCTAssertEqual(box.pushes.count, 1, "still inside the window")

        clock.advance(ms: VoiceLiveActivityThrottle.windowMs)
        XCTAssertEqual(box.pushes.count, 2)
        XCTAssertEqual(box.pushes.last?.transcript, "hello",
                       "the LATEST state is sent, not the one that was queued first")
    }

    func testTerminalStatesBypassTheThrottle() {
        let (throttle, _, box) = make()
        throttle.offer(snapshot("listening"), terminal: false)
        // Otherwise the island sticks on "Listening" after Stop, because the
        // final "idle" update gets dropped.
        throttle.offer(snapshot("idle"), terminal: true)
        XCTAssertEqual(box.pushes.map(\.state), ["listening", "idle"])
    }

    func testCancelDropsAPendingTrailingPush() {
        let (throttle, clock, box) = make()
        throttle.offer(snapshot("listening"), terminal: false)
        throttle.offer(snapshot("thinking"), terminal: false)
        throttle.cancel()
        clock.advance(ms: 5000)
        XCTAssertEqual(box.pushes.count, 1)
    }

    func testReOfferingTheSentContentCancelsAPendingPush() {
        let (throttle, clock, box) = make()
        throttle.offer(snapshot("listening"), terminal: false)
        throttle.offer(snapshot("thinking"), terminal: false) // queued
        throttle.offer(snapshot("listening"), terminal: false) // back to what's on screen
        clock.advance(ms: 5000)
        XCTAssertEqual(box.pushes.count, 1)
    }

    // MARK: - Line builders

    func testFirstLineTakesOneLineAndCapsItsLength() {
        XCTAssertEqual(voiceFirstLine("  hello there\nand more  "), "hello there")
        XCTAssertEqual(voiceFirstLine(""), "")
        let long = String(repeating: "a", count: 200)
        let capped = voiceFirstLine(long)
        XCTAssertEqual(capped.count, VoiceLiveActivityThrottle.lineLimit + 1)
        XCTAssertTrue(capped.hasSuffix("…"))
    }

    func testOutputLinePrefersTheErrorThenTheToolThenTheReply() {
        XCTAssertEqual(voiceOutputLine(error: "boom", toolStatus: "Running x",
                                       state: .speaking, assistantText: "Hi"), "boom")
        XCTAssertEqual(voiceOutputLine(error: nil, toolStatus: "Running x",
                                       state: .speaking, assistantText: "Hi"), "Running x")
        XCTAssertEqual(voiceOutputLine(error: nil, toolStatus: nil,
                                       state: .speaking, assistantText: "Hi\nthere"), "Hi")
    }

    func testOutputLineIsEmptyWhenTheStateLabelAlreadySaysIt() {
        // "Listening"/"Thinking" is the state label's job.
        XCTAssertEqual(voiceOutputLine(error: nil, toolStatus: nil,
                                       state: .listening, assistantText: "Hi"), "")
        XCTAssertEqual(voiceOutputLine(error: nil, toolStatus: "",
                                       state: .thinking, assistantText: "Hi"), "")
        XCTAssertEqual(voiceOutputLine(error: "", toolStatus: nil,
                                       state: .speaking, assistantText: ""), "")
    }
}

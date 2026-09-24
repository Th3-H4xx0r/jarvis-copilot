import XCTest
@testable import JarvisCopilot

/// Persistence for the Live choices, and for the Voice ⇄ Live mode switch.
@MainActor
final class LiveSettingsTests: XCTestCase {

    // MARK: - The mode switch

    /// An update must not move an existing install onto an always-listening screen
    /// it never asked for.
    func testLiveModeIsOffOnAFreshInstall() {
        XCTAssertFalse(VoiceSettings(store: MemoryKeyValueStore()).liveMode)
    }

    func testLiveModeSurvivesARelaunch() {
        let store = MemoryKeyValueStore()
        VoiceSettings(store: store).liveMode = true
        XCTAssertTrue(VoiceSettings(store: store).liveMode)

        VoiceSettings(store: store).liveMode = false
        XCTAssertFalse(VoiceSettings(store: store).liveMode,
                       "switching back must persist too, not just fall through to the default")
    }

    /// It is stored under its own key, beside the existing voice choices — not
    /// entangled with them.
    func testLiveModeUsesItsOwnKeyAndLeavesTheOtherVoiceChoicesAlone() {
        let store = MemoryKeyValueStore()
        let settings = VoiceSettings(store: store)
        settings.transcription = .onDevice
        settings.mode = .quality
        settings.liveMode = true

        XCTAssertEqual(store.bool(VoiceSettings.liveModeKey), true)
        let reloaded = VoiceSettings(store: store)
        XCTAssertEqual(reloaded.transcription, .onDevice)
        XCTAssertEqual(reloaded.mode, .quality)
        XCTAssertTrue(reloaded.liveMode)
    }

    // MARK: - Device-local Live settings

    func testDefaultsAreAutomaticMicAndRecordingOn() {
        let settings = LiveSettings(store: MemoryKeyValueStore())
        XCTAssertEqual(settings.captureSourceID, LiveCaptureSource.automaticID)
        XCTAssertTrue(settings.captureHere,
                      "a user who opened Live mode on their phone meant to record with it")
    }

    func testCaptureChoicesSurviveARelaunch() {
        let store = MemoryKeyValueStore()
        let first = LiveSettings(store: store)
        first.captureSourceID = "route:abc-123"
        first.captureHere = false

        let second = LiveSettings(store: store)
        XCTAssertEqual(second.captureSourceID, "route:abc-123")
        XCTAssertFalse(second.captureHere)
    }

    func testAnEmptySourceIDFallsBackToAutomatic() {
        let settings = LiveSettings(store: MemoryKeyValueStore())
        settings.captureSourceID = ""
        XCTAssertEqual(settings.captureSourceID, LiveCaptureSource.automaticID)
    }

    // MARK: - The resume cursor

    func testTheCursorIsRememberedAcrossRelaunches() {
        let store = MemoryKeyValueStore()
        LiveSettings(store: store).rememberCursor(sessionID: "L1", seq: 4417)

        let reloaded = LiveSettings(store: store)
        XCTAssertEqual(reloaded.lastSessionID, "L1")
        XCTAssertEqual(reloaded.lastSeq, 4417)
    }

    /// An out-of-order frame must not rewind the cursor — resuming from a lower seq
    /// would replay rows already on screen.
    func testTheCursorOnlyEverMovesForward() {
        let settings = LiveSettings(store: MemoryKeyValueStore())
        settings.rememberCursor(sessionID: "L1", seq: 100)
        settings.rememberCursor(sessionID: "L1", seq: 40)
        XCTAssertEqual(settings.lastSeq, 100)
        settings.rememberCursor(sessionID: "L1", seq: 101)
        XCTAssertEqual(settings.lastSeq, 101)
    }

    /// A fresh conversation must not inherit the last one's cursor, or it would ask
    /// the server to skip rows that do not exist and open with a hole in it.
    func testANewSessionRestartsTheCursor() {
        let settings = LiveSettings(store: MemoryKeyValueStore())
        settings.rememberCursor(sessionID: "L1", seq: 4417)
        settings.rememberCursor(sessionID: "L2", seq: 0)
        XCTAssertEqual(settings.lastSessionID, "L2")
        XCTAssertEqual(settings.lastSeq, 0)
    }

    /// Resuming a session after a RELAUNCH must continue its audio clock. Starting
    /// again at zero would emit timestamps colliding with the rows already in the
    /// transcript, interleaving the two halves of one conversation.
    func testTheAudioClockIsRememberedForAResumedSession() {
        let store = MemoryKeyValueStore()
        let first = LiveSettings(store: store)
        first.rememberCursor(sessionID: "L1", seq: 10)
        first.rememberAudioClock(sessionID: "L1", elapsedMs: 754_000, audioSeq: 9421)

        let second = LiveSettings(store: store)
        XCTAssertEqual(second.lastElapsedMs, 754_000)
        XCTAssertEqual(second.lastAudioSeq, 9421)
    }

    func testTheAudioClockOnlyMovesForwardAndOnlyForItsOwnSession() {
        let settings = LiveSettings(store: MemoryKeyValueStore())
        settings.rememberCursor(sessionID: "L1", seq: 1)
        settings.rememberAudioClock(sessionID: "L1", elapsedMs: 5000, audioSeq: 50)
        settings.rememberAudioClock(sessionID: "L1", elapsedMs: 1000, audioSeq: 10)
        XCTAssertEqual(settings.lastElapsedMs, 5000)
        XCTAssertEqual(settings.lastAudioSeq, 50)

        settings.rememberAudioClock(sessionID: "other", elapsedMs: 99_000, audioSeq: 999)
        XCTAssertEqual(settings.lastElapsedMs, 5000,
                       "another session's clock must not be written into this one")
    }

    func testANewSessionAlsoRestartsTheAudioClock() {
        let settings = LiveSettings(store: MemoryKeyValueStore())
        settings.rememberCursor(sessionID: "L1", seq: 10)
        settings.rememberAudioClock(sessionID: "L1", elapsedMs: 754_000, audioSeq: 9421)

        settings.rememberCursor(sessionID: "L2", seq: 0)
        XCTAssertEqual(settings.lastElapsedMs, 0)
        XCTAssertEqual(settings.lastAudioSeq, 0)
    }

    func testAnEmptySessionIDIsIgnoredRatherThanStored() {
        let settings = LiveSettings(store: MemoryKeyValueStore())
        settings.rememberCursor(sessionID: "", seq: 9)
        XCTAssertEqual(settings.lastSessionID, "")
        XCTAssertEqual(settings.lastSeq, 0)
    }

    func testForgettingTheCursorClearsBothHalves() {
        let settings = LiveSettings(store: MemoryKeyValueStore())
        settings.rememberCursor(sessionID: "L1", seq: 10)
        settings.forgetCursor()
        XCTAssertEqual(settings.lastSessionID, "")
        XCTAssertEqual(settings.lastSeq, 0)
    }

    // MARK: - Server config

    func testConfigRoundTripsEveryContractKey() {
        var config = LiveConfig()
        config.enabled = false
        config.windowSeconds = 300
        config.minWindowWords = 5
        config.monitor = false
        config.factCheck = false
        config.translate = false
        config.memoryExtraction = false
        config.artifacts = false
        config.replyMode = "spoken"
        config.primaryLanguage = "fr-FR"
        config.embedModel = "ecapa-v1"
        config.speakerSplit = "engine"

        XCTAssertEqual(LiveConfig.from(config.payload), config)
    }

    /// Every key on every PUT: the web popup edits the same record, so a client that
    /// omitted a key would erase whatever the other surface had set.
    func testEveryContractKeyIsPresentOnEveryPut() {
        let payload = LiveConfig().payload
        for key in ["enabled", "window_seconds", "min_window_words", "monitor", "fact_check",
                    "translate", "memory_extraction", "artifacts", "reply_mode",
                    "primary_language", "embed_model", "speaker_split"] {
            XCTAssertNotNil(payload[key], "\(key) is missing from the PUT body")
        }
    }

    func testConfigIsReadWhetherNestedOrFlat() {
        let flat = LiveConfig.from(["monitor": false, "window_seconds": 45])
        XCTAssertFalse(flat.monitor)
        XCTAssertEqual(flat.windowSeconds, 45)

        let nested = LiveConfig.from(["config": ["monitor": false, "window_seconds": 45]])
        XCTAssertEqual(nested, flat)
    }

    /// A key the server did not send must keep its default, not become false/zero —
    /// an absent `monitor` silently reading as "off" would disable a watcher.
    func testAbsentKeysKeepTheirDefaults() {
        let defaults = LiveConfig()
        let partial = LiveConfig.from(["window_seconds": 45])
        XCTAssertEqual(partial.monitor, defaults.monitor)
        XCTAssertEqual(partial.factCheck, defaults.factCheck)
        XCTAssertEqual(partial.replyMode, defaults.replyMode)
        XCTAssertEqual(partial.primaryLanguage, defaults.primaryLanguage)
    }

    func testSpokenRepliesReadsTheReplyMode() {
        var config = LiveConfig()
        config.replyMode = "spoken"
        XCTAssertTrue(config.spokenReplies)
        config.replyMode = "text"
        XCTAssertFalse(config.spokenReplies)
        config.replyMode = "SPOKEN"
        XCTAssertTrue(config.spokenReplies, "the comparison must not be case-sensitive")
    }

    /// The phone translates its own lines unless told otherwise, and remembers.
    func testTranslatingOnThePhoneIsTheDefaultAndPersists() {
        let values = MemoryKeyValueStore()
        XCTAssertTrue(LiveSettings(store: values).translateOnPhone)
        LiveSettings(store: values).translateOnPhone = false
        XCTAssertFalse(LiveSettings(store: values).translateOnPhone)
    }

    /// Removing the model a choice runs on moves the choice to what is left,
    /// rather than leaving "This phone" ticked while the server does the work.
    /// (Nothing is downloaded in the simulator, so nothing is left.)
    func testRemovingTheChosenModelFallsBackToWhatIsLeft() {
        let values = MemoryKeyValueStore()
        values.set(LiveHearing.phoneAll.rawValue, forKey: LiveModels.hearingKey)
        let models = LiveModels(defaults: values)
        XCTAssertEqual(models.hearing, .phoneAll)

        models.remove(.senseVoice)

        XCTAssertEqual(models.hearing, .server)
        XCTAssertEqual(LiveModels(defaults: values).hearing, .server, "and it is remembered")
    }

    /// Server means the phone does not re-hear lines, even with models on it.
    func testChoosingTheServerBuildsNoTranscriber() async {
        let values = MemoryKeyValueStore()
        values.set(LiveHearing.server.rawValue, forKey: LiveModels.hearingKey)
        let made = await LiveModels(defaults: values).transcriber()
        XCTAssertNil(made)
    }
}

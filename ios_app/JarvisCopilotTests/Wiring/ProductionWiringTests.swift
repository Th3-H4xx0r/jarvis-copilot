import XCTest
@testable import JarvisCopilot

/// The cross-area wiring that a screen only exercises when it is actually on
/// screen — the kind that compiles perfectly while doing nothing.
@MainActor
final class ProductionWiringTests: XCTestCase {

    // MARK: Dynamic Island designs

    /// Without `sync` the widget extension keeps reading a stale App Group copy;
    /// without `onChanged` a selection change waits out the coordinator's
    /// idle-throttled (60 s) poll before the island actually switches.
    func testTheDesignsScreenShipsWithTheCacheAndTheRefreshHook() {
        let (api, _) = JarvisAPI.mocked()
        let store = IslandDesignsStore.production(api: IslandDesignsAPI(api: api))
        XCTAssertNotNil(store.sync, "the widget reads the App Group copy this writes")
        XCTAssertNotNil(store.onChanged, "a selection change must refresh the island now")
    }

    func testAnInjectedDesignsStoreStaysInert() {
        let (api, _) = JarvisAPI.mocked()
        let store = IslandDesignsStore(api: IslandDesignsAPI(api: api))
        XCTAssertNil(store.sync)
        XCTAssertNil(store.onChanged)
    }

    // MARK: Startup cost

    /// `main.dart` built its voice controller lazily so the audio session was not
    /// configured until Voice was opened; `AppServices` resolves `VoiceStore`
    /// eagerly instead (that is what makes the live-activity attach and the
    /// background pause/resume reach the session). That is only acceptable while
    /// `init` claims nothing: no audio session, no microphone.
    func testVoiceStoreInitConfiguresNoAudioSessionAndStartsNoMic() {
        let (api, _) = JarvisAPI.mocked()
        let input = MockAudioInput()
        let audioSession = MockAudioSessionControlling()

        _ = VoiceStore(api: api, input: input, output: MockAudioOutput(),
                       recognizer: MockSpeechRecognizing(),
                       synthesizer: MockVoiceSynthesizing(),
                       audioSession: audioSession,
                       connector: MockVoiceSocketConnector(),
                       clock: TestVoiceClock(),
                       keyValueStore: MemoryKeyValueStore())

        XCTAssertEqual(audioSession.configureCount, 0,
                       "claiming the session at launch would duck other apps' audio")
        XCTAssertEqual(audioSession.activeCalls, [])
        XCTAssertTrue(input.startedRates.isEmpty, "no mic, and so no red status bar")
        XCTAssertFalse(input.isRunning)
    }
}

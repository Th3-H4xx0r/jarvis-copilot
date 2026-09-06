import XCTest
@testable import JarvisCopilot

/// Records what the Coding tab told the Live Activity coordinator.
@MainActor
final class FakeCodingVisibilityReporter: CodingVisibilityReporting {
    private(set) var reports: [Bool] = []
    func setCodingVisible(_ visible: Bool) { reports.append(visible) }
}

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

    // MARK: Coding visibility

    /// Three listeners, one call site: the flag `CodingStore` reads, its list
    /// poll, and the coordinator's poll cadence (`LivePollPolicy` keeps the fast
    /// cadence while Coding is on screen even before a session goes live).
    func testCodingVisibilityFansOutToAllThreeListeners() {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/coding/projects", json: ["projects": []])
        let flag = CodingVisibilityFlag()
        let store = CodingStore(api: CodingSessionsAPI(api: api), isVisible: { flag.isVisible })
        let liveActivity = FakeCodingVisibilityReporter()
        let visibility = CodingVisibility(flag: flag, store: store, liveActivity: liveActivity)

        visibility.set(true)
        XCTAssertTrue(flag.isVisible)
        XCTAssertEqual(liveActivity.reports, [true])

        visibility.set(false)
        XCTAssertFalse(flag.isVisible)
        XCTAssertEqual(liveActivity.reports, [true, false],
                       "leaving Coding must let the poll fall back to 60 s discovery")
    }

    /// The one coordinator really implements the reporting boundary — the fake
    /// above would otherwise be testing itself.
    func testTheLiveActivityCoordinatorIsTheProductionReporter() {
        let reporter: any CodingVisibilityReporting = LiveActivityCoordinator.shared
        reporter.setCodingVisible(true)
        XCTAssertTrue(LiveActivityCoordinator.shared.codingVisible)
        reporter.setCodingVisible(false)
        XCTAssertFalse(LiveActivityCoordinator.shared.codingVisible)
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

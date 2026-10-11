import XCTest
@testable import JarvisCopilot

@MainActor
final class MockSettingsBridge: SettingsBridging {
    var serverURL = "https://jarvis.test"
    var isPaired = true
    var keepaliveEnabled = true
    private(set) var unpairCount = 0

    func unpair() { unpairCount += 1; isPaired = false; keepaliveEnabled = false }
}

@MainActor
final class MockLocationTracking: LocationTracking {
    var grant = true
    private(set) var calls: [Bool] = []
    func setEnabled(_ on: Bool) async -> Bool {
        calls.append(on)
        return on ? grant : true
    }
}

@MainActor
final class MockLiveActivityToggling: LiveActivityToggling {
    private(set) var calls: [Bool] = []
    func setEnabled(_ on: Bool) { calls.append(on) }
}

@MainActor
final class SettingsStoreTests: XCTestCase {

    private var liveActivity = MockLiveActivityToggling()

    override func setUp() {
        super.setUp()
        liveActivity = MockLiveActivityToggling()
        websiteClears = 0
    }

    /// Stands in for WebKit: touching the real store from the test host would
    /// clear the simulator's shared one.
    private var websiteClears = 0

    private func makeStore(
        _ prefs: MemoryKeyValueStore = MemoryKeyValueStore()
    ) -> (SettingsStore, MockSettingsBridge, MockLocationTracking, MemoryKeyValueStore) {
        let bridge = MockSettingsBridge()
        let location = MockLocationTracking()
        let store = SettingsStore(preferences: prefs, bridge: bridge, location: location,
                                  liveActivity: liveActivity,
                                  clearWebsiteData: { [unowned self] in self.websiteClears += 1 })
        return (store, bridge, location, prefs)
    }

    // MARK: Defaults (mirroring credentials.dart)

    func testDefaults() {
        let (store, bridge, _, _) = makeStore()
        XCTAssertFalse(store.trackLocation, "opt-in: it needs Always permission and costs battery")
        XCTAssertTrue(store.liveActivities, "credentials.dart defaults live_activities on")
        XCTAssertEqual(store.keepalive, bridge.keepaliveEnabled)
        XCTAssertEqual(store.serverURL, "https://jarvis.test")
        XCTAssertTrue(store.isPaired)
        XCTAssertFalse(store.deviceName.isEmpty, "falls back to the hardware label")
    }

    // MARK: Persistence

    func testDeviceNameRoundTripsThroughThePreferences() {
        let prefs = MemoryKeyValueStore()
        let (store, _, _, _) = makeStore(prefs)
        store.setDeviceName("Work iPhone")
        XCTAssertEqual(prefs.string(SettingsStore.Keys.deviceName), "Work iPhone")

        let (reloaded, _, _, _) = makeStore(prefs)
        XCTAssertEqual(reloaded.deviceName, "Work iPhone")
    }

    func testBlankingTheDeviceNameFallsBackToTheDefault() {
        let (store, _, _, prefs) = makeStore()
        store.setDeviceName("   ")
        XCTAssertFalse(store.deviceName.isEmpty)
        XCTAssertNil(prefs.string(SettingsStore.Keys.deviceName))
    }

    func testLiveActivitiesRoundTrips() {
        let prefs = MemoryKeyValueStore()
        let (store, _, _, _) = makeStore(prefs)
        store.setLiveActivities(false)
        XCTAssertFalse(store.liveActivities)
        XCTAssertEqual(prefs.bool(SettingsStore.Keys.liveActivities), false)

        let (reloaded, _, _, _) = makeStore(prefs)
        XCTAssertFalse(reloaded.liveActivities)
    }

    /// Recording the preference is not enough: switching off has to END the
    /// running activity, or a stale island survives on the Lock Screen.
    func testLiveActivitiesTellsTheCoordinatorImmediately() {
        let (store, _, _, _) = makeStore()
        store.setLiveActivities(false)
        XCTAssertEqual(liveActivity.calls, [false])
        store.setLiveActivities(true)
        XCTAssertEqual(liveActivity.calls, [false, true])
    }

    /// The two platform switches only mean something if the store is holding the
    /// real services; a default-constructed store is what `SettingsPage` ships.
    func testProductionDefaultsReachTheRealServices() {
        let store = SettingsStore(preferences: MemoryKeyValueStore(),
                                  bridge: MockSettingsBridge())
        XCTAssertTrue(store.location === BackgroundLocationService.shared,
                      "the settings toggle and the launch re-arm must be the same tracker")
        XCTAssertTrue(store.liveActivity === LiveActivityCoordinator.shared,
                      "there is exactly one Live Activity owner")
    }

    func testTrackLocationRoundTripsWhenPermissionIsGranted() async {
        let prefs = MemoryKeyValueStore()
        let (store, _, location, _) = makeStore(prefs)
        await store.setTrackLocation(true)
        XCTAssertTrue(store.trackLocation)
        XCTAssertEqual(location.calls, [true])
        XCTAssertEqual(prefs.bool(SettingsStore.Keys.trackLocation), true)

        let (reloaded, _, _, _) = makeStore(prefs)
        XCTAssertTrue(reloaded.trackLocation)
    }

    /// Flutter leaves the switch off and shows a SnackBar when Always-location is
    /// refused — flipping it on would lie about what the app can do.
    func testTrackLocationStaysOffWhenPermissionIsRefused() async {
        let (store, _, location, prefs) = makeStore()
        location.grant = false
        await store.setTrackLocation(true)
        XCTAssertFalse(store.trackLocation)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertNil(prefs.bool(SettingsStore.Keys.trackLocation))
    }

    func testTurningTrackLocationOffAlwaysSticks() async {
        let (store, _, location, _) = makeStore()
        await store.setTrackLocation(true)
        location.grant = false          // irrelevant when switching off
        await store.setTrackLocation(false)
        XCTAssertFalse(store.trackLocation)
        XCTAssertEqual(location.calls, [true, false])
    }

    // MARK: Keepalive → the bridge

    /// The switch only governs the background keepalive; the socket stays up.
    func testKeepaliveWritesThroughToTheBridge() {
        let (store, bridge, _, _) = makeStore()
        store.setKeepalive(false)
        XCTAssertFalse(store.keepalive)
        XCTAssertFalse(bridge.keepaliveEnabled)

        store.setKeepalive(true)
        XCTAssertTrue(store.keepalive)
        XCTAssertTrue(bridge.keepaliveEnabled)
    }

    /// The bridge owns the live value; it lives in the Keychain.
    func testKeepaliveFollowsTheBridgeNotThePreferences() {
        let prefs = MemoryKeyValueStore()
        let bridge = MockSettingsBridge()
        bridge.keepaliveEnabled = true
        let store = SettingsStore(preferences: prefs, bridge: bridge,
                                  location: MockLocationTracking())
        XCTAssertTrue(store.keepalive)
    }

    // MARK: Unpair

    func testUnpairGoesThroughTheBridgeAndForgetsThePreferences() async {
        let (store, bridge, _, prefs) = makeStore()
        store.setDeviceName("Work iPhone")
        await store.setTrackLocation(true)
        store.unpair()
        XCTAssertEqual(bridge.unpairCount, 1)
        XCTAssertFalse(store.isPaired)
        XCTAssertNil(prefs.string(SettingsStore.Keys.deviceName))
        XCTAssertNil(prefs.bool(SettingsStore.Keys.trackLocation))
        XCTAssertFalse(store.trackLocation)
    }

    // MARK: - Unpair clears the webview's storage (security M1 / swift H15)

    /// The embedded server tabs run in a `WKWebView`, and the `hermes_session`
    /// cookie they need lives in WebKit's own store — NOT the Keychain the
    /// bridge wipes. Leaving it behind hands the next person to pair this phone
    /// a logged-in webui.
    func testUnpairClearsTheWebviewsWebsiteData() {
        let (store, _, _, _) = makeStore()
        XCTAssertEqual(websiteClears, 0)
        store.unpair()
        XCTAssertEqual(websiteClears, 1)
    }

    // MARK: - Unpair forgets what we learned about that server

    /// `ChatAPI`'s streaming-start probe is process-wide, and unpairing never
    /// cleared it: the next pairing inherited the previous server's verdict for
    /// the rest of the launch and every turn took the wrong path.
    func testUnpairForgetsWhatWeLearnedAboutThatServer() {
        var resets = 0
        let store = SettingsStore(preferences: MemoryKeyValueStore(),
                                  bridge: MockSettingsBridge(),
                                  location: MockLocationTracking(),
                                  liveActivity: liveActivity, clearWebsiteData: {},
                                  onServerChanged: { resets += 1 })
        XCTAssertEqual(resets, 0)
        store.unpair()
        XCTAssertEqual(resets, 1)
    }

    /// …and the production default really is `ChatAPI.resetFeatureDetection()`.
    func testTheDefaultHookClearsChatsFeatureProbe() {
        ChatAPI.streamingStartSupported = true
        let (store, _, _, _) = makeStore()
        store.unpair()
        XCTAssertNil(ChatAPI.streamingStartSupported, "a re-pair must re-probe the new server")
    }

    // MARK: - Notification permission row (silent-failures M1)

    func testNotificationsAreOffOnlyOnceSomethingHasActuallyAsked() {
        let (store, _, _, _) = makeStore()
        XCTAssertNil(store.notificationsGranted, "nobody has asked yet")
        XCTAssertFalse(store.notificationsAreOff, "…so we must not claim they are off")
    }

    func testTheNotificationRowFollowsWhoeverLearnedThePermission() {
        let prefs = MemoryKeyValueStore()
        let (store, _, _, _) = makeStore(prefs)

        prefs.set(false, forKey: SettingsStore.Keys.notificationsGranted)
        store.refreshNotificationStatus()
        XCTAssertTrue(store.notificationsAreOff)

        // Re-granted in iOS Settings while we were backgrounded.
        prefs.set(true, forKey: SettingsStore.Keys.notificationsGranted)
        store.refreshNotificationStatus()
        XCTAssertFalse(store.notificationsAreOff)
    }

    func testAStoreBuiltAfterTheRefusalStartsInTheOffState() {
        let prefs = MemoryKeyValueStore([SettingsStore.Keys.notificationsGranted: false])
        let (store, _, _, _) = makeStore(prefs)
        XCTAssertTrue(store.notificationsAreOff)
    }
}

/// Settings → Auto-compact: `/api/compression/config`, the same settings the web
/// edits. The trigger math mirrors `compute_threshold_tokens` on the server so the
/// readout moves with the slider before anything is saved.
@MainActor
final class CompactionSettingsTests: XCTestCase {

    private let server: [String: Any] = [
        "config": ["enabled": true, "threshold_percent": 50, "max_context_tokens": 0],
        "defaults": ["enabled": true, "threshold_percent": 50, "max_context_tokens": 0],
        "limits": ["min_percent": 10, "max_percent": 95, "floor_tokens": 64000,
                   "min_cap_tokens": 16000, "fallback_context_length": 256000],
        "preview": ["model": "claude-sonnet-5-5", "provider": "anthropic-api",
                    "context_length": 1_000_000, "threshold_tokens": 500_000],
    ]

    func testParsesWhatTheServerSends() {
        let s = CompactionSettings.from(server)
        XCTAssertTrue(s.enabled)
        XCTAssertEqual(s.percent, 50)
        XCTAssertEqual(s.cap, 0)
        XCTAssertEqual(s.minPercent, 10)
        XCTAssertEqual(s.maxPercent, 95)
        XCTAssertEqual(s.model, "claude-sonnet-5-5")
        XCTAssertEqual(s.contextLength, 1_000_000)
        XCTAssertEqual(s.trigger, 500_000)
    }

    func testTriggerFollowsTheWindow() {
        var s = CompactionSettings.from(server)
        XCTAssertEqual(s.trigger(contextLength: 1_000_000, percent: 50, cap: 0), 500_000)
        XCTAssertEqual(s.trigger(contextLength: 200_000, percent: 50, cap: 0), 100_000)
        XCTAssertEqual(s.trigger(contextLength: 100_000, percent: 50, cap: 0), 64_000, "the floor")
        XCTAssertEqual(s.trigger(contextLength: 64_000, percent: 50, cap: 0), 60_800, "never above 95%")
        XCTAssertEqual(s.trigger(contextLength: 1_000_000, percent: 50, cap: 200_000), 200_000)
        XCTAssertEqual(s.trigger(contextLength: 0, percent: 50, cap: 0), 128_000, "unknown window → fallback")
        s.percent = 80
        XCTAssertEqual(s.trigger, 800_000)
    }

    func testReadoutNamesTheModelAndTheNumbers() {
        var s = CompactionSettings.from(server)
        XCTAssertEqual(s.readout, "Compacts at \(500_000.formatted()) of \(1_000_000.formatted()) tokens "
                                + "for claude-sonnet-5-5.")
        s.cap = 200_000
        XCTAssertTrue(s.readout.hasSuffix("held down by the token cap."), s.readout)
        s.enabled = false
        XCTAssertTrue(s.readout.hasPrefix("Off"), s.readout)
    }

    func testLoadAsksAboutTheChatModelAndSaveSendsOnlyTheChange() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/compression/config", json: server)
        let prefs = MemoryKeyValueStore()
        let selection = ModelSelection(store: prefs)
        selection.set(.chat, model: "claude-opus-5-5", provider: "claude-code")
        let store = CompactionStore(api: CompactionAPI(api: api), selection: selection)
        await store.load()
        XCTAssertTrue(store.loaded)
        let query = transport.lastRequest?.url?.query ?? ""
        XCTAssertTrue(query.contains("model=claude-opus-5-5"), query)
        XCTAssertTrue(query.contains("provider=claude-code"), query)

        await store.setPercent(80)
        XCTAssertEqual(transport.lastRequest?.httpMethod, "PUT")
        let body = transport.lastBody()
        XCTAssertEqual(body["threshold_percent"] as? Int, 80)
        XCTAssertNil(body["max_context_tokens"])
        XCTAssertEqual(body["model"] as? String, "claude-opus-5-5")
    }

    func testAFailedSaveRollsBack() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: server)
        transport.enqueue(json: ["error": "max_context_tokens must be 0 (no cap) or 16,000 to 10,000,000"],
                          status: 400)
        let store = CompactionStore(api: CompactionAPI(api: api), selection: ModelSelection(store: MemoryKeyValueStore()))
        await store.load()
        await store.setCap(1000)
        XCTAssertEqual(store.settings.cap, 0, "the server refused, so the screen shows what it holds")
        XCTAssertFalse(store.error.isEmpty)
    }
}

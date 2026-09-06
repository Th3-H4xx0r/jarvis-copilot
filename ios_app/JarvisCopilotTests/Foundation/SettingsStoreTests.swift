import XCTest
@testable import JarvisCopilot

@MainActor
final class MockSettingsBridge: SettingsBridging {
    var serverURL = "https://jarvis.test"
    var isPaired = true
    var keepaliveEnabled = true
    private(set) var unpairCount = 0
    private(set) var connectCount = 0
    private(set) var disconnectCount = 0

    func unpair() { unpairCount += 1; isPaired = false; keepaliveEnabled = false }
    func connect() { connectCount += 1 }
    func disconnect() { disconnectCount += 1 }
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

/// Stands in for WebKit: there is no way to observe `WKWebsiteDataStore` from a
/// unit test, and touching the real one from the test host would clear the
/// simulator's shared store.
@MainActor
final class MockWebsiteCleaner: WebsiteDataClearing {
    private(set) var clears = 0
    func clearWebsiteData() { clears += 1 }
}

@MainActor
final class SettingsStoreTests: XCTestCase {

    private var liveActivity = MockLiveActivityToggling()

    override func setUp() {
        super.setUp()
        liveActivity = MockLiveActivityToggling()
        website = MockWebsiteCleaner()
    }

    private var website = MockWebsiteCleaner()

    private func makeStore(
        _ prefs: MemoryKeyValueStore = MemoryKeyValueStore()
    ) -> (SettingsStore, MockSettingsBridge, MockLocationTracking, MemoryKeyValueStore) {
        let bridge = MockSettingsBridge()
        let location = MockLocationTracking()
        let store = SettingsStore(preferences: prefs, bridge: bridge, location: location,
                                  liveActivity: liveActivity, website: website)
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

    func testKeepaliveWritesThroughToTheBridgeAndReconnects() {
        let (store, bridge, _, prefs) = makeStore()
        store.setKeepalive(false)
        XCTAssertFalse(store.keepalive)
        XCTAssertFalse(bridge.keepaliveEnabled)
        XCTAssertEqual(bridge.disconnectCount, 1)
        XCTAssertEqual(prefs.bool(SettingsStore.Keys.keepalive), false)

        store.setKeepalive(true)
        XCTAssertTrue(bridge.keepaliveEnabled)
        XCTAssertEqual(bridge.connectCount, 1)
    }

    /// The bridge owns the live value (it lives in the Keychain); the mirror in
    /// preferences is only there so a fresh store starts in the right place.
    func testKeepaliveFollowsTheBridgeNotThePreferences() {
        let prefs = MemoryKeyValueStore([SettingsStore.Keys.keepalive: false])
        let bridge = MockSettingsBridge()
        bridge.keepaliveEnabled = true
        let store = SettingsStore(preferences: prefs, bridge: bridge,
                                  location: MockLocationTracking(),
                                  website: MockWebsiteCleaner())
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
        XCTAssertEqual(website.clears, 0)
        store.unpair()
        XCTAssertEqual(website.clears, 1)
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
                                  liveActivity: liveActivity, website: website,
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

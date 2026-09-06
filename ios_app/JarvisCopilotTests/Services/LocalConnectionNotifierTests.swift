import Foundation
import XCTest
@testable import JarvisCopilot

/// `Services/LocalConnectionNotifier.swift` — the notification half of the
/// connection monitor, and `BridgeConnectionFeed`, which samples the bridge for it.
@MainActor
final class LocalConnectionNotifierTests: XCTestCase {

    // MARK: Identifiers (pure)

    func testEachDirectionHasItsOwnFixedIdentifier() {
        XCTAssertEqual(LocalConnectionNotifier.identifier(for: ConnectionNotice.reconnected.title),
                       "jc.connection.up")
        XCTAssertEqual(LocalConnectionNotifier.identifier(for: ConnectionNotice.disconnected.title),
                       "jc.connection.down")
    }

    func testTheOppositeBannerIsTheOtherDirection() {
        XCTAssertEqual(LocalConnectionNotifier.opposite(of: "jc.connection.up"),
                       "jc.connection.down")
        XCTAssertEqual(LocalConnectionNotifier.opposite(of: "jc.connection.down"),
                       "jc.connection.up")
    }

    // MARK: Posting

    /// The opposite banner has to be cancelled BEFORE the new one is posted, or
    /// Notification Centre briefly shows "disconnected" and "reconnected"
    /// together — and, if the post is slow, keeps showing the stale one.
    func testTheOppositeBannerIsCancelledBeforeThePost() async {
        let mock = MockNotifier()
        let notifier = LocalConnectionNotifier(notifier: mock,
                                               preferences: MemoryKeyValueStore())

        notifier.notify(title: ConnectionNotice.reconnected.title,
                        body: ConnectionNotice.reconnected.body)
        await notifier.waitForPost()

        XCTAssertEqual(mock.cancelled, ["jc.connection.down"])
        XCTAssertEqual(mock.posted.count, 1)
        XCTAssertEqual(mock.posted[0].identifier, "jc.connection.up")
        XCTAssertEqual(mock.posted[0].title, "JARVIS reconnected")
    }

    func testADisconnectCancelsTheReconnectedBanner() async {
        let mock = MockNotifier()
        let notifier = LocalConnectionNotifier(notifier: mock,
                                               preferences: MemoryKeyValueStore())

        notifier.notify(title: ConnectionNotice.disconnected.title,
                        body: ConnectionNotice.disconnected.body)
        await notifier.waitForPost()

        XCTAssertEqual(mock.cancelled, ["jc.connection.up"])
        XCTAssertEqual(mock.posted[0].identifier, "jc.connection.down")
    }

    /// A refused permission is the only realistic failure, and it is worth
    /// recording: Settings reads this flag to say "Notifications are off"
    /// instead of leaving the user with banners that never appear.
    func testARefusedPostRecordsThatNotificationsAreOff() async {
        let mock = MockNotifier(granted: false)
        let prefs = MemoryKeyValueStore()
        let notifier = LocalConnectionNotifier(notifier: mock, preferences: prefs)

        notifier.notify(title: ConnectionNotice.disconnected.title, body: "x")
        await notifier.waitForPost()

        XCTAssertTrue(mock.posted.isEmpty)
        XCTAssertEqual(prefs.bool(SettingsStore.Keys.notificationsGranted), false)

        let store = SettingsStore(preferences: prefs, bridge: MockSettingsBridge(),
                                  location: MockLocationTracking(),
                                  liveActivity: MockLiveActivityToggling(),
                                  website: MockWebsiteCleaner())
        XCTAssertTrue(store.notificationsAreOff)
    }

    func testASuccessfulPostRecordsThatNotificationsWork() async {
        let prefs = MemoryKeyValueStore()
        let notifier = LocalConnectionNotifier(notifier: MockNotifier(), preferences: prefs)
        notifier.notify(title: ConnectionNotice.reconnected.title, body: "x")
        await notifier.waitForPost()
        XCTAssertEqual(prefs.bool(SettingsStore.Keys.notificationsGranted), true)
    }

    // MARK: BridgeConnectionFeed

    /// Edge-triggered: the monitor is told only when the sampled state actually
    /// changes, otherwise every 1 s tick would restart the 4 s debounce and no
    /// banner would ever settle.
    func testTheFeedOnlyReportsEdges() async {
        let notifier = RecordingNotifier()
        let monitor = ConnectionMonitor(notifier: notifier, debounce: 0,
                                        sleeper: { _ in })
        let samples = [false, false, true, true, false]
        var index = 0
        let feed = BridgeConnectionFeed(
            monitor: monitor,
            isConnected: {
                defer { index = min(index + 1, samples.count - 1) }
                return samples[index]
            },
            sleeper: { _ in try await Task.sleep(nanoseconds: 1_000_000) })

        feed.start()
        let deadline = Date().addingTimeInterval(2)
        while notifier.titles.count < 2 && Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        feed.stop()

        // The first sample is the monitor's silent baseline; only the two real
        // flips reach the notifier.
        XCTAssertEqual(notifier.titles, ["JARVIS reconnected", "JARVIS disconnected"])
    }

    func testStoppingTheFeedEndsTheSampling() async {
        let notifier = RecordingNotifier()
        let monitor = ConnectionMonitor(notifier: notifier, debounce: 0, sleeper: { _ in })
        var polls = 0
        let feed = BridgeConnectionFeed(
            monitor: monitor,
            isConnected: { polls += 1; return false },
            sleeper: { _ in try await Task.sleep(nanoseconds: 1_000_000) })

        feed.start()
        try? await Task.sleep(nanoseconds: 20_000_000)
        feed.stop()
        let settled = polls
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(polls, settled, "stop() must cancel the sampler")
    }
}

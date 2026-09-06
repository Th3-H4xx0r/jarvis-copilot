import Foundation
import XCTest
@testable import JarvisCopilot

/// `services/connection_monitor.dart` had no Dart test; these cover the policy
/// it encodes — silent first settle, ignore flaps, announce real transitions.
final class ConnectionMonitorTests: XCTestCase {

    // MARK: Pure policy

    func testFirstSettleIsSilentAndOnlyEstablishesTheBaseline() {
        var policy = ConnectionMonitorPolicy()
        XCTAssertNil(policy.settled(true))
        XCTAssertEqual(policy.lastNotified, true)
    }

    func testFirstSettleWhileDisconnectedIsAlsoSilent() {
        var policy = ConnectionMonitorPolicy()
        XCTAssertNil(policy.settled(false))
        XCTAssertEqual(policy.lastNotified, false)
    }

    func testTransitionsAnnounceOnceEach() {
        var policy = ConnectionMonitorPolicy()
        _ = policy.settled(true)                                // baseline
        XCTAssertEqual(policy.settled(false), .disconnected)
        XCTAssertEqual(policy.settled(true), .reconnected)
    }

    func testRepeatedSameStateSettlesAreNoOps() {
        var policy = ConnectionMonitorPolicy()
        _ = policy.settled(true)
        XCTAssertNil(policy.settled(true))
        XCTAssertEqual(policy.settled(false), .disconnected)
        XCTAssertNil(policy.settled(false))
    }

    func testNoticeCopyMatchesTheFlutterStrings() {
        XCTAssertEqual(ConnectionNotice.disconnected.title, "JARVIS disconnected")
        XCTAssertEqual(ConnectionNotice.disconnected.body, "Lost connection to your server.")
        XCTAssertEqual(ConnectionNotice.reconnected.title, "JARVIS reconnected")
        XCTAssertEqual(ConnectionNotice.reconnected.body, "Back online with your server.")
    }

    // MARK: Debounced monitor

    @MainActor
    func testInitialConnectIsNeverAnnounced() async {
        let notifier = RecordingNotifier()
        let monitor = ConnectionMonitor(notifier: notifier, debounce: 0, sleeper: instantSleeper)
        monitor.connectionChanged(true)
        await monitor.waitForPending()
        XCTAssertTrue(notifier.posted.isEmpty)
    }

    @MainActor
    func testADropAfterTheBaselineIsAnnouncedOnce() async {
        let notifier = RecordingNotifier()
        let monitor = ConnectionMonitor(notifier: notifier, debounce: 0, sleeper: instantSleeper)
        monitor.connectionChanged(true)
        await monitor.waitForPending()
        monitor.connectionChanged(false)
        await monitor.waitForPending()

        XCTAssertEqual(notifier.titles, ["JARVIS disconnected"])
        XCTAssertEqual(notifier.posted.first?.body, "Lost connection to your server.")
    }

    @MainActor
    func testReconnectIsAnnouncedAfterADrop() async {
        let notifier = RecordingNotifier()
        let monitor = ConnectionMonitor(notifier: notifier, debounce: 0, sleeper: instantSleeper)
        for value in [true, false, true] {
            monitor.connectionChanged(value)
            await monitor.waitForPending()
        }
        XCTAssertEqual(notifier.titles, ["JARVIS disconnected", "JARVIS reconnected"])
    }

    @MainActor
    func testAFlapWithinTheDebounceWindowIsDroppedEntirely() async {
        let notifier = RecordingNotifier()
        let monitor = ConnectionMonitor(notifier: notifier, debounce: 0, sleeper: instantSleeper)
        monitor.connectionChanged(true)
        await monitor.waitForPending()

        // Drop and come back before the debounce elapses: the pending settle is
        // cancelled, and the replacement settles on the SAME state as the
        // baseline, so nothing is announced.
        monitor.connectionChanged(false)
        monitor.connectionChanged(true)
        await monitor.waitForPending()

        XCTAssertTrue(notifier.posted.isEmpty, "\(notifier.titles)")
    }

    @MainActor
    func testCancelStopsAPendingAnnouncement() async {
        let notifier = RecordingNotifier()
        let monitor = ConnectionMonitor(notifier: notifier, debounce: 0, sleeper: instantSleeper)
        monitor.connectionChanged(true)
        await monitor.waitForPending()

        monitor.connectionChanged(false)
        monitor.cancel()
        await monitor.waitForPending()
        XCTAssertTrue(notifier.posted.isEmpty)
    }

    @MainActor
    func testConnectedTracksTheLatestReportedValueImmediately() {
        let notifier = RecordingNotifier()
        let monitor = ConnectionMonitor(connected: true, notifier: notifier,
                                        debounce: 0, sleeper: instantSleeper)
        XCTAssertTrue(monitor.connected)
        monitor.connectionChanged(false)
        XCTAssertFalse(monitor.connected)
    }
}

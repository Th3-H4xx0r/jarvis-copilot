import CoreLocation
import Foundation
import XCTest
@testable import JarvisCopilot

/// `services/background_location.dart` plus the significant-location-change half
/// of the Flutter `AppDelegate`.
@MainActor
final class BackgroundLocationTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func fix(lat: Double = 51.5, lng: Double = -0.12,
                     accuracy: Double = 12, at offset: TimeInterval = 0) -> LocationFix {
        LocationFix(latitude: lat, longitude: lng, accuracyMeters: accuracy,
                    timestamp: base.addingTimeInterval(offset))
    }

    // MARK: Report gating (pure)

    func testTheFirstFixIsAlwaysReported() {
        XCTAssertTrue(BackgroundLocationService.shouldReport(
            fix(), lastReported: nil, lastReportAt: .distantPast, now: base))
    }

    func testAStationaryDeviceIsReportedOnlyEveryTenMinutes() {
        let last = fix()
        XCTAssertFalse(BackgroundLocationService.shouldReport(
            fix(), lastReported: last, lastReportAt: base, now: base.addingTimeInterval(9 * 60)))
        XCTAssertTrue(BackgroundLocationService.shouldReport(
            fix(), lastReported: last, lastReportAt: base, now: base.addingTimeInterval(10 * 60)))
    }

    func testRealMovementIsReportedImmediately() {
        let last = fix(lat: 51.5, lng: -0.12)
        // ~111 m north.
        let moved = fix(lat: 51.501, lng: -0.12)
        XCTAssertTrue(BackgroundLocationService.shouldReport(
            moved, lastReported: last, lastReportAt: base, now: base.addingTimeInterval(30)))
    }

    func testGPSJitterUnderTheThresholdIsIgnored() {
        let last = fix(lat: 51.5, lng: -0.12)
        // ~11 m: inside the 75 m threshold.
        let jitter = fix(lat: 51.5001, lng: -0.12)
        XCTAssertFalse(BackgroundLocationService.shouldReport(
            jitter, lastReported: last, lastReportAt: base, now: base.addingTimeInterval(30)))
    }

    func testDistanceIsRoughlyRight() {
        // One degree of latitude is ~111 km.
        let metres = BackgroundLocationService.distanceMeters(
            fix(lat: 51.0, lng: 0), fix(lat: 52.0, lng: 0))
        XCTAssertEqual(metres, 111_195, accuracy: 500)
    }

    // MARK: Posting

    func testAFixIsPostedInTheServersShape() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["ok": true])
        let service = BackgroundLocationService(api: api, preferences: MemoryKeyValueStore(),
                                                monitor: FakeLocationMonitor(), now: { self.base })

        await service.report(fix(lat: 51.5, lng: -0.12, accuracy: 12))

        XCTAssertEqual(transport.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(transport.lastRequest?.url?.path, "/api/devices/mobile/location")
        let body = transport.lastBody()
        XCTAssertEqual(body["lat"] as? Double, 51.5)
        XCTAssertEqual(body["lng"] as? Double, -0.12)
        XCTAssertEqual(body["accuracy"] as? Double, 12)
        XCTAssertEqual(body["ts"] as? Double, base.timeIntervalSince1970,
                       "the fix's own timestamp, not now — a queued SLC fix can be minutes old")
    }

    func testFixesArriveOnlyAfterTrackingIsSwitchedOn() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/devices/mobile/location", json: ["ok": true])
        let monitor = FakeLocationMonitor()
        let service = BackgroundLocationService(api: api, preferences: MemoryKeyValueStore(),
                                                monitor: monitor, now: { self.base })

        monitor.emit(fix())
        XCTAssertTrue(transport.requests.isEmpty, "off means off — no fix leaves the device")

        let enabled = await service.setEnabled(true)
        XCTAssertTrue(enabled)
        monitor.emit(fix())
        await servicesWaitUntil { !transport.requests.isEmpty }
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(monitor.starts, 1)
    }

    func testRefusedAlwaysPermissionLeavesTrackingOff() async {
        let monitor = FakeLocationMonitor()
        monitor.authorized = false
        let (api, _) = JarvisAPI.mocked()
        let service = BackgroundLocationService(api: api, preferences: MemoryKeyValueStore(),
                                                monitor: monitor, now: { self.base })

        let enabled = await service.setEnabled(true)
        XCTAssertFalse(enabled, "the switch must not claim the app is tracking when it can't")
        XCTAssertFalse(service.enabled)
        XCTAssertEqual(monitor.starts, 0)
    }

    func testADeviceWithoutSignificantChangeMonitoringCannotEnable() async {
        let monitor = FakeLocationMonitor()
        monitor.isAvailable = false
        let (api, _) = JarvisAPI.mocked()
        let service = BackgroundLocationService(api: api, preferences: MemoryKeyValueStore(),
                                                monitor: monitor, now: { self.base })
        let enabled = await service.setEnabled(true)
        XCTAssertFalse(enabled)
        XCTAssertEqual(monitor.authorizationRequests, 0, "don't prompt for something we can't do")
    }

    func testSwitchingOffStopsTheMonitor() async {
        let monitor = FakeLocationMonitor()
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/devices/mobile/location", json: ["ok": true])
        let service = BackgroundLocationService(api: api, preferences: MemoryKeyValueStore(),
                                                monitor: monitor, now: { self.base })
        _ = await service.setEnabled(true)
        _ = await service.setEnabled(false)

        XCTAssertEqual(monitor.stops, 1)
        monitor.emit(fix(lat: 1, lng: 1))
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testLaunchReArmsOnlyWhenTheUserLeftTrackingOn() {
        let monitor = FakeLocationMonitor()
        let (api, _) = JarvisAPI.mocked()

        let off = BackgroundLocationService(api: api, preferences: MemoryKeyValueStore(),
                                            monitor: monitor, now: { self.base })
        off.startIfEnabled()
        XCTAssertEqual(monitor.starts, 0)

        let onMonitor = FakeLocationMonitor()
        let on = BackgroundLocationService(
            api: api,
            preferences: MemoryKeyValueStore([SettingsStore.Keys.trackLocation: true]),
            monitor: onMonitor, now: { self.base })
        on.startIfEnabled()
        XCTAssertEqual(onMonitor.starts, 1, "iOS relaunches us for a location event after a force-quit")
        XCTAssertTrue(on.enabled)
    }

    func testConsecutiveJitterFixesProduceASinglePost() async {
        let monitor = FakeLocationMonitor()
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/devices/mobile/location", json: ["ok": true])
        let service = BackgroundLocationService(api: api, preferences: MemoryKeyValueStore(),
                                                monitor: monitor, now: { self.base })
        _ = await service.setEnabled(true)

        monitor.emit(fix(lat: 51.5, lng: -0.12))
        await servicesWaitUntil { !transport.requests.isEmpty }
        monitor.emit(fix(lat: 51.5001, lng: -0.12))
        monitor.emit(fix(lat: 51.5, lng: -0.1201))

        XCTAssertEqual(transport.requests.count, 1)
    }

    // MARK: - Authorization deadline (swift-correctness C4)

    /// iOS silently NO-OPS an authorization request it considers already
    /// answered, and `locationManagerDidChangeAuthorization` never fires. Without
    /// a deadline the Settings toggle awaits forever and the continuation leaks.
    func testWaitingForAuthorizationGivesUpInsteadOfHangingForever() async {
        let monitor = DefaultLocationMonitor(authorizationTimeout: 0.05)
        let granted = await monitor.waitForAuthorization()
        XCTAssertFalse(granted, "nothing granted it — answer with what we can read")
    }

    /// Switching the toggle back off while a prompt is parked must not strand
    /// the waiter: an abandoned `CheckedContinuation` is a leak, not a no-op.
    func testTearingDownMonitoringResumesAParkedWaiter() async {
        let monitor = DefaultLocationMonitor(authorizationTimeout: 30)
        async let waited = monitor.waitForAuthorization()
        // Let the waiter park before tearing down.
        try? await Task.sleep(nanoseconds: 20_000_000)
        monitor.stopMonitoring()
        let granted = await waited
        XCTAssertFalse(granted)
    }

    func testOnlyRealGrantsCountAsAuthorized() {
        XCTAssertTrue(DefaultLocationMonitor.isGranted(.authorizedAlways))
        XCTAssertTrue(DefaultLocationMonitor.isGranted(.authorizedWhenInUse))
        XCTAssertFalse(DefaultLocationMonitor.isGranted(.denied))
        XCTAssertFalse(DefaultLocationMonitor.isGranted(.restricted))
        XCTAssertFalse(DefaultLocationMonitor.isGranted(.notDetermined))
    }

    func testTheDeadlineIsTenSecondsByDefault() {
        XCTAssertEqual(DefaultLocationMonitor.authorizationTimeout, 10,
                       "long enough for a real prompt, short enough that a toggle answers")
    }
}

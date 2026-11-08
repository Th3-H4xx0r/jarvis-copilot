import XCTest
@testable import JarvisCopilot

/// The on-demand link rules every BLE wearable shares (OnDemandWearable).
@MainActor
final class OnDemandWearableTests: XCTestCase {
    private final class FakeWearable: OnDemandWearable {
        var state: ConnectionState = .idle
        var bluetoothReady = true
        var linkIsUp: Bool { state == .connecting || state == .discovering || state == .ready }
        let linkLogName = "fake"
        var keepAliveEnabled = false
        var screenIsOpen = false
        var healthIsOpen = false
        var holdsLinkForWorkout = false
        var isWorking = false
        var isSettingUp = false
        var idleDropTask: Task<Void, Never>?
        var linkStarts = 0
        var onStart: (FakeWearable) -> Void = { _ in }
        func startLink() { linkStarts += 1; onStart(self) }
        func dropIdleLink() async {}
    }

    func testAFailedConnectEndsTheWaitAtOnce() async {
        let device = FakeWearable()
        device.onStart = { $0.state = .failed("refused") }
        let started = Date()
        let ok = await device.ensureConnected(timeout: 12)
        XCTAssertFalse(ok)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "a failed connect must not wait out the timeout")
    }

    func testAReadyLinkNeedsNoConnect() async {
        let device = FakeWearable()
        device.state = .ready
        let ok = await device.ensureConnected()
        XCTAssertTrue(ok)
        XCTAssertEqual(device.linkStarts, 0)
    }

    func testNoBluetoothMeansNoConnect() async {
        let device = FakeWearable()
        device.bluetoothReady = false
        let ok = await device.ensureConnected()
        XCTAssertFalse(ok)
        XCTAssertEqual(device.linkStarts, 0)
    }

    func testEveryHoldKeepsTheLink() {
        for hold in [\FakeWearable.keepAliveEnabled, \.screenIsOpen, \.healthIsOpen, \.holdsLinkForWorkout] {
            let device = FakeWearable()
            device[keyPath: hold] = true
            device.releaseIfIdle()
            XCTAssertNil(device.idleDropTask, "\(hold) must hold the link")
        }
    }

    func testWithNothingHoldingItTheIdleDropStarts() {
        let device = FakeWearable()
        device.releaseIfIdle()
        XCTAssertNotNil(device.idleDropTask)
        device.idleDropTask?.cancel()
    }

    func testTakingAHoldCancelsAPendingDrop() {
        let device = FakeWearable()
        device.releaseIfIdle()
        device.screenIsOpen = true
        device.holdChanged(true)
        XCTAssertNil(device.idleDropTask)
    }

    func testAHoldThatAsksBringsTheLinkUp() async {
        let device = FakeWearable()
        device.onStart = { $0.state = .ready }
        device.healthIsOpen = true
        device.holdChanged(true, connectIfDown: true)
        for _ in 0..<20 where device.state != .ready { try? await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(device.linkStarts, 1)
        XCTAssertEqual(device.state, .ready)
    }
}

import Foundation
import XCTest
@testable import JarvisCopilot

/// "Smart" keepalive (Oct 18): awake in use and 30 min after, on Wi‑Fi, charging, in the car or a
/// workout; asleep out on cellular when idle.
final class SmartKeepaliveTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func pocket(onWiFi: Bool = false) -> KeepalivePolicy {
        var p = KeepalivePolicy()
        p.foreground = false
        p.onWiFi = onWiFi
        return p
    }

    func testOnCellularItSleepsHalfAnHourAfterTheScreen() {
        var p = pocket()
        p.lastUse = t0
        XCTAssertTrue(p.wantsAwake(at: t0.addingTimeInterval(29 * 60)))
        XCTAssertFalse(p.wantsAwake(at: t0.addingTimeInterval(30 * 60)))
        XCTAssertEqual(p.expiry(after: t0.addingTimeInterval(60)), t0.addingTimeInterval(KeepalivePolicy.idleGrace))
        XCTAssertNil(p.expiry(after: t0.addingTimeInterval(31 * 60)), "already past: nothing to wait for")
    }

    func testEachReasonToStayHoldsItPastTheHalfHour() {
        let late = t0.addingTimeInterval(3 * 3600)
        var base = pocket()
        base.lastUse = t0
        XCTAssertFalse(base.wantsAwake(at: late))
        for reason in [\KeepalivePolicy.onWiFi, \.charging, \.inCar, \.workout, \.foreground] {
            var p = base
            p[keyPath: reason] = true
            XCTAssertTrue(p.wantsAwake(at: late), "\(reason)")
            XCTAssertNil(p.expiry(after: late), "held: the clock doesn't end it")
        }
    }

    func testABackgroundLaunchWithNoUseSleepsOnCellular() {
        XCTAssertFalse(pocket().wantsAwake(at: t0))
        XCTAssertTrue(pocket(onWiFi: true).wantsAwake(at: t0))
    }

    @MainActor
    func testLeavingTheScreenStartsTheHalfHourAndFlipsOnlyOnChange() {
        var now = t0
        var voice = false
        var power = false
        let smart = SmartKeepalive(clock: { now }, voiceLive: { voice }, onPower: { power })
        var changes = 0
        smart.onChange = { changes += 1 }
        smart.update { $0.onWiFi = false }
        XCTAssertTrue(smart.wantsAwake, "still on screen")
        smart.setForeground(false)
        XCTAssertEqual(smart.policy.lastUse, t0)
        XCTAssertTrue(smart.wantsAwake)
        XCTAssertEqual(changes, 0, "no flip yet")

        now = t0.addingTimeInterval(31 * 60)
        XCTAssertFalse(smart.wantsAwake)
        smart.refresh()                               // a background wake asks again
        XCTAssertEqual(changes, 1, "slept")

        power = true                                  // plugged in while asleep
        smart.refresh()
        XCTAssertTrue(smart.wantsAwake)
        XCTAssertEqual(changes, 2, "woke")
        power = false
        smart.refresh()
        XCTAssertEqual(changes, 3, "slept again")

        smart.update { $0.onWiFi = true }             // home
        XCTAssertTrue(smart.wantsAwake)
        XCTAssertEqual(changes, 4, "woke")

        smart.update { $0.onWiFi = false }
        XCTAssertEqual(changes, 5)
        voice = true                                  // a background voice turn counts as use
        smart.refresh()
        XCTAssertEqual(smart.policy.lastUse, now)
        XCTAssertTrue(smart.wantsAwake)
    }

    func testTheWorkoutPhaseSaysWhenOneIsUnderWay() {
        XCTAssertTrue(RingWorkoutController.Phase.running.isActive)
        XCTAssertTrue(RingWorkoutController.Phase.countdown(3).isActive)
        XCTAssertFalse(RingWorkoutController.Phase.idle.isActive)
        XCTAssertFalse(RingWorkoutController.Phase.failed("x").isActive)
    }
}

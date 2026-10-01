import HealthKit
import XCTest
@testable import JarvisCopilot

/// Which ring Jarvis Health reads, chosen in Health settings.
@MainActor
final class HealthRingTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "HealthRingTests-\(UUID().uuidString)")
    }

    func testWithNothingPairedItIsTheR12() {
        XCTAssertEqual(HealthRing.current(defaults: defaults), .r12)
    }

    func testAnX5OnItsOwnIsTheHealthRing() {
        WearableIdentity.remember("x5-id", for: WearableKeepAlive.x5ring, defaults: defaults)
        XCTAssertEqual(HealthRing.current(defaults: defaults), .x5)
    }

    func testWithBothPairedTheR12StaysUntilChosen() {
        WearableIdentity.remember("r12-id", for: WearableKeepAlive.ring, defaults: defaults)
        WearableIdentity.remember("x5-id", for: WearableKeepAlive.x5ring, defaults: defaults)
        XCTAssertEqual(HealthRing.current(defaults: defaults), .r12)
        HealthRing.set(.x5, defaults: defaults)
        XCTAssertEqual(HealthRing.current(defaults: defaults), .x5)
        HealthRing.set(.r12, defaults: defaults)
        XCTAssertEqual(HealthRing.current(defaults: defaults), .r12)
    }

    /// Switching rings only changes which one leads: both stay linked on the server, so the
    /// other ring's history keeps showing and its days keep filling the gaps.
    func testBothRingsStayLinkedAndOnlyTheChosenOneIsPrimary() {
        let x5 = HealthRing.serverFlags(for: WearableKeepAlive.x5ring, chosen: .x5)
        let r12 = HealthRing.serverFlags(for: WearableKeepAlive.ring, chosen: .x5)
        XCTAssertEqual(x5["linked"] as? Bool, true)
        XCTAssertEqual(x5["primary"] as? Bool, true)
        XCTAssertEqual(r12["linked"] as? Bool, true)
        XCTAssertEqual(r12["primary"] as? Bool, false)
    }

    /// The R12's Apple Health ids never change (that would duplicate its history); the X5's are
    /// its own, so the two rings can never overwrite each other's samples.
    func testAppleHealthIdsKeepTheR12sAndTagTheX5s() {
        let samples = [AppleHealthSample(value: .quantity(.heartRate, unit: AppleHealthPlan.bpm, value: 60),
                                         start: Date(), end: Date(), syncID: "jarvis-hr-20240827-541")]
        XCTAssertEqual(AppleHealthPlan.tagged(samples, ring: .r12).map(\.syncID), ["jarvis-hr-20240827-541"])
        XCTAssertEqual(AppleHealthPlan.tagged(samples, ring: .x5).map(\.syncID), ["x5-jarvis-hr-20240827-541"])
    }
}

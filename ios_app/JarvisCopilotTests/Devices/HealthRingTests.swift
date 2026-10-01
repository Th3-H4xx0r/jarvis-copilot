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

    /// Only the chosen ring is registered with Jarvis Health; the scale always is.
    func testOnlyTheChosenRingIsEligible() {
        XCTAssertEqual(HealthRing.eligibleKinds(chosen: .x5), [WearableKeepAlive.x5ring, WearableKeepAlive.scale])
        XCTAssertEqual(HealthRing.eligibleKinds(chosen: .r12), [WearableKeepAlive.ring, WearableKeepAlive.scale])
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

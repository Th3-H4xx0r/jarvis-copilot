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

    /// The chosen ring is linked and primary; another's link is left to the person's switch, so
    /// re-registering on launch never turns a wearable they switched off back on.
    func testOnlyTheChosenRingIsLinkedAndPrimaryTheOthersKeepTheirSwitch() {
        let band = HealthRing.serverFlags(for: WearableKeepAlive.band, chosen: .band)
        let x5 = HealthRing.serverFlags(for: WearableKeepAlive.x5ring, chosen: .band)
        XCTAssertEqual(band["linked"] as? Bool, true)
        XCTAssertEqual(band["primary"] as? Bool, true)
        XCTAssertNil(x5["linked"], "not re-linked: that is the person's switch")
        XCTAssertEqual(x5["primary"] as? Bool, false)
    }

    func testAServerDeviceKeyNamesItsRing() {
        XCTAssertEqual(HealthRing.ring(forDeviceKey: "band-1a2b3c4d"), .band)
        XCTAssertEqual(HealthRing.ring(forDeviceKey: "x5ring-00ff00ff"), .x5)
        XCTAssertEqual(HealthRing.ring(forDeviceKey: "ring-b6ce93c4"), .r12)
        XCTAssertNil(HealthRing.ring(forDeviceKey: "scale-12345678"))
    }

    func testAdoptingAPrimaryChosenElsewhereSticks() {
        let defaults = UserDefaults(suiteName: "adopt-\(UUID().uuidString)")!
        HealthRing.set(.x5, defaults: defaults)
        HealthRing.adopt(.band, defaults: defaults)
        XCTAssertEqual(HealthRing.current(defaults: defaults), .band)
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

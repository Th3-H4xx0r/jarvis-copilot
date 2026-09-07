import XCTest
@testable import JarvisCopilot

/// Per-device "Connection Keep Alive". Off means nothing reconnects on its
/// own — the bottle was buzzing every time the app quietly brought the link
/// back — while on-demand connects still work.
final class WearableKeepAliveTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "keepalive-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaults.description)
        super.tearDown()
    }

    func testItDefaultsToOnSoNothingChangesForAnExistingInstall() {
        XCTAssertTrue(WearableKeepAlive.isOn(WearableKeepAlive.bottle, defaults: defaults))
        XCTAssertTrue(WearableKeepAlive.isOn(WearableKeepAlive.scale, defaults: defaults))
        XCTAssertTrue(WearableKeepAlive.isOn(WearableKeepAlive.esp32, defaults: defaults))
    }

    func testTheSettingRoundTrips() {
        WearableKeepAlive.set(false, for: WearableKeepAlive.bottle, defaults: defaults)
        XCTAssertFalse(WearableKeepAlive.isOn(WearableKeepAlive.bottle, defaults: defaults))
        WearableKeepAlive.set(true, for: WearableKeepAlive.bottle, defaults: defaults)
        XCTAssertTrue(WearableKeepAlive.isOn(WearableKeepAlive.bottle, defaults: defaults))
    }

    func testEachDeviceIsIndependent() {
        WearableKeepAlive.set(false, for: WearableKeepAlive.bottle, defaults: defaults)
        XCTAssertFalse(WearableKeepAlive.isOn(WearableKeepAlive.bottle, defaults: defaults))
        XCTAssertTrue(WearableKeepAlive.isOn(WearableKeepAlive.scale, defaults: defaults),
                      "turning the bottle off must not silence the scale")
    }

    func testTheIdleGraceIsLongEnoughToShareOneLinkAcrossABurst() {
        XCTAssertGreaterThanOrEqual(WearableKeepAlive.idleGraceSeconds, 10)
    }
}

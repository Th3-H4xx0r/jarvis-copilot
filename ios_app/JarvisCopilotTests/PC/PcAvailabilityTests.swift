import XCTest
@testable import JarvisCopilot

/// One rule for "are the lights Jarvis's to show right now" — the section, the model and the card use it.
final class PcAvailabilityTests: XCTestCase {
    func testAsleepOrOfflineIsUnavailable() {
        XCTAssertEqual(PcLightingAvailability.status(online: false, awake: true, mapped: true, engine: "running",
                                                     engineError: nil, controllers: 1), .unavailable("The PC is asleep or offline"))
        XCTAssertEqual(PcLightingAvailability.status(online: true, awake: false, mapped: true, engine: "running",
                                                     engineError: nil, controllers: 1), .unavailable("The PC is asleep or offline"))
    }

    func testOpenRGBErrorIsUnavailableWithItsReason() {
        XCTAssertEqual(PcLightingAvailability.status(online: true, awake: true, mapped: true, engine: "error",
                                                     engineError: "Can't reach OpenRGB", controllers: 0), .unavailable("Can't reach OpenRGB"))
    }

    func testNotMappedOrNoControllersNeedsSetup() {
        XCTAssertEqual(PcLightingAvailability.status(online: true, awake: true, mapped: false, engine: "running",
                                                     engineError: nil, controllers: 1), .setUp)
        XCTAssertEqual(PcLightingAvailability.status(online: true, awake: true, mapped: true, engine: "running",
                                                     engineError: nil, controllers: 0), .setUp)
    }

    func testLiveOnlyWhenEverythingIsUp() {
        XCTAssertEqual(PcLightingAvailability.status(online: true, awake: true, mapped: true, engine: "running",
                                                     engineError: nil, controllers: 1), .live)
        XCTAssertNotEqual(PcLightingAvailability.status(online: true, awake: true, mapped: true, engine: "stopped",
                                                        engineError: nil, controllers: 1), .live)
    }
}

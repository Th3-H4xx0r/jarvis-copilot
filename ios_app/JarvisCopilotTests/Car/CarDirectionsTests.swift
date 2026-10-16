import XCTest
@testable import JarvisCopilot

/// Voice directions in the car: which app, which place, and when the map opens.
@MainActor
final class CarDirectionsTests: XCTestCase {

    func testURLsPerApp() {
        XCTAssertEqual(CarMapsApp.google.url(latitude: 29.760427, longitude: -95.369803).absoluteString,
                       "comgooglemaps://?daddr=29.760427,-95.369803&directionsmode=driving")
        XCTAssertEqual(CarMapsApp.apple.url(latitude: 29.760427, longitude: -95.369803).absoluteString,
                       "maps://?daddr=29.760427,-95.369803&dirflg=d")
        XCTAssertEqual(CarMapsApp.waze.url(latitude: 29.760427, longitude: -95.369803).absoluteString,
                       "waze://?ll=29.760427,-95.369803&navigate=yes")
    }

    func testDefaultAppIsGoogle() {
        let prefs = MemoryKeyValueStore()
        XCTAssertEqual(CarMapsApp.current(prefs), .google)
        prefs.set("waze", forKey: CarMapsApp.key)
        XCTAssertEqual(CarMapsApp.current(prefs), .waze)
        prefs.set("bogus", forKey: CarMapsApp.key)
        XCTAssertEqual(CarMapsApp.current(prefs), .google)
    }

    func testClosestPicksNearest() {
        let far = CarPlace(name: "Costco", street: "Gessner Rd", address: "far", latitude: 1, longitude: 1, meters: 9000)
        let near = CarPlace(name: "Costco", street: "Richmond Ave", address: "near", latitude: 2, longitude: 2, meters: 3100)
        XCTAssertEqual(CarPlace.closest([far, near])?.address, "near")
        XCTAssertNil(CarPlace.closest([]))
    }

    func testDistanceInMiles() {
        let place = CarPlace(name: "Costco", street: "", address: "", latitude: 0, longitude: 0, meters: 6437.4)
        XCTAssertEqual(place.miles, 4.0)
    }

    // MARK: - Handoff: Maps opens once Jarvis has said where it's going

    private let url = URL(string: "comgooglemaps://?daddr=1,2&directionsmode=driving")!

    func testHandoffOpensAfterTurnFinished() {
        var opened: [URL] = []
        let handoff = CarHandoff(cap: 60, open: { opened.append($0) }, sessionActive: { true })
        handoff.queue(url)
        XCTAssertEqual(opened, [], "not while Jarvis is still talking")
        handoff.turnFinished()
        XCTAssertEqual(opened, [url])
        handoff.turnFinished()
        XCTAssertEqual(opened, [url], "once")
    }

    func testHandoffDroppedOnStop() {
        var opened: [URL] = []
        let handoff = CarHandoff(cap: 60, open: { opened.append($0) }, sessionActive: { true })
        handoff.queue(url)
        handoff.stopped()
        handoff.turnFinished()
        XCTAssertEqual(opened, [], "Stop during the line cancels the directions")
    }

    func testHandoffOpensImmediatelyWithoutSession() {
        var opened: [URL] = []
        let handoff = CarHandoff(cap: 60, open: { opened.append($0) }, sessionActive: { false })
        handoff.queue(url)
        XCTAssertEqual(opened, [url])
    }

    func testHandoffCapOpens() async {
        var opened: [URL] = []
        let handoff = CarHandoff(cap: 0.05, open: { opened.append($0) }, sessionActive: { true })
        handoff.queue(url)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(opened, [url], "a turn that never finishes can't swallow the directions")
    }
}

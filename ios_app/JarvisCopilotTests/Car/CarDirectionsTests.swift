import MapKit
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
        XCTAssertEqual(CarPlace.pick([far, near])?.address, "near")
        XCTAssertNil(CarPlace.pick([]))
    }

    func testAChainPicksItsNearestBranch() {
        let first = CarPlace(name: "Starbucks", street: "Main St", address: "a", latitude: 0, longitude: 0, meters: 5000)
        let nearer = CarPlace(name: "Starbucks", street: "Elm St", address: "b", latitude: 0, longitude: 0, meters: 900)
        let other = CarPlace(name: "Starbucks Reserve", street: "", address: "c", latitude: 0, longitude: 0, meters: 100)
        XCTAssertEqual(CarPlace.pick([first, nearer, other])?.address, "b")
    }

    func testANamedPlaceKeepsMapKitsMatch() {
        let match = CarPlace(name: "George Bush Intercontinental Airport", street: "", address: "IAH",
                             latitude: 0, longitude: 0, meters: 30000)
        let nearer = CarPlace(name: "Bush Park", street: "", address: "park", latitude: 0, longitude: 0, meters: 2000)
        XCTAssertEqual(CarPlace.pick([match, nearer])?.address, "IAH", "the place he named, not a nearer partial match")
        XCTAssertNil(CarPlace.pick([]))
    }

    func testOnlyNoResultsMeansNothingFound() {
        XCTAssertTrue(CarDirections.isNothingFound(MKError(.placemarkNotFound)))
        XCTAssertFalse(CarDirections.isNothingFound(URLError(.notConnectedToInternet)),
                       "a failed search must not be reported as no such place")
    }

    func testDistanceInMiles() {
        let place = CarPlace(name: "Costco", street: "", address: "", latitude: 0, longitude: 0, meters: 6437.4)
        XCTAssertEqual(place.miles, 4.0)
    }

    // MARK: - Handoff: Maps opens once Jarvis has said where it's going

    private let url = URL(string: "comgooglemaps://?daddr=1,2&directionsmode=driving")!

    /// Records opens; `failing` URLs report that the car screen couldn't open them.
    private func opener(_ opened: @escaping (URL) -> Void, failing: Set<String> = [])
    -> (URL, @escaping (Bool) -> Void) -> Void {
        { url, done in opened(url); done(!failing.contains(url.scheme ?? "")) }
    }

    func testAMapThatWontOpenFallsBackToAppleMaps() {
        var opened: [URL] = []
        let handoff = CarHandoff(cap: 60, open: opener({ opened.append($0) }, failing: ["comgooglemaps"]),
                                 sessionActive: { false })
        let apple = URL(string: "maps://?daddr=1,2&dirflg=d")!
        handoff.queue(url, fallback: apple)
        XCTAssertEqual(opened, [url, apple], "announced directions must open somewhere")
    }

    func testHandoffOpensAfterTurnFinished() {
        var opened: [URL] = []
        let handoff = CarHandoff(cap: 60, open: opener { opened.append($0) }, sessionActive: { true })
        handoff.queue(url)
        XCTAssertEqual(opened, [], "not while Jarvis is still talking")
        handoff.turnFinished()
        XCTAssertEqual(opened, [url])
        handoff.turnFinished()
        XCTAssertEqual(opened, [url], "once")
    }

    func testHandoffDroppedOnStop() {
        var opened: [URL] = []
        let handoff = CarHandoff(cap: 60, open: opener { opened.append($0) }, sessionActive: { true })
        handoff.queue(url)
        handoff.stopped()
        handoff.turnFinished()
        XCTAssertEqual(opened, [], "Stop during the line cancels the directions")
    }

    func testHandoffOpensImmediatelyWithoutSession() {
        var opened: [URL] = []
        let handoff = CarHandoff(cap: 60, open: opener { opened.append($0) }, sessionActive: { false })
        handoff.queue(url)
        XCTAssertEqual(opened, [url])
    }

    func testHandoffCapOpens() async {
        var opened: [URL] = []
        let handoff = CarHandoff(cap: 0.05, open: opener { opened.append($0) }, sessionActive: { true })
        handoff.queue(url)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(opened, [url], "a turn that never finishes can't swallow the directions")
    }
}

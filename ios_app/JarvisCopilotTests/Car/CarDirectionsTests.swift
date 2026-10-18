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

    /// The voice model opened directions with `open_url` (an Apple Maps link).
    /// With the phone locked that became a "tap to run" notification; with
    /// CarPlay up, a map link opens on the car's screen instead.
    func testMapLinksAreRecognised() throws {
        for link in ["http://maps.apple.com/?saddr=Current%20Location&daddr=Costco&dirflg=d",
                     "https://maps.apple.com/?daddr=Costco", "maps://?daddr=Costco",
                     "comgooglemaps://?daddr=Costco&directionsmode=driving",
                     "https://www.google.com/maps/dir/?api=1&destination=Costco",
                     "https://maps.google.com/?daddr=Costco", "https://maps.app.goo.gl/abc123",
                     "waze://?q=Costco&navigate=yes", "https://waze.com/ul?q=Costco"] {
            XCTAssertTrue(CarLinks.isMap(try XCTUnwrap(URL(string: link))), link)
        }
        for link in ["https://www.google.com/search?q=costco", "https://example.com/maps",
                     "tel:5551234", "https://apple.com"] {
            XCTAssertFalse(CarLinks.isMap(try XCTUnwrap(URL(string: link))), link)
        }
    }

    func testAMapLinkGoesToTheCarScreenWhenCarPlayIsUp() async throws {
        var queued: [URL] = []
        let link = "http://maps.apple.com/?daddr=Costco"
        let result = try await CarLinks.route("open_url", ["url": link],
                                              carScreen: { true }, queue: { queued.append($0) })
        XCTAssertEqual(queued.map(\.absoluteString), [link])
        XCTAssertEqual(result?["launched"] as? Bool, true)
        XCTAssertNotNil(result?["note"], "tells Jarvis where it opened")
    }

    func testWithoutCarPlayOrForOtherLinksItStepsAside() async throws {
        var queued: [URL] = []
        let none = try await CarLinks.route("open_url", ["url": "http://maps.apple.com/?daddr=Costco"],
                                            carScreen: { false }, queue: { queued.append($0) })
        XCTAssertNil(none, "no car screen: the phone's own open_url runs")
        let web = try await CarLinks.route("open_url", ["url": "https://example.com"],
                                           carScreen: { true }, queue: { queued.append($0) })
        XCTAssertNil(web)
        let other = try await CarLinks.route("set_timer", ["url": "maps://?daddr=x"],
                                             carScreen: { true }, queue: { queued.append($0) })
        XCTAssertNil(other)
        XCTAssertEqual(queued, [])
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

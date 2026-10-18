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

    /// His drive (2026-10-18): `car_directions` opened a route; the map links the
    /// model sent itself (a text address, an empty `saddr`) opened the maps app
    /// with no route. Every link's destination now takes car_directions' path.
    func testTheDestinationIsReadFromAnyMapLink() throws {
        let cases: [(String, String?)] = [
            ("http://maps.apple.com/?saddr=Current%20Location&daddr=Costco%20Wholesale%2C%203836%20Richmond%20Ave%2C%20Houston%2C%20TX%2077027&dirflg=d",
             "Costco Wholesale, 3836 Richmond Ave, Houston, TX 77027"),
            ("https://www.google.com/maps/dir/?api=1&origin=Current+Location&destination=Costco+Wholesale+3836+Richmond+Ave+Houston+TX+77027&travelmode=driving",
             "Costco Wholesale 3836 Richmond Ave Houston TX 77027"),
            ("comgooglemaps://?saddr=&daddr=Costco+Wholesale+3836+Richmond+Ave+Houston+TX+77027&directionsmode=driving",
             "Costco Wholesale 3836 Richmond Ave Houston TX 77027"),
            ("https://www.google.com/maps/dir/Current+Location/Costco+Wholesale/", "Costco Wholesale"),
            ("https://www.google.com/maps/place/Costco+Wholesale/@29.73,-95.43,15z", "Costco Wholesale"),
            ("https://maps.apple.com/?q=Costco", "Costco"),
            ("waze://?q=Costco&navigate=yes", "Costco"),
            ("https://maps.app.goo.gl/abc123", nil),
        ]
        for (link, want) in cases {
            XCTAssertEqual(CarLinks.destination(in: try XCTUnwrap(URL(string: link))), want, link)
        }
    }

    func testAMapLinkTakesTheSameRouteAsCarDirections() async throws {
        var asked: [String] = []
        var queued: [URL] = []
        let result = try await CarLinks.route(
            "open_url", ["url": "http://maps.apple.com/?saddr=Current%20Location&daddr=Costco&dirflg=d"],
            carScreen: { true },
            directions: { asked.append($0); return ["ok": true, "place": "Costco Wholesale", "app": "Google Maps"] },
            queue: { queued.append($0) })
        XCTAssertEqual(asked, ["Costco"])
        XCTAssertEqual(queued, [], "the link itself isn't opened: the route is")
        XCTAssertEqual(result?["launched"] as? Bool, true)
        XCTAssertEqual(result?["place"] as? String, "Costco Wholesale")
        XCTAssertNotNil(result?["note"], "tells Jarvis where it opened")
    }

    func testALinkWithNoPlaceOrAPlaceNotFoundStillOpensAsIs() async throws {
        var queued: [URL] = []
        let short = "https://maps.app.goo.gl/abc123"
        _ = try await CarLinks.route("open_url", ["url": short], carScreen: { true },
                                     directions: { _ in XCTFail("nothing to search"); return [:] },
                                     queue: { queued.append($0) })
        let unknown = "maps://?daddr=Nowhere%20Special"
        let result = try await CarLinks.route("open_url", ["url": unknown], carScreen: { true },
                                              directions: { _ in throw DeviceError.badArgument("Couldn't find it") },
                                              queue: { queued.append($0) })
        XCTAssertEqual(queued.map(\.absoluteString), [short, unknown])
        XCTAssertEqual(result?["launched"] as? Bool, true)
    }

    /// "Call Shabd" from the car (2026-10-18 00:25): `make_call` became "tap the
    /// notification". In CarPlay a `tel:` link opened on the car's screen places the
    /// call there — after Jarvis says who it's calling, and Stop still cancels it.
    func testACallIsPlacedFromTheCarScreen() async throws {
        var queued: [URL] = []
        let noRoute: (String) async throws -> [String: Any] = { _ in XCTFail("not a map"); return [:] }
        let result = try await CarLinks.route("make_call", ["number": "(209) 627-7732"], carScreen: { true },
                                              directions: noRoute, queue: { queued.append($0) })
        _ = try await CarLinks.route("make_call", ["number": "+1 209 627 7732"], carScreen: { true },
                                     directions: noRoute, queue: { queued.append($0) })
        XCTAssertEqual(queued.map(\.absoluteString), ["tel:2096277732", "tel:+12096277732"])
        XCTAssertEqual(result?["launched"] as? Bool, true)
        XCTAssertNotNil(result?["note"])
        let nothing = try await CarLinks.route("make_call", ["number": "mom"], carScreen: { true },
                                               directions: noRoute, queue: { queued.append($0) })
        XCTAssertNil(nothing, "no digits: the phone's own make_call answers")
    }

    /// "Text Shabd hello" (2026-10-18 01:19): `send_sms` became "tap the notification".
    /// iOS never sends a text silently; the Mac sends it as him when it can, and on
    /// CarPlay the phone's way is the message opened, filled in, on the car's screen
    /// for him to confirm.
    func testATextOpensFilledInOnTheCarScreen() async throws {
        var queued: [URL] = []
        let noRoute: (String) async throws -> [String: Any] = { _ in XCTFail("not a map"); return [:] }
        let result = try await CarLinks.route("send_sms", ["number": "2096277732", "message": "hello there"],
                                              carScreen: { true }, directions: noRoute, queue: { queued.append($0) })
        XCTAssertEqual(queued.map(\.absoluteString), ["sms:2096277732&body=hello%20there"])
        XCTAssertEqual(result?["launched"] as? Bool, true)
        XCTAssertNotNil(result?["note"], "tells Jarvis he confirms it on the car's screen")
        let none = try await CarLinks.route("send_sms", ["number": "", "message": "hi"], carScreen: { true },
                                            directions: noRoute, queue: { queued.append($0) })
        XCTAssertNil(none)
    }

    /// "Play Blinding Lights" (2026-10-18 06:36): Spotify opened only after the reply,
    /// and opened idle it never shows up for the server to play on. The server now
    /// sends the song's own link marked `now`: it opens on the car's screen at once,
    /// and Spotify starts it. Unmarked, a car app's link still waits for the reply.
    func testACarAppLinkMarkedNowOpensOnTheCarScreenAtOnce() async throws {
        var queued: [URL] = []
        var opened: [URL] = []
        let noRoute: (String) async throws -> [String: Any] = { _ in XCTFail("not a map"); return [:] }
        let song = "spotify:track:0VjIjW4GlUZAMYd2vXMi3b"
        let result = try await CarLinks.route("open_url", ["url": song, "now": true], carScreen: { true },
                                              directions: noRoute, queue: { queued.append($0) },
                                              openNow: { opened.append($0) })
        XCTAssertEqual(opened.map(\.absoluteString), [song])
        XCTAssertEqual(queued, [])
        XCTAssertEqual(result?["launched"] as? Bool, true)
        _ = try await CarLinks.route("open_url", ["url": song], carScreen: { true },
                                     directions: noRoute, queue: { queued.append($0) },
                                     openNow: { opened.append($0) })
        XCTAssertEqual(queued.map(\.absoluteString), [song], "unmarked: after the reply")
        XCTAssertEqual(opened.count, 1)
    }

    /// "Open Spotify" became "tap the notification" too — so a play request had no
    /// Spotify to play on. A CarPlay app opens on the car's screen instead.
    func testACarPlayAppOpensOnTheCarScreen() async throws {
        var queued: [URL] = []
        let noRoute: (String) async throws -> [String: Any] = { _ in XCTFail("not a map"); return [:] }
        for (args, want) in [(["app": "spotify"], "spotify://"), (["app": "Apple Music"], "music://"),
                             (["name": "Waze"], "waze://"), (["app": "x", "scheme_url": "spotify://"], "spotify://")] {
            let result = try await CarLinks.route("open_app", args, carScreen: { true },
                                                  directions: noRoute, queue: { queued.append($0) })
            XCTAssertEqual(result?["launched"] as? Bool, true, "\(args)")
            XCTAssertEqual(queued.last?.absoluteString, want)
        }
        queued.removeAll()
        for args in [["app": "instagram"], ["app": "x", "scheme_url": "shortcuts://x-callback-url/run-shortcut?name=x"]] {
            let result = try await CarLinks.route("open_app", args, carScreen: { true },
                                                  directions: noRoute, queue: { queued.append($0) })
            XCTAssertNil(result, "not a CarPlay app: the phone's own open_app answers")
        }
        XCTAssertEqual(queued, [])
    }

    func testWithoutCarPlayOrForOtherLinksItStepsAside() async throws {
        var queued: [URL] = []
        let noRoute: (String) async throws -> [String: Any] = { _ in XCTFail("no route expected"); return [:] }
        let none = try await CarLinks.route("open_url", ["url": "http://maps.apple.com/?daddr=Costco"],
                                            carScreen: { false }, directions: noRoute, queue: { queued.append($0) })
        XCTAssertNil(none, "no car screen: the phone's own open_url runs")
        let web = try await CarLinks.route("open_url", ["url": "https://example.com"],
                                           carScreen: { true }, directions: noRoute, queue: { queued.append($0) })
        XCTAssertNil(web)
        let other = try await CarLinks.route("set_timer", ["url": "maps://?daddr=x"],
                                             carScreen: { true }, directions: noRoute, queue: { queued.append($0) })
        XCTAssertNil(other)
        let call = try await CarLinks.route("make_call", ["number": "2096277732"],
                                            carScreen: { false }, directions: noRoute, queue: { queued.append($0) })
        XCTAssertNil(call, "no car screen: the phone's own make_call runs")
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

    /// Anything handed to the car's screen ends the voice conversation after its reply.
    func testQueuingAHandoffEndsTheConversationAfterTheReply() {
        var ended = 0
        let handoff = CarHandoff(cap: 60, open: opener { _ in }, sessionActive: { true })
        handoff.onQueued = { ended += 1 }
        handoff.queue(url)
        XCTAssertEqual(ended, 1)
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

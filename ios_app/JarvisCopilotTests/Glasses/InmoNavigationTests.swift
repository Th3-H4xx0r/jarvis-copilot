import XCTest
import CoreLocation
@testable import JarvisCopilot

final class InmoNavigationTests: XCTestCase {
    private func data(_ hex: String) -> Data {
        let text = hex.filter { !$0.isWhitespace }; var result = Data(); var i = text.startIndex
        while i < text.endIndex { let end = text.index(i, offsetBy: 2); result.append(UInt8(text[i..<end], radix: 16)!); i = end }; return result
    }

    // Encodings worked out from the official Android builders (inmo-re/notes/go3-navigation-flow.md §1):
    // Message{2: 33, 36: Navigation{1: subtype (omitted when 0), N: payload}}, no version field.
    func testGuidanceGoldens() {
        XCTAssertEqual(InmoNavigationWire.guide(type: 8, road: "Main St", meters: 120, countryCode: "USA"),
                       data("1021a20214 1212 0808 12074d61696e205374 1878 2203555341"))
        XCTAssertEqual(InmoNavigationWire.remaining(meters: 1234, seconds: 900, reachTime: "14:05", countryCode: "USA"),
                       data("1021a20216 0801 1a12 08d209 108407 1a0531343a3035 2203555341"))
        XCTAssertEqual(InmoNavigationWire.permission(false), data("1021a20204 0805 3a00"))
    }
    // The official app answers the glasses' supported-modules question (captured 1023b20200 → 1023b20204…);
    // Jarvis offers Navigation only.
    func testSupportedModulesAnswerOffersNavigation() {
        XCTAssertEqual(InmoNavigationWire.supportedModules([2, 3]), data("1023b202040a020203"))
        XCTAssertEqual(InmoNavigationWire.supportedModules([2]), data("1023b202030a0102"))
    }
    func testAddressesRoutePlanningAndArrival() throws {
        let list = InmoNavigationWire.addresses([.init(index: 0, type: 0, name: "Home", detail: "1 A St"),
                                                 .init(index: 7, type: 2, name: "Gym", detail: "")])
        let nav = try XCTUnwrap(try InmoWireCodec.decode(list).firstField(36)?.nested())
        XCTAssertEqual(nav.firstField(1)?.varint, 3)
        let entries = try XCTUnwrap(try nav.firstField(5)?.nested()).filter { $0.number == 1 }
        XCTAssertEqual(entries.count, 2)
        let gym = try entries[1].nested()
        XCTAssertEqual(gym.firstField(1)?.varint, 7); XCTAssertEqual(gym.firstField(2)?.varint, 2)
        XCTAssertEqual(gym.firstField(3)?.bytes, Data("Gym".utf8))
        XCTAssertEqual(InmoNavigationWire.addresses([]), data("1021a20204 0803 2a00"))

        let plan = InmoNavigationWire.routePlanning(cycling: .init(achievable: true, seconds: 300, meters: 1200),
                                                     walking: .init(achievable: false, seconds: 0, meters: 0), countryCode: "USA")
        let planned = try XCTUnwrap(try InmoWireCodec.decode(plan).firstField(36)?.nested())
        XCTAssertEqual(planned.firstField(1)?.varint, 6)
        let body = try XCTUnwrap(try planned.firstField(8)?.nested())
        let cycling = try XCTUnwrap(try body.firstField(1)?.nested())
        XCTAssertEqual(cycling.firstField(1)?.varint, 1); XCTAssertEqual(cycling.firstField(2)?.varint, 300); XCTAssertEqual(cycling.firstField(3)?.varint, 1200)
        XCTAssertEqual(try body.firstField(2)?.nested().count, 0)
        XCTAssertEqual(body.firstField(3)?.bytes, Data("USA".utf8))

        let arrived = try XCTUnwrap(try InmoWireCodec.decode(InmoNavigationWire.arrived(meters: 900, seconds: 600, countryCode: "", image: Data([1, 2]))).firstField(36)?.nested())
        XCTAssertEqual(arrived.firstField(1)?.varint, 10)
        let a = try XCTUnwrap(try arrived.firstField(12)?.nested())
        XCTAssertEqual(a.firstField(1)?.varint, 900); XCTAssertEqual(a.firstField(2)?.varint, 600); XCTAssertEqual(a.firstField(4)?.bytes, Data([1, 2]))
    }
    func testIncomingStartAndSelection() throws {
        // NAV{4 START, 6:{1: CommonlyUsedAddress{1: 7, 2: 2, 3: "Gym"}}}
        let start = InmoCommand.envelope(type: 33, field: 36, payload: InmoWireCodec.uint(1, 4)
            + InmoWireCodec.bytes(6, InmoWireCodec.bytes(1, InmoWireCodec.uint(1, 7) + InmoWireCodec.uint(2, 2) + InmoWireCodec.bytes(3, Data("Gym".utf8)))))
        XCTAssertEqual(InmoNavigationWire.incoming(try InmoWireCodec.decode(start)), .start(type: 2, index: 7))
        let home = InmoCommand.envelope(type: 33, field: 36, payload: InmoWireCodec.uint(1, 4) + InmoWireCodec.bytes(6, InmoWireCodec.bytes(1, Data())))
        XCTAssertEqual(InmoNavigationWire.incoming(try InmoWireCodec.decode(home)), .start(type: 0, index: 0))
        let walking = InmoCommand.envelope(type: 33, field: 36, payload: InmoWireCodec.uint(1, 7) + InmoWireCodec.bytes(9, InmoWireCodec.uint(1, 1)))
        XCTAssertEqual(InmoNavigationWire.incoming(try InmoWireCodec.decode(walking)), .selected(walking: true))
        let cycling = InmoCommand.envelope(type: 33, field: 36, payload: InmoWireCodec.uint(1, 7) + InmoWireCodec.bytes(9, Data()))
        XCTAssertEqual(InmoNavigationWire.incoming(try InmoWireCodec.decode(cycling)), .selected(walking: false))
        XCTAssertNil(InmoNavigationWire.incoming(try InmoWireCodec.decode(InmoCommand.home())))
    }
    // The glasses open/close their Navigation app with STARTING_APPLICATION{13, open 0 | close 1}.
    func testNavigationAppSwitchParses() throws {
        XCTAssertEqual(InmoNavigationWire.appSwitch(try InmoWireCodec.decode(data("100f920102080d"))), true)
        XCTAssertEqual(InmoNavigationWire.appSwitch(try InmoWireCodec.decode(data("100f920104080d1001"))), false)
        XCTAssertNil(InmoNavigationWire.appSwitch(try InmoWireCodec.decode(data("100f9201020804"))))
        XCTAssertEqual(InmoCommand.openModule(13), data("100f920102080d"))
    }

    // MARK: Guidance

    /// A 200 m walk due north, then a right turn and 100 m due east.
    private func lRoute() -> NavigationRoute {
        let start = CLLocationCoordinate2D(latitude: 37.0, longitude: -122.0)
        let corner = NavigationGeo.offset(start, north: 200, east: 0)
        let end = NavigationGeo.offset(corner, north: 0, east: 100)
        return NavigationRoute(steps: [
            .init(instructions: "Head north on Oak Ave", points: [start, corner]),
            .init(instructions: "Turn right onto Main St", points: [corner, end]),
            .init(instructions: "Arrive at the destination", points: [end, end]),
        ], expectedTime: 300)
    }
    func testGuidanceAnnouncesTheNextTurnAndRemaining() {
        let route = lRoute()
        var guidance = NavigationGuidance(route: route)
        let here = NavigationGeo.offset(route.steps[0].points[0], north: 50, east: 3)
        let u = guidance.update(at: here, now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(u.guideType, 8, "right turn")
        XCTAssertEqual(u.roadName, "Main St")
        XCTAssertEqual(Double(u.toManeuver), 150, accuracy: 3)
        XCTAssertEqual(Double(u.remaining), 250, accuracy: 3)
        XCTAssertEqual(Double(u.remainingSeconds), 250, accuracy: 5)
        XCTAssertFalse(u.arrived)
        XCTAssertLessThan(u.offRoute, 5)
    }
    func testGuidanceAfterTheTurnHeadsForArrival() {
        let route = lRoute()
        var guidance = NavigationGuidance(route: route)
        let corner = route.steps[1].points[0]
        let u = guidance.update(at: NavigationGeo.offset(corner, north: 0, east: 40), now: Date())
        XCTAssertEqual(u.guideType, 1, "arrive")
        XCTAssertEqual(Double(u.toManeuver), 60, accuracy: 3)
        let done = guidance.update(at: NavigationGeo.offset(corner, north: 0, east: 95), now: Date())
        XCTAssertTrue(done.arrived)
    }
    func testGuidanceNoticesLeavingTheRoute() {
        let route = lRoute()
        var guidance = NavigationGuidance(route: route)
        let away = NavigationGeo.offset(route.steps[0].points[0], north: 100, east: -80)
        XCTAssertGreaterThan(guidance.update(at: away, now: Date()).offRoute, 70)
    }
    func testTurnClassification() {
        XCTAssertEqual(NavigationGuidance.guideType(turn: 0, instructions: "Continue on Oak"), 6)
        XCTAssertEqual(NavigationGuidance.guideType(turn: 30, instructions: "Bear right"), 7)
        XCTAssertEqual(NavigationGuidance.guideType(turn: -90, instructions: "Turn left onto 2nd"), 4)
        XCTAssertEqual(NavigationGuidance.guideType(turn: 150, instructions: "Turn sharp right"), 9)
        XCTAssertEqual(NavigationGuidance.guideType(turn: -175, instructions: "Make a U-turn"), 2)
        XCTAssertEqual(NavigationGuidance.guideType(turn: 40, instructions: "At the roundabout, take the second exit"), 21)
        XCTAssertEqual(NavigationGuidance.roadName("Turn right onto Main St"), "Main St")
        XCTAssertEqual(NavigationGuidance.roadName("Turn left"), "Turn left")
    }
    func testReachTimeIsTwentyFourHourClock() {
        XCTAssertEqual(NavigationGuidance.reachTime(Date(timeIntervalSince1970: 14 * 3600 + 5 * 60), timeZone: TimeZone(identifier: "UTC")!), "14:05")
    }
    func testMinimapIsALensSizedPNG() throws {
        let route = lRoute()
        let png = try XCTUnwrap(NavigationMinimap.render(route: route.points, position: NavigationGeo.offset(route.points[0], north: 30, east: 0), heading: 0))
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        let image = try XCTUnwrap(UIImage(data: png))
        XCTAssertEqual(image.size.width * image.scale, 211); XCTAssertEqual(image.size.height * image.scale, 121)
    }
    // The GO3 has no navigation screen (the official app only speaks); turns go out as lens cards.
    func testTurnCardsWordingAndStages() {
        let update = NavigationGuidance.Update(guideType: 8, roadName: "Austin St", toManeuver: 480, remaining: 39_576, remainingSeconds: 7860,
                                               reachTime: "17:28", offRoute: 0, arrived: false, along: 0)
        let card = NavigationCards.turn(update, imperial: true)
        XCTAssertEqual(card.title, "↱ Austin St")
        XCTAssertEqual(card.body, "0.3 mi · 24.6 mi left · ETA 17:28")
        let metric = NavigationCards.turn(update, imperial: false)
        XCTAssertEqual(metric.body, "480 m · 39.6 km left · ETA 17:28")
        XCTAssertEqual(NavigationCards.distance(40, imperial: true), "130 ft")
        XCTAssertEqual(NavigationCards.distance(15, imperial: false), "15 m")
        XCTAssertEqual(NavigationCards.stage(toManeuver: 500, walking: true), 0)
        XCTAssertEqual(NavigationCards.stage(toManeuver: 55, walking: true), 1)
        XCTAssertEqual(NavigationCards.stage(toManeuver: 12, walking: true), 2)
        XCTAssertEqual(NavigationCards.stage(toManeuver: 140, walking: false), 1)
        var arrive = update; arrive.guideType = 1; arrive.toManeuver = 12
        XCTAssertEqual(NavigationCards.turn(arrive, imperial: false).title, "Arrive · Austin St")
    }
    func testPlacesMapToLensEntriesAndBack() {
        let home = GlassesPlace(kind: .home, number: 0, name: "Home", detail: "1 A St", latitude: 1, longitude: 2)
        let gym = GlassesPlace(kind: .other, number: 7, name: "Gym", detail: "", latitude: 3, longitude: 4)
        let entries = GlassesPlaces.lensEntries([gym, home])
        XCTAssertEqual(entries.map(\.type), [0, 2], "home, work, then others — the official order")
        XCTAssertEqual(GlassesPlaces.match([gym, home], type: 2, index: 7)?.name, "Gym")
        XCTAssertEqual(GlassesPlaces.match([gym, home], type: 0, index: 0)?.name, "Home")
        XCTAssertNil(GlassesPlaces.match([gym, home], type: 1, index: 0))
    }
}

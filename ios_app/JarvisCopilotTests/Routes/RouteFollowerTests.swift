import CoreLocation
import XCTest
@testable import JarvisCopilot

/// Following a past route: where you are along it, how far is left, and
/// when you've strayed.
@MainActor
final class RouteFollowerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let metersPerDegree = RouteMathTests.metersPerDegree
    private var eastPerDegree: Double { metersPerDegree * cos(40 * .pi / 180) }

    /// North `north` m, then east `east` m, then (optionally) back south.
    private func guide(north: Double, east: Double, back: Bool = false) -> RouteGuide {
        var points: [RoutePoint] = []
        var t = 0.0
        func add(_ n: Double, _ e: Double) {
            points.append(RoutePoint(t: t, lat: 40 + n / metersPerDegree, lon: -105 + e / eastPerDegree, ele: nil, hr: nil,
                                     speed: nil))
            t += 1
        }
        for n in stride(from: 0.0, through: north, by: 10) { add(n, 0) }
        for e in stride(from: 10.0, through: east, by: 10) { add(north, e) }
        if back { for n in stride(from: north - 10, through: 0, by: -10) { add(n, east) } }
        return RouteGuide(route: WorkoutRoute(start: start, segments: [points], elevationSource: "none"), title: "Run", sport: 7)
    }

    private func at(north: Double, east: Double) -> (Double, Double) {
        (40 + north / metersPerDegree, -105 + east / eastPerDegree)
    }

    func testWhereYouAreAlongAnLShapedRoute() {
        let g = guide(north: 500, east: 500)
        XCTAssertEqual(g.total, 1000, accuracy: 2)
        XCTAssertLessThan(g.lats.count, 6, "a straight leg keeps only its ends")
        let (lat, lon) = at(north: 250, east: 10)
        let p = g.project(lat: lat, lon: lon)
        XCTAssertEqual(p.along, 250, accuracy: 2)
        XCTAssertEqual(p.off, 10, accuracy: 1)
        let ahead = g.coordinates(from: 250)
        XCTAssertEqual(ahead.first?.latitude ?? 0, 40 + 250 / metersPerDegree, accuracy: 1e-6)
        XCTAssertEqual(ahead.count, g.lats.count - 1 + 1)
        XCTAssertTrue(g.coordinates(from: 5000).isEmpty)
        XCTAssertEqual(g.coordinates(from: 0).count, g.lats.count)
        let (lat2, lon2) = at(north: 480, east: 200)
        XCTAssertEqual(g.project(lat: lat2, lon: lon2).along, 700, accuracy: 3)
        XCTAssertEqual(g.project(lat: lat2, lon: lon2).off, 20, accuracy: 1)
    }

    func testAnOutAndBackDoesntJumpToTheOtherLeg() {
        let g = guide(north: 500, east: 20, back: true)
        // On the way back, 5 m from both legs: the hint keeps you on the return.
        let (lat, lon) = at(north: 100, east: 12)
        XCTAssertEqual(g.project(lat: lat, lon: lon, near: 900).along, 920, accuracy: 5)
        XCTAssertEqual(g.project(lat: lat, lon: lon, near: 90).along, 100, accuracy: 5)
    }

    func testStrayingTakesFifteenSecondsAndComingBackNeedsTwentyFiveMetres() {
        var d = OffRouteDetector()
        XCTAssertNil(d.update(off: 50, at: start))
        XCTAssertNil(d.update(off: 50, at: start.addingTimeInterval(14)))
        XCTAssertEqual(d.update(off: 55, at: start.addingTimeInterval(15)), .offRoute)
        XCTAssertNil(d.update(off: 60, at: start.addingTimeInterval(20)), "once, not every fix")
        XCTAssertNil(d.update(off: 30, at: start.addingTimeInterval(25)), "30 m is not back yet")
        XCTAssertEqual(d.update(off: 20, at: start.addingTimeInterval(26)), .backOnRoute)
        // A GPS wobble out and in again says nothing.
        var wobble = OffRouteDetector()
        XCTAssertNil(wobble.update(off: 50, at: start))
        XCTAssertNil(wobble.update(off: 30, at: start.addingTimeInterval(5)))
        XCTAssertNil(wobble.update(off: 50, at: start.addingTimeInterval(10)))
        XCTAssertNil(wobble.update(off: 50, at: start.addingTimeInterval(24)))
        XCTAssertEqual(wobble.update(off: 50, at: start.addingTimeInterval(25)), .offRoute)
    }

    func testTheWorkoutFollowsItsGuideAndSaysWhenYouStray() async throws {
        UserDefaults().removePersistentDomain(forName: "RouteFollowerTests")
        let defaults = UserDefaults(suiteName: "RouteFollowerTests")!
        let location = FakeLocation()
        var clock = start
        let c = RingWorkoutController(session: RingSession(transport: makeRingTransport(FakeRingLink()), defaults: defaults),
                                      ensureConnected: { true }, location: location, clock: { clock }, defaults: defaults)
        var events: [OffRouteDetector.Event] = []
        c.onGuideEvent = { events.append($0) }
        c.countdownSeconds = 0
        WorkoutMonitorPreference.usesRing = false
        defer { WorkoutMonitorPreference.usesRing = true }
        c.guide = guide(north: 500, east: 500)
        c.start(RingSport.withID(7))
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertNotNil(c.guide, "starting keeps the route to follow")
        for s in 0...20 {
            clock = start.addingTimeInterval(Double(s))
            let (lat, lon) = at(north: Double(s) * 10, east: 0)
            location.fix(lat: lat, lon: lon, at: clock)
        }
        XCTAssertEqual(c.guideAlong ?? 0, 200, accuracy: 3)
        XCTAssertFalse(c.offRoute)
        // Off to the west for twenty seconds.
        for s in 21...45 {
            clock = start.addingTimeInterval(Double(s))
            let (lat, lon) = at(north: 200, east: -Double(s - 20) * 4)
            location.fix(lat: lat, lon: lon, at: clock)
        }
        XCTAssertTrue(c.offRoute)
        XCTAssertEqual(events, [.offRoute])
        c.end()
        c.close(save: false)
        XCTAssertNil(c.guide, "a finished workout lets the route go")
    }
}

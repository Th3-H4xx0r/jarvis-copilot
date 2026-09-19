import XCTest
@testable import JarvisCopilot

/// Distances, splits, climbing, speeds and outlines of a route.
final class RouteMathTests: XCTestCase {
    static let metersPerDegree = 111_195.08

    /// Due north from (40, -105) at `speed` m/s, a fix a second.
    static func line(seconds: Int, speed: Double, from t0: Double = 0, lat0: Double = 40,
                     ele: (Int) -> Double? = { _ in nil }, hr: Int? = nil) -> [RoutePoint] {
        (0...seconds).map { s in
            RoutePoint(t: t0 + Double(s), lat: lat0 + Double(s) * speed / metersPerDegree, lon: -105, ele: ele(s), hr: hr,
                       speed: speed)
        }
    }

    private func route(_ segments: [[RoutePoint]], elevation: String = "barometer") -> WorkoutRoute {
        WorkoutRoute(start: Date(timeIntervalSince1970: 1_800_000_000), segments: segments, elevationSource: elevation)
    }

    func testHaversineOneDegreeOfLatitude() {
        XCTAssertEqual(RouteMath.distance(0, 0, 1, 0), Self.metersPerDegree, accuracy: 1)
    }

    func testThreeKilometresInTenMinutes() {
        let stats = RouteMath.stats(route([Self.line(seconds: 600, speed: 5, hr: 150)]), unit: .km)
        XCTAssertEqual(stats.distance, 3000, accuracy: 30)
        XCTAssertEqual(stats.moving, 600, accuracy: 0.5)
        XCTAssertEqual(stats.elapsed, 600)
        XCTAssertEqual(stats.splits.count, 3)
        XCTAssertTrue(stats.splits.allSatisfy { abs($0.seconds - 200) < 3 && !$0.partial })
        XCTAssertNotNil(stats.best)
        XCTAssertEqual(stats.splits[0].hr, 150)
        XCTAssertEqual(stats.movingPace! * 1000, 200, accuracy: 2)
        XCTAssertEqual(stats.samples.count, 601)
        XCTAssertEqual(stats.samples[300].speed!, 5, accuracy: 0.05)
    }

    func testMileSplitsEndInAPartial() {
        let stats = RouteMath.stats(route([Self.line(seconds: 600, speed: 5)]), unit: .mi)
        XCTAssertEqual(stats.splits.count, 2)
        XCTAssertFalse(stats.splits[0].partial)
        XCTAssertEqual(stats.splits[0].meters, 1609.344, accuracy: 0.01)
        XCTAssertTrue(stats.splits[1].partial)
        XCTAssertEqual(stats.splits[1].meters, 3000 - 1609.344, accuracy: 30)
        XCTAssertEqual(stats.best, 0, "a partial split is never the best")
    }

    func testAPauseAddsNoDistanceOrTime() {
        let first = Self.line(seconds: 100, speed: 4)
        // Five minutes later, half a kilometre further on.
        let second = Self.line(seconds: 100, speed: 4, from: 400, lat0: first.last!.lat + 500 / Self.metersPerDegree)
        let stats = RouteMath.stats(route([first, second]), unit: .km)
        XCTAssertEqual(stats.distance, 800, accuracy: 8)
        XCTAssertEqual(stats.active, 200)
        XCTAssertEqual(stats.elapsed, 500)
        XCTAssertEqual(stats.moving, 200, accuracy: 0.5)
    }

    func testClimbingNeedsToClearTheThreshold() {
        let eles: [Double] = [0, 10, 7, 20]
        let points = Self.line(seconds: 3, speed: 5, ele: { eles[$0] })
        let stats = RouteMath.stats(route([points]), unit: .km)
        XCTAssertEqual(stats.gain, 23)
        XCTAssertEqual(stats.loss, 3)
        XCTAssertEqual(stats.minEle, 0)
        XCTAssertEqual(stats.maxEle, 20)
        let jitter = Self.line(seconds: 100, speed: 3, ele: { 100 + Double($0 % 2) })
        XCTAssertEqual(RouteMath.stats(route([jitter]), unit: .km).gain, 0)
        XCTAssertEqual(RouteMath.stats(route([Self.line(seconds: 5, speed: 3)]), unit: .km).gain, nil)
    }

    func testSplitGainsAddUpToTheTotal() {
        let points = Self.line(seconds: 600, speed: 5, ele: { Double($0) * 0.1 })
        let stats = RouteMath.stats(route([points]), unit: .km)
        XCTAssertEqual(stats.splits.reduce(0) { $0 + $1.gain }, stats.gain!, accuracy: 0.001)
        XCTAssertGreaterThan(stats.gain!, 55)
    }

    func testMaxSpeedIgnoresOneWildFix() {
        var points = Self.line(seconds: 120, speed: 3)
        points[60].lon += 30 / 85_000   // 30 m sideways and straight back
        let fastest = RouteMath.maxSpeed(route([points]))!
        XCTAssertEqual(fastest, 3, accuracy: 0.3)
    }

    func testSimplifyKeepsCornersAndDropsTheStraight() {
        let straight = Self.line(seconds: 100, speed: 5)
        XCTAssertEqual(RouteMath.simplify(straight, tolerance: 2).count, 2)
        let east = (1...100).map { s in
            RoutePoint(t: 100 + Double(s), lat: straight.last!.lat, lon: -105 + Double(s) * 5 / 85_000, ele: nil, hr: nil,
                       speed: nil)
        }
        let corner = RouteMath.simplify(straight + east, tolerance: 2)
        XCTAssertEqual(corner.count, 3)
        XCTAssertEqual(corner[1], straight.last)
    }

    func testGooglesPolylineExample() {
        let coordinates: [(lat: Double, lon: Double)] = [(38.5, -120.2), (40.7, -120.95), (43.252, -126.453)]
        XCTAssertEqual(RouteMath.encode(coordinates), "_p~iF~ps|U_ulLnnqC_mqNvxq`@")
        let back = RouteMath.decode("_p~iF~ps|U_ulLnnqC_mqNvxq`@")
        XCTAssertEqual(back.count, 3)
        XCTAssertEqual(back[2].lat, 43.252, accuracy: 1e-6)
        XCTAssertEqual(back[2].lon, -126.453, accuracy: 1e-6)
    }

    func testThinningKeepsTheEndsAndTheCap() {
        let points = Self.line(seconds: 1000, speed: 1)
        let thinned = RouteMath.thin(route([points]))
        XCTAssertEqual(thinned.points.count, 501, accuracy: 2)
        XCTAssertEqual(thinned.points.first, points.first)
        XCTAssertEqual(thinned.points.last, points.last)
        XCTAssertLessThanOrEqual(RouteMath.thin(route([points]), maxPoints: 100).points.count, 100)
    }

    func testAPointIsAnArrayOnTheWire() throws {
        let point = RoutePoint(t: 12.34, lat: 40.1234567, lon: -105.7654321, ele: nil, hr: 142, speed: 3.456)
        let json = String(decoding: try JSONEncoder().encode(point), as: UTF8.self)
        XCTAssertEqual(json, "[12.3,40.123457,-105.765432,null,142,3.46]")
        let back = try JSONDecoder().decode(RoutePoint.self, from: Data(json.utf8))
        XCTAssertEqual(back.hr, 142)
        XCTAssertNil(back.ele)
        let short = try JSONDecoder().decode(RoutePoint.self, from: Data("[1,2,3]".utf8))
        XCTAssertEqual(short.lon, 3)
    }

    func testTheSummaryIsSmall() throws {
        let wiggly = (0...3000).map { s in
            RoutePoint(t: Double(s), lat: 40 + Double(s) * 2 / Self.metersPerDegree,
                       lon: -105 + sin(Double(s) / 20) * 0.0004, ele: 1600 + sin(Double(s) / 300) * 40, hr: nil, speed: nil)
        }
        let summary = RouteMath.summary(route([wiggly]))
        XCTAssertLessThanOrEqual(RouteMath.decode(summary.preview).count, 120)
        XCTAssertGreaterThan(RouteMath.decode(summary.preview).count, 10)
        XCTAssertEqual(summary.bounds.count, 4)
        XCTAssertGreaterThan(summary.gainMeters ?? 0, 60)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(summary)) as? [String: Any]
        XCTAssertNotNil(json?["distance_m"])
        XCTAssertNotNil(json?["moving_s"])
    }

    func testUnitsFormat() {
        XCTAssertEqual(DistanceUnit.mi.distance(1609.344 * 3.42), "3.42")
        XCTAssertEqual(DistanceUnit.km.pace(secondsPerMeter: 0.25), "4:10")
        XCTAssertEqual(DistanceUnit.mi.pace(secondsPerMeter: 492 / 1609.344), "8:12")
        XCTAssertEqual(DistanceUnit.mi.pace(secondsPerMeter: nil), "--")
        XCTAssertEqual(DistanceUnit.mi.elevation(100), "328")
        XCTAssertEqual(DistanceUnit.km.speed(5), "18.0")
    }
}

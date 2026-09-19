import SwiftUI
import XCTest
@testable import JarvisCopilot

/// The route detail, its charts' series, and GPX export.
@MainActor
final class RouteDetailTests: XCTestCase {
    override func setUp() async throws {
        DistanceUnit.current = .mi
        MapStyle.current = .standard
    }

    private func workout(_ route: WorkoutRoute, phoneOnly: Bool = false) -> RingWorkout {
        let stats = RouteMath.stats(route, unit: .mi)
        var w = RingWorkout(sport: 7, sportName: "Run", start: route.start,
                            end: route.start.addingTimeInterval((route.points.last?.t ?? 0) + 60),
                            activeSeconds: Int(stats.active), steps: phoneOnly ? 0 : 4210, distanceMeters: stats.distance,
                            distanceSource: "gps", kilocalories: 431,
                            heartRateAverage: phoneOnly ? nil : 146, heartRateMax: phoneOnly ? nil : 171,
                            heartRates: [], zoneSeconds: phoneOnly ? [0, 0, 0, 0, 0] : [60, 240, 700, 300, 40])
        w.route = RouteMath.summary(route)
        w.effort = phoneOnly ? nil : 6
        if phoneOnly { w.kcalSource = "estimate" }
        return w
    }

    func testChartSeriesAreCappedAndInTheUnit() {
        let route = SampleRoute.route()
        let stats = RouteMath.stats(route, unit: .mi)
        let elevation = RouteChartSeries.points(.elevation, stats: stats, unit: .mi, limit: 100)
        XCTAssertLessThanOrEqual(elevation.count, 100)
        XCTAssertGreaterThan(elevation.count, 80)
        XCTAssertEqual(elevation.map(\.y).max() ?? 0, (150 + 24) * DistanceUnit.feetPerMeter, accuracy: 15, "feet")
        XCTAssertEqual(elevation.last?.x ?? 0, stats.distance / 1609.344, accuracy: 0.05)
        let pace = RouteChartSeries.points(.pace, stats: stats, unit: .mi)
        XCTAssertFalse(pace.isEmpty)
        XCTAssertTrue(pace.allSatisfy { $0.y > 200 && $0.y < 900 }, "the sample loop runs 4–7 minutes a mile")
        XCTAssertEqual(RouteChartSeries.nearest(elevation, to: 1.0)?.x ?? 0, 1.0, accuracy: 0.05)
        let phone = RouteMath.stats(SampleRoute.route(hr: false), unit: .mi)
        XCTAssertTrue(RouteChartSeries.points(.heartRate, stats: phone, unit: .mi).isEmpty)
    }

    func testGPXHasASegmentPerStretchWithTimeElevationAndHeartRate() throws {
        let route = SampleRoute.route(seconds: 40)
        let gpx = GPXWriter.gpx(route, name: "Run & <fun>")
        XCTAssertTrue(gpx.hasPrefix("<?xml"))
        XCTAssertEqual(gpx.components(separatedBy: "<trkseg>").count - 1, 2)
        XCTAssertEqual(gpx.components(separatedBy: "<trkpt ").count - 1, route.points.count)
        XCTAssertTrue(gpx.contains("<ele>"))
        XCTAssertTrue(gpx.contains("<gpxtpx:hr>"))
        XCTAssertTrue(gpx.contains("Run &amp; &lt;fun&gt;"))
        // It parses as XML.
        let parser = XMLParser(data: Data(gpx.utf8))
        XCTAssertTrue(parser.parse(), parser.parserError.map { "\($0)" } ?? "")
        let url = try GPXWriter.file(route, name: "Run")
        XCTAssertTrue(url.lastPathComponent.hasPrefix("Run "))
        XCTAssertTrue(url.lastPathComponent.hasSuffix(".gpx"))
    }

    func testMarkersAtEachMile() {
        let route = SampleRoute.route()
        let stats = RouteMath.stats(route, unit: .mi)
        let markers = RouteMarker.markers(route, stats: stats, unit: .mi)
        XCTAssertEqual(markers.first?.kind, .start)
        XCTAssertEqual(markers.last?.kind, .finish)
        XCTAssertEqual(markers.count, 2 + stats.splits.filter { !$0.partial }.count)
    }

    func testTheRouteDetail() throws {
        let route = SampleRoute.route()
        try RenderHarness.write(NavigationStack { RouteDetailView(workout: workout(route), route: route, fromHistory: true) },
                                size: CGSize(width: 402, height: 2300), name: "route-detail", settle: 6)
    }

    func testTheRouteDetailColouredByPace() throws {
        let route = SampleRoute.route()
        try RenderHarness.write(RouteDetailView(workout: workout(route), route: route, colouring: .pace),
                                size: CGSize(width: 402, height: 900), name: "route-detail-pace", settle: 6)
    }

    func testTheSummaryOfAPhoneOnlyWalk() throws {
        let route = SampleRoute.route(seconds: 900, hr: false)
        var walk = workout(route, phoneOnly: true)
        walk.sport = 4
        walk.sportName = "Walk"
        try RenderHarness.write(RouteDetailView(workout: walk, route: route, onSave: {}, onDiscard: {}),
                                size: CGSize(width: 402, height: 2100), name: "route-summary", settle: 6)
    }

    func testGPSWorkoutsInTheHealthList() throws {
        let route = SampleRoute.route()
        var lift = workout(route)
        lift.route = nil
        lift.sport = 22
        lift.sportName = "Yoga"
        lift.start = lift.start.addingTimeInterval(-7200)
        try RenderHarness.write(ScrollView { HealthWorkoutsCard(workouts: [workout(route), lift]).padding(.top, 20) },
                                size: CGSize(width: 402, height: 260), name: "workouts-card-gps")
    }
}

import XCTest
@testable import JarvisCopilot

/// Which fixes a route keeps, pauses, climbing, pace and calories.
final class RouteRecordingTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func fix(_ s: Double, lat: Double, lon: Double = -105, accuracy: Double = 5, altitude: Double? = nil,
                     speed: Double? = nil) -> RouteFix {
        RouteFix(time: start.addingTimeInterval(s), lat: lat, lon: lon, horizontalAccuracy: accuracy,
                 altitude: altitude, verticalAccuracy: altitude == nil ? nil : 4, speed: speed)
    }

    private func north(_ meters: Double) -> Double { 40 + meters / RouteMathTests.metersPerDegree }

    private func take(_ recording: inout RouteRecording, _ fix: RouteFix, hr: Int? = nil, baro: Double? = nil) -> Bool {
        recording.take(fix, heartRate: hr, pressureAltitude: baro, now: fix.time)
    }

    func testBadFixesAreLeftOut() {
        var r = RouteRecording(start: start, sport: 7, weightKg: 70)
        XCTAssertTrue(take(&r, fix(0, lat: 40)))
        XCTAssertFalse(take(&r, fix(1, lat: north(3), accuracy: 25)), "too vague")
        XCTAssertFalse(take(&r, fix(1, lat: north(3), accuracy: -1)), "invalid")
        XCTAssertFalse(take(&r, fix(-60, lat: north(6))), "the cached fix from before the start")
        XCTAssertTrue(r.take(fix(2, lat: north(6)), heartRate: nil, pressureAltitude: nil,
                             now: start.addingTimeInterval(300)), "late in a batch still counts")
        XCTAssertFalse(take(&r, fix(3, lat: north(1000))), "a kilometre in a second")
        XCTAssertTrue(take(&r, fix(4, lat: north(12))))
        XCTAssertEqual(r.distance, 12, accuracy: 0.2)
        XCTAssertFalse(take(&r, fix(4, lat: north(20))), "time must move on")
    }

    func testStandingStillAddsNoDistance() {
        var r = RouteRecording(start: start, sport: 4, weightKg: 70)
        for s in 0..<60 {
            let wobble = Double([0, 2, -1, 3, -2, 1][s % 6])
            _ = take(&r, fix(Double(s), lat: north(wobble), lon: -105 + wobble / 85_000, speed: 0.1))
        }
        XCTAssertLessThan(r.distance, 5)
        XCTAssertEqual(r.route.points.count, 1)
        // Walking off, slowly: a real move counts even when Doppler lags.
        _ = take(&r, fix(61, lat: north(12), speed: 0.2))
        XCTAssertEqual(r.distance, 12, accuracy: 0.5)
    }

    func testAPauseStartsANewSegmentWithoutDistance() {
        var r = RouteRecording(start: start, sport: 7, weightKg: 70)
        for s in 0...10 { _ = take(&r, fix(Double(s), lat: north(Double(s) * 3))) }
        r.pause()
        XCTAssertFalse(take(&r, fix(20, lat: north(60))))
        XCTAssertNil(r.pace)
        r.resume()
        for s in 0...10 { _ = take(&r, fix(100 + Double(s), lat: north(300 + Double(s) * 3))) }
        XCTAssertEqual(r.route.segments.count, 2)
        XCTAssertEqual(r.distance, 60, accuracy: 1)
    }

    func testHeartRateAndTheBarometerRideOnEachPoint() {
        var r = RouteRecording(start: start, sport: 8, weightKg: 70)
        _ = take(&r, fix(0, lat: 40, altitude: 1500), hr: 120, baro: 1512)
        _ = take(&r, fix(5, lat: north(10), altitude: 1500), hr: 121, baro: 1516)
        XCTAssertEqual(r.route.points.map(\.hr), [120, 121])
        XCTAssertEqual(r.route.points.map(\.ele), [1512, 1516])
        XCTAssertEqual(r.route.elevationSource, "barometer")
        XCTAssertEqual(r.gain, 4)
    }

    func testGPSAltitudeWhenThereIsNoBarometer() {
        var r = RouteRecording(start: start, sport: 8, weightKg: 70)
        _ = take(&r, fix(0, lat: 40, altitude: 1500))
        _ = take(&r, fix(5, lat: north(10), altitude: 1504))
        XCTAssertEqual(r.route.elevationSource, "gps")
        XCTAssertEqual(r.gain, 0, "4 m is inside GPS's 5 m noise")
    }

    func testPaceIsTheLastFewHundredMetres() {
        var r = RouteRecording(start: start, sport: 7, weightKg: 70)
        for s in 0...250 { _ = take(&r, fix(Double(s), lat: north(Double(s) * 4))) }
        XCTAssertEqual(r.pace!, 250, accuracy: 3)
        XCTAssertEqual(r.progress.distance, 1000, accuracy: 5)
        // Points 4 m apart with 5 m fixes: every other one is a move.
        XCTAssertEqual(r.progress.revision, r.route.points.count)
        XCTAssertEqual(r.route.points.count, 126)
    }

    func testRunningCaloriesFollowACSM() {
        // 10 km/h on the flat: 0.2 × 166.7 + 3.5 = 36.8 ml/kg/min → 12.9 kcal/min at 70 kg.
        let perMinute = OutdoorCalories.kcal(kind: .run, metersPerSecond: 10 / 3.6, grade: 0, seconds: 60, weightKg: 70)
        XCTAssertEqual(perMinute, 12.9, accuracy: 0.1)
        let uphill = OutdoorCalories.kcal(kind: .walk, metersPerSecond: 1.4, grade: 0.1, seconds: 60, weightKg: 70)
        let flat = OutdoorCalories.kcal(kind: .walk, metersPerSecond: 1.4, grade: 0, seconds: 60, weightKg: 70)
        XCTAssertGreaterThan(uphill, flat * 1.5)
        XCTAssertEqual(OutdoorCalories.kcal(kind: .cycle, metersPerSecond: 20 / 3.6, grade: 0, seconds: 60, weightKg: 70),
                       8 * 3.5 * 70 / 200, accuracy: 0.01)
    }

    func testARecordingSurvivesBeingSaved() throws {
        var r = RouteRecording(start: start, sport: 7, weightKg: 70)
        for s in 0...20 { _ = take(&r, fix(Double(s), lat: north(Double(s) * 3)), hr: 130) }
        let back = try JSONDecoder().decode(RouteRecording.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(back.distance, r.distance)
        XCTAssertEqual(back.route.points.count, r.route.points.count)
        XCTAssertEqual(back.route.points.last!.lat, r.route.points.last!.lat, accuracy: 1e-6, "six decimals on disk")
    }
}

import HealthKit
import XCTest
@testable import JarvisCopilot

/// How workouts map onto Apple Health, without touching HealthKit.
final class AppleHealthPlannerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func workout(sport: Int, meters: Double = 0) -> RingWorkout {
        RingWorkout(sport: sport, sportName: "x", start: start, end: start.addingTimeInterval(20), activeSeconds: 20, steps: 0,
                    distanceMeters: meters, distanceSource: "gps", kilocalories: 42.4, heartRateAverage: 120, heartRateMax: 130,
                    heartRates: [110, 0, 120, 130, 140], zoneSeconds: [0, 0, 0, 0, 0], effort: 5)
    }

    func testSportsMapOntoActivities() {
        XCTAssertEqual(AppleHealthPlanner.activity(sport: 88).0, .traditionalStrengthTraining)
        XCTAssertTrue(AppleHealthPlanner.activity(sport: 40).indoor, "a treadmill is indoors")
        XCTAssertFalse(AppleHealthPlanner.activity(sport: 7).indoor)
        XCTAssertEqual(AppleHealthPlanner.activity(sport: 999).0, .other)
        XCTAssertEqual(AppleHealthPlanner.distanceType(sport: 9), .distanceCycling)
        XCTAssertNil(AppleHealthPlanner.distanceType(sport: 88))
    }

    func testThePlanCarriesHeartRateCaloriesDistanceAndEffort() {
        let plan = AppleHealthPlanner.plan(workout(sport: 7, meters: 3210), version: 2)
        XCTAssertEqual(plan.heartRates.map(\.bpm), [110, 120, 130, 140], "gaps are not readings")
        XCTAssertEqual(plan.heartRates[1].at, start.addingTimeInterval(10))
        XCTAssertEqual(plan.heartRates.count, 4)
        XCTAssertEqual(plan.activeKcal, 42.4)
        XCTAssertEqual(plan.distanceType, .distanceWalkingRunning)
        XCTAssertEqual(plan.meters, 3210)
        XCTAssertEqual(plan.effort, 5)
        XCTAssertEqual(plan.version, 2)
        XCTAssertEqual(plan.syncID, AppleHealthPlanner.syncID(start))
    }

    func testReadingsAfterTheEndAreDropped() {
        var w = workout(sport: 88)
        w.end = start.addingTimeInterval(9)
        XCTAssertEqual(AppleHealthPlanner.plan(w, version: 1).heartRates.map(\.bpm), [110])
    }

    func testTheSyncIDIsStableAndKeyable() {
        XCTAssertEqual(AppleHealthPlanner.syncID(start), AppleHealthPlanner.syncID(start.addingTimeInterval(0.3)))
        XCTAssertTrue(AppleHealthPlanner.syncID(start).hasPrefix("jarvis-2027"))
    }
}

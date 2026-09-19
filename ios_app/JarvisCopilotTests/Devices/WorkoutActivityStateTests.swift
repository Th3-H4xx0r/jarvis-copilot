import XCTest
@testable import JarvisCopilot

/// The Live Activity's state: a strength rest rides along, and a state from
/// before strength existed still decodes (an activity outlives an update).
final class WorkoutActivityStateTests: XCTestCase {
    func testAnOlderStateStillDecodes() throws {
        let old = #"{"running":true,"reference":0,"frozenElapsed":12,"heartRate":120}"#
        let state = try JSONDecoder().decode(RingWorkoutAttributes.ContentState.self, from: Data(old.utf8))
        XCTAssertNil(state.restEnds)
        XCTAssertNil(state.detail)
        XCTAssertEqual(state.heartRate, 120)
    }

    func testARestRoundTrips() throws {
        let ends = Date(timeIntervalSince1970: 1_800_000_120)
        let state = RingWorkoutAttributes.ContentState(running: true, reference: .now, frozenElapsed: 0, heartRate: nil,
                                                       distanceKm: nil, zone: nil, restEnds: ends,
                                                       restStarted: ends.addingTimeInterval(-120), detail: "Bench · set 2")
        let back = try JSONDecoder().decode(RingWorkoutAttributes.ContentState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(back, state)
    }
}

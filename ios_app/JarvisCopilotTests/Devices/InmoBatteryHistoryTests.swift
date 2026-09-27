import XCTest
@testable import JarvisCopilot

final class InmoBatteryHistoryTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    func testEstimateRequiresThreeObservationsThirtyMinutesAndTwoPoints() {
        let history = InmoBatteryHistory(identity: "test", defaults: nil)
        history.record(80, at: start)
        history.record(79, at: start.addingTimeInterval(60))
        XCTAssertNil(history.estimate())
        // Routine gaps over ten minutes split segments, so give genuine minute observations.
        for minute in 2...30 { history.record(80 - max(1, minute / 10), at: start.addingTimeInterval(Double(minute) * 60)) }
        XCTAssertNotNil(history.estimate())
    }
    func testRiseAndDisconnectPreventJoinedEstimate() {
        let history = InmoBatteryHistory(identity: "test", defaults: nil)
        for minute in 0...30 { history.record(80 - minute / 10, at: start.addingTimeInterval(Double(minute) * 60)) }
        XCTAssertNotNil(history.estimate())
        history.record(90, at: start.addingTimeInterval(1860))
        XCTAssertNil(history.estimate())
        history.disconnected(at: start.addingTimeInterval(1900))
        XCTAssertNil(history.estimate())
    }
    func testInvalidReadingsSamplingAndRetention() {
        let history = InmoBatteryHistory(identity: "test", defaults: nil)
        history.record(-1, at: start); history.record(101, at: start)
        XCTAssertTrue(history.samples.isEmpty)
        history.record(50, at: start); history.record(50, at: start.addingTimeInterval(20))
        XCTAssertEqual(history.samples.count, 1)
        history.record(49, at: start.addingTimeInterval(30))
        XCTAssertEqual(history.samples.count, 2)
        history.record(40, at: start.addingTimeInterval(8 * 24 * 3600))
        XCTAssertEqual(history.samples.count, 1)
    }
}

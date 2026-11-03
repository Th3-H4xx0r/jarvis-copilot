import XCTest
@testable import JarvisCopilot

/// The big number above the battery counts from this morning's wake-up — never from a
/// wake-up days old, which read "Awake 1021h".
final class HealthDayHeaderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)

    func testAFreshWakeUpCountsFromTheWakeUp() {
        let wake = now.addingTimeInterval(-3 * 3600)
        let window = HealthWindow(start: wake, end: now, noNight: false, wake: wake)
        XCTAssertFalse(HealthDayHeader.countsFromMidnight(window, now: now))
        XCTAssertEqual(HealthDayHeader.countStart(window, now: now), wake)
    }

    func testAWakeUpMoreThanADayOldCountsFromMidnight() {
        let wake = now.addingTimeInterval(-40 * 24 * 3600)
        let window = HealthWindow(start: wake, end: now, noNight: false, wake: wake)
        XCTAssertTrue(HealthDayHeader.countsFromMidnight(window, now: now))
        XCTAssertEqual(HealthDayHeader.countStart(window, now: now), Calendar.current.startOfDay(for: now))
    }

    func testNoNightCountsFromTheWindowStart() {
        let midnight = Calendar.current.startOfDay(for: now)
        let window = HealthWindow(start: midnight, end: now, noNight: true)
        XCTAssertTrue(HealthDayHeader.countsFromMidnight(window, now: now))
        XCTAssertEqual(HealthDayHeader.countStart(window, now: now), midnight)
    }
}

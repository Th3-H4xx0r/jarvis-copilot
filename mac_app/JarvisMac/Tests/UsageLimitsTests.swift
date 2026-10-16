import XCTest
@testable import Jarvis

/// The Agents tab's limits card: each window's use, when it resets, and the
/// pace — ahead of the clock (a deficit) or under it (in reserve).
final class UsageLimitsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testTheWindowsKeepWhenTheyReset() {
        let base = Date().timeIntervalSince1970          // the pills read "now" from the clock
        let u = MacPlanUsage(json: ["rate_limits": [
            "five_hour": ["used_percentage": 91, "resets_at": base + 2 * 3600 + 240],
            "seven_day": ["used_percentage": 18.4, "resets_at": base + 6 * 86_400 + 4 * 3600]]])!
        XCTAssertEqual(u.fiveHour, 91)
        XCTAssertEqual(u.sevenDay, 18)
        XCTAssertEqual(u.five?.resetsAt, Date(timeIntervalSince1970: base + 2 * 3600 + 240))
        XCTAssertNotNil(u.week)
        // A window that has reset reads nothing used.
        let old = MacPlanUsage(json: ["rate_limits": ["five_hour": ["used_percentage": 50, "resets_at": base - 10]]])!
        XCTAssertEqual(old.fiveHour, 0)
    }

    func testResetsInReadsLikeAClock() {
        XCTAssertEqual(UsagePace.resetsIn(now.addingTimeInterval(2 * 3600 + 4 * 60), now: now), "2h 4m")
        XCTAssertEqual(UsagePace.resetsIn(now.addingTimeInterval(6 * 86_400 + 4 * 3600 + 59), now: now), "6 days 4h")
        XCTAssertEqual(UsagePace.resetsIn(now.addingTimeInterval(1 * 86_400 + 60), now: now), "1 day")
        XCTAssertEqual(UsagePace.resetsIn(now.addingTimeInterval(12 * 60), now: now), "12 min")
        XCTAssertEqual(UsagePace.resetsIn(now.addingTimeInterval(-5), now: now), "now")
    }

    /// 91 % used with 2 h 4 m of a 5 h window left: 58.7 % of the window has
    /// gone, so the use runs 32.3 points ahead of the clock.
    func testPaceIsUseMinusTheShareOfTheWindowGone() {
        let pace = UsagePace.pace(used: 91, resetsAt: now.addingTimeInterval(2 * 3600 + 4 * 60),
                                  length: 5 * 3600, now: now)
        XCTAssertEqual(pace, 32.3, accuracy: 0.1)
        let under = UsagePace.pace(used: 10, resetsAt: now.addingTimeInterval(3 * 86_400), length: 7 * 86_400, now: now)
        XCTAssertLessThan(under, 0)
    }
}

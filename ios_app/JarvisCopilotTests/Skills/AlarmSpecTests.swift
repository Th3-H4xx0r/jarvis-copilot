import XCTest
@testable import JarvisCopilot

final class AlarmSpecTests: XCTestCase {
    func testWeekdayNamesAndAbbreviations() {
        XCTAssertEqual(AlarmWeekdays.parse(["mon", "Wednesday", "FRI"]), [2, 4, 6])
    }

    func testWeekdaysAndWeekendsGroups() {
        XCTAssertEqual(AlarmWeekdays.parse(["weekdays"]), [2, 3, 4, 5, 6])
        XCTAssertEqual(AlarmWeekdays.parse(["weekends"]), [1, 7])
        XCTAssertEqual(AlarmWeekdays.parse(["daily"]), [1, 2, 3, 4, 5, 6, 7])
    }

    func testDuplicatesCollapseAndBlanksAreIgnored() {
        XCTAssertEqual(AlarmWeekdays.parse(["mon", "monday", ""]), [2])
        XCTAssertEqual(AlarmWeekdays.parse([]), [])
    }

    func testAnUnknownDayRefusesTheWholeList() {
        XCTAssertNil(AlarmWeekdays.parse(["mon", "funday"]))
    }

    func testNextOccurrenceIsTodayWhenStillAhead() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 9, day: 7, hour: 8, minute: 0)))
        let next = try XCTUnwrap(AlarmSpec.nextOccurrence(hour: 9, minute: 30, from: now, calendar: cal))
        XCTAssertEqual(cal.dateComponents([.day, .hour, .minute], from: next),
                       DateComponents(day: 7, hour: 9, minute: 30))
    }

    func testNextOccurrenceRollsToTomorrowWhenPassed() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 9, day: 7, hour: 10, minute: 0)))
        let next = try XCTUnwrap(AlarmSpec.nextOccurrence(hour: 9, minute: 30, from: now, calendar: cal))
        XCTAssertEqual(cal.component(.day, from: next), 8)
        // Exactly now is "passed" too: an alarm for this very minute rings tomorrow.
        let same = try XCTUnwrap(AlarmSpec.nextOccurrence(hour: 10, minute: 0, from: now, calendar: cal))
        XCTAssertEqual(cal.component(.day, from: same), 8)
    }
}

import XCTest
@testable import JarvisCopilot

/// The X5's automatic-measurement schedule as the settings screen edits and describes it.
final class X5MonitoringTests: XCTestCase {

    private func schedule(_ interval: Int, _ start: (Int, Int) = (0, 0), _ end: (Int, Int) = (23, 59),
                          days: UInt8 = 0x7F, on: Bool = true) -> X5Monitoring {
        X5Monitoring(on: on, startHour: start.0, startMinute: start.1, endHour: end.0, endMinute: end.1,
                     weekdays: days, intervalMinutes: interval, type: .heartRate)
    }

    func testTheRowValueIsTheIntervalOrOff() {
        XCTAssertEqual(schedule(10).value, "10 min")
        XCTAssertEqual(schedule(10, on: false).value, "Off")
    }

    func testAnAllDayEveryDayScheduleNeedsNoCaption() {
        XCTAssertNil(schedule(10).window)
    }

    func testTheCaptionNamesAnOvernightWindowAndWeekdays() {
        XCTAssertEqual(schedule(30, (22, 0), (8, 0), days: 0b0111110).window, "22:00–08:00 · weekdays")
    }

    func testTheCaptionNamesWeekendsAndPickedDays() {
        XCTAssertEqual(schedule(60, days: 0b1000001).window, "All day · weekends")
        XCTAssertEqual(schedule(60, days: 0b0001010).window, "All day · Mon, Wed")
        XCTAssertEqual(schedule(60, days: 0).window, "All day · no days")
    }

    func testIntervalLabels() {
        XCTAssertEqual(X5Monitoring.label(minutes: 5), "5 min")
        XCTAssertEqual(X5Monitoring.label(minutes: 60), "1 hour")
        XCTAssertEqual(X5Monitoring.label(minutes: 90), "1 h 30 min")
        XCTAssertEqual(X5Monitoring.label(minutes: 120), "2 hours")
    }

    func testTheIntervalMenuKeepsAValueSetElsewhere() {
        let choices = X5Monitoring.intervalChoices(including: 7)
        XCTAssertTrue(choices.contains(7))
        XCTAssertEqual(choices, choices.sorted())
        XCTAssertEqual(X5Monitoring.intervalChoices(including: 10).filter { $0 == 10 }.count, 1)
    }

    func testTogglingADayFlipsItsBit() {
        var m = schedule(10)
        XCTAssertTrue(m.has(weekday: 3))
        m.toggle(weekday: 3)
        XCTAssertFalse(m.has(weekday: 3))
        XCTAssertEqual(m.weekdays, 0x7F & ~0b0001000)
        m.toggle(weekday: 3)
        XCTAssertEqual(m.weekdays, 0x7F)
    }

    func testAllDayIsMidnightToTwentyThreeFiftyNine() {
        var m = schedule(10, (22, 0), (8, 0))
        XCTAssertFalse(m.isAllDay)
        XCTAssertTrue(m.isOvernight)
        m.isAllDay = true
        XCTAssertEqual([m.startHour, m.startMinute, m.endHour, m.endMinute], [0, 0, 23, 59])
        XCTAssertFalse(m.isOvernight)
    }

    func testTurningAllDayOffGivesAWakingHoursWindow() {
        var m = schedule(10)
        m.isAllDay = false
        XCTAssertFalse(m.isAllDay)
        XCTAssertFalse(m.isOvernight)
    }

    func testTheEditedScheduleIsWhatTheRingIsSent() {
        var m = schedule(10)
        m.intervalMinutes = 15
        m.isAllDay = false
        m.toggle(weekday: 0)
        let frame = [UInt8](RingRequest.x5SetMonitoring(m).payload.prefix(9))
        XCTAssertEqual(frame[0], 2)
        XCTAssertEqual(frame[5], 0x7E, "Sunday off")
        XCTAssertEqual(frame[6], 15)
    }
}

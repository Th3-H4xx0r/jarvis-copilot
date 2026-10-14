import XCTest
@testable import JarvisCopilot

/// The numbers on a habit's card and page: streaks, local days, periods, goals.
final class HabitMathTests: XCTestCase {
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        c.locale = Locale(identifier: "en_US")
        c.firstWeekday = 1
        return c
    }()
    /// 2026-10-14 13:00 in Los Angeles.
    private let now = utc("2026-10-14T20:00:00Z")

    private static func utc(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private func utc(_ text: String) -> Date { Self.utc(text) }

    private func habit(started: String = "2026-10-01T07:00:00Z", streak: Int? = nil, limit: HabitLimit? = nil) -> Habit {
        Habit(id: "scroll", name: "Doomscrolling", startedAt: utc(started), timezone: "America/Los_Angeles",
              goal: HabitGoal(streakDays: streak, limit: limit))
    }

    private func relapses(_ times: String...) -> [HabitRelapse] {
        times.map { HabitRelapse(habit: "scroll", uid: $0, at: utc($0), tz: "America/Los_Angeles") }
    }

    func testTheStreakRunsFromTheLaterOfTheQuitDateAndTheLastRelapse() {
        XCTAssertEqual(HabitMath.since(habit(), []), utc("2026-10-01T07:00:00Z"))
        let two = relapses("2026-10-05T07:00:00Z", "2026-10-12T20:00:00Z")
        XCTAssertEqual(HabitMath.since(habit(), two), utc("2026-10-12T20:00:00Z"))
        XCTAssertEqual(HabitMath.since(habit(started: "2026-10-13T20:00:00Z"), two), utc("2026-10-13T20:00:00Z"))
    }

    func testTheLongestStreakCountsTheOneUnderWay() {
        let two = relapses("2026-10-05T07:00:00Z", "2026-10-12T20:00:00Z")
        XCTAssertEqual(HabitMath.longestStreak(habit(), two, now: now),
                       utc("2026-10-12T20:00:00Z").timeIntervalSince(utc("2026-10-05T07:00:00Z")))
        XCTAssertEqual(HabitMath.longestStreak(habit(), [], now: now), now.timeIntervalSince(utc("2026-10-01T07:00:00Z")))
    }

    func testDurations() {
        XCTAssertEqual(HabitMath.duration(42), "42s")
        XCTAssertEqual(HabitMath.duration(252), "4m 12s")
        XCTAssertEqual(HabitMath.duration(11_100), "3h 5m")
        XCTAssertEqual(HabitMath.duration(1_053_060), "12d 4h 31m")
        XCTAssertEqual(HabitMath.duration(-5), "0s")
    }

    func testARelapseCountsOnItsLocalDay() {
        // 23:30 on Sep 30 in Los Angeles is Oct 1 06:30 UTC.
        let late = relapses("2026-10-01T06:30:00Z")
        let october = HabitMath.period(.month, containing: now, calendar: cal)
        XCTAssertEqual(HabitMath.buckets(late, range: .month, period: october, calendar: cal).map(\.count).reduce(0, +), 0)
        let september = HabitMath.period(.month, containing: utc("2026-09-15T20:00:00Z"), calendar: cal)
        XCTAssertEqual(HabitMath.buckets(late, range: .month, period: september, calendar: cal).last?.count, 1)
    }

    func testTheMonthIsTheCalendarMonth() {
        let october = HabitMath.period(.month, containing: now, calendar: cal)
        let buckets = HabitMath.buckets([], range: .month, period: october, calendar: cal)
        XCTAssertEqual(buckets.count, 31)
        XCTAssertEqual(buckets.map(\.id), Array(0..<31))
        XCTAssertEqual(cal.component(.day, from: buckets[0].start), 1)
    }

    func testTheWeekIsTheSevenDaysEndingOnTheAnchor() {
        let week = HabitMath.period(.week, containing: now, calendar: cal)
        XCTAssertEqual(cal.component(.day, from: week.start), 8)
        XCTAssertEqual(HabitMath.buckets([], range: .week, period: week, calendar: cal).count, 7)
        let day = HabitMath.period(.day, containing: now, calendar: cal)
        XCTAssertEqual(HabitMath.buckets([], range: .day, period: day, calendar: cal).count, 24)
    }

    func testSixMonthsUseWeeksAndAYearUsesMonths() {
        let half = HabitMath.period(.halfYear, containing: now, calendar: cal)
        XCTAssertEqual(cal.component(.month, from: half.start), 5)
        let weeks = HabitMath.buckets([], range: .halfYear, period: half, calendar: cal)
        XCTAssertTrue((26...28).contains(weeks.count), "\(weeks.count)")
        XCTAssertEqual(weeks.first?.start, half.start)
        XCTAssertEqual(weeks.last?.end, half.end)
        let year = HabitMath.period(.year, containing: now, calendar: cal)
        XCTAssertEqual(HabitMath.buckets([], range: .year, period: year, calendar: cal).count, 12)
    }

    func testSteppingNeverPassesNow() {
        let back = HabitMath.step(.month, from: now, by: -1, now: now, calendar: cal)
        XCTAssertEqual(cal.component(.month, from: back), 9)
        XCTAssertEqual(HabitMath.step(.month, from: back, by: 1, now: now, calendar: cal), now)
        XCTAssertEqual(HabitMath.step(.month, from: now, by: 1, now: now, calendar: cal), now)
        XCTAssertTrue(HabitMath.isCurrent(.month, anchor: now, now: now, calendar: cal))
        XCTAssertFalse(HabitMath.isCurrent(.month, anchor: back, now: now, calendar: cal))
    }

    func testDayStatus() {
        let start = utc("2026-10-01T07:00:00Z")
        let daily = habit(limit: HabitLimit(per: .day, count: 2))
        let oct10 = utc("2026-10-10T19:00:00Z")
        func status(_ day: Date, _ count: Int, _ h: Habit) -> HabitMath.DayStatus {
            HabitMath.status(day: day, count: count, habit: h, start: start, now: now, calendar: cal)
        }
        XCTAssertEqual(status(oct10, 0, daily), .clean)
        XCTAssertEqual(status(oct10, 2, daily), .within)
        XCTAssertEqual(status(oct10, 3, daily), .over)
        XCTAssertEqual(status(oct10, 1, habit()), .over)
        XCTAssertEqual(status(utc("2026-09-29T19:00:00Z"), 0, daily), .beforeStart)
        XCTAssertEqual(status(utc("2026-10-20T19:00:00Z"), 0, daily), .future)
        XCTAssertEqual(status(now, 0, daily), .clean)
    }

    func testTheMonthGridLeadsWithBlanksFromTheFirstWeekday() {
        let october = HabitMath.period(.month, containing: now, calendar: cal)
        let rel = relapses("2026-10-03T19:00:00Z", "2026-10-03T20:00:00Z")
        let buckets = HabitMath.buckets(rel, range: .month, period: october, calendar: cal)
        let grid = HabitMath.monthGrid(buckets: buckets, habit: habit(), start: utc("2026-10-01T07:00:00Z"),
                                       now: now, calendar: cal)
        XCTAssertEqual(grid.prefix(4).map(\.day), [nil, nil, nil, nil])     // Oct 1 2026 is a Thursday
        XCTAssertEqual(grid[4].bucket, 0)
        XCTAssertEqual(grid[6].count, 2)
        XCTAssertEqual(grid[6].status, .over)
        XCTAssertEqual(grid[4 + 13].status, .clean)      // the 14th, today
        XCTAssertEqual(grid[4 + 14].status, .future)
        XCTAssertEqual(grid.count, 4 + 31)
    }

    func testTheLimitLine() {
        let today = relapses("2026-10-14T16:00:00Z")
        let daily = HabitMath.limitLine(habit(limit: HabitLimit(per: .day, count: 2)), today, now: now, calendar: cal)
        XCTAssertEqual(daily?.text, "1 of 2 today")
        XCTAssertEqual(daily?.over, false)
        let month = relapses("2026-10-02T16:00:00Z", "2026-10-03T16:00:00Z", "2026-10-04T16:00:00Z",
                             "2026-10-05T16:00:00Z", "2026-10-06T16:00:00Z", "2026-10-07T16:00:00Z")
        let monthly = HabitMath.limitLine(habit(limit: HabitLimit(per: .month, count: 5)), month, now: now, calendar: cal)
        XCTAssertEqual(monthly?.text, "6 of 5 this month")
        XCTAssertEqual(monthly?.over, true)
        XCTAssertNil(HabitMath.limitLine(habit(), month, now: now, calendar: cal))
    }

    func testAMonthsStats() {
        let rel = relapses("2026-10-03T19:00:00Z", "2026-10-03T20:00:00Z", "2026-10-09T19:00:00Z")
        let october = HabitMath.period(.month, containing: now, calendar: cal)
        let stats = HabitMath.stats(rel, habit: habit(), period: october, now: now, calendar: cal)
        XCTAssertEqual(stats.total, 3)
        XCTAssertEqual(stats.measuredDays, 14)
        XCTAssertEqual(stats.cleanDays, 12)
        XCTAssertEqual(stats.mostInADay, 2)
        XCTAssertEqual(stats.dailyAverage, 3.0 / 14, accuracy: 0.0001)
        // Oct 3 20:00 → Oct 9 19:00 beats Oct 9 19:00 → now.
        XCTAssertEqual(stats.longest, utc("2026-10-09T19:00:00Z").timeIntervalSince(utc("2026-10-03T20:00:00Z")))
        let before = HabitMath.previous(.month, before: october, calendar: cal)
        XCTAssertEqual(cal.component(.month, from: before.start), 9)
        XCTAssertEqual(HabitMath.count(rel, in: before), 0)
    }

    func testTheHighlight() {
        let october = HabitMath.period(.month, containing: now, calendar: cal)
        XCTAssertEqual(HabitMath.highlight(range: .month, period: october, count: 4, previous: 7, now: now, calendar: cal),
                       "4 relapses in October so far, 3 fewer than in September.")
        XCTAssertEqual(HabitMath.highlight(range: .week, period: october, count: 1, previous: 1, now: now, calendar: cal),
                       "1 relapse in these 7 days, the same as the 7 days before.")
        XCTAssertEqual(HabitMath.highlight(range: .day, period: HabitMath.period(.day, containing: now, calendar: cal),
                                           count: 0, previous: 2, now: now, calendar: cal),
                       "No relapses today, 2 fewer than the day before.")
    }

    func testAHabitDecodesFromTheServerAndLeavesAClearedLimitOut() throws {
        let json = """
        {"id": "scroll", "name": "Doomscrolling", "started_at": "2026-10-01T07:00:00Z", "timezone": "America/Los_Angeles",
         "goal": {"streak_days": 30, "limit": null}, "created_at": "2026-10-01T07:00:00Z", "summary": {"total": 0}}
        """
        let decoded = try HealthClient.decode(Habit.self, from: try JSONSerialization.jsonObject(with: Data(json.utf8)))
        XCTAssertEqual(decoded.goal, HabitGoal(streakDays: 30, limit: nil))
        let sent = try XCTUnwrap(HealthClient.serverJSON(decoded) as? [String: Any])
        XCTAssertEqual(sent["started_at"] as? String, "2026-10-01T07:00:00Z")
        XCTAssertNil((sent["goal"] as? [String: Any])?["limit"])
    }
}

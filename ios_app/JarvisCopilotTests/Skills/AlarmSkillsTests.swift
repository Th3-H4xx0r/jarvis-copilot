import XCTest
@testable import JarvisCopilot

/// `set_alarm` / `set_timer` / `list_alarms` / `cancel_alarm` against the mock
/// scheduler: the native path, every fallback, and the argument rules.
final class AlarmSkillsTests: XCTestCase {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private var now: Date {
        cal.date(from: DateComponents(year: 2026, month: 9, day: 7, hour: 8, minute: 0))!
    }

    private func setAlarm(_ alarms: MockAlarmScheduler, _ notifier: MockNotifier) -> AnySkill {
        DataSkills.setAlarm(alarms, notifier: notifier, now: { self.now }, calendar: cal)
    }

    // MARK: set_alarm

    func testClockTimeSchedulesANativeFixedAlarm() async throws {
        let alarms = MockAlarmScheduler(), notifier = MockNotifier()
        let r = try await setAlarm(alarms, notifier).run(["hour": 9, "minute": 30, "label": "Gym"])
        XCTAssertEqual(r["scheduled"] as? Bool, true)
        XCTAssertEqual(r["native"] as? Bool, true)
        XCTAssertEqual(alarms.scheduled.count, 1)
        XCTAssertEqual(alarms.scheduled.first?.label, "Gym")
        let expected = cal.date(from: DateComponents(year: 2026, month: 9, day: 7, hour: 9, minute: 30))!
        XCTAssertEqual(alarms.scheduled.first?.kind, .fixed(expected))
        XCTAssertEqual(r["id"] as? String, "mock-alarm-1")
        XCTAssertTrue(notifier.posted.isEmpty, "the notification path is not used when AlarmKit works")
    }

    func testAPassedClockTimeRollsToTomorrow() async throws {
        let alarms = MockAlarmScheduler()
        _ = try await setAlarm(alarms, MockNotifier()).run(["hour": 7])
        let expected = cal.date(from: DateComponents(year: 2026, month: 9, day: 8, hour: 7, minute: 0))!
        XCTAssertEqual(alarms.scheduled.first?.kind, .fixed(expected))
    }

    func testInMinutesSchedulesAFixedAlarmFromNow() async throws {
        let alarms = MockAlarmScheduler()
        let r = try await setAlarm(alarms, MockNotifier()).run(["in_minutes": 10])
        XCTAssertEqual(alarms.scheduled.first?.kind, .fixed(now.addingTimeInterval(600)))
        XCTAssertEqual(r["at"] as? String, DataSkills.isoString(now.addingTimeInterval(600)))
    }

    func testRepeatDaysBecomeAWeeklyAlarm() async throws {
        let alarms = MockAlarmScheduler()
        _ = try await setAlarm(alarms, MockNotifier()).run(["hour": 6, "minute": 45, "repeat": ["weekdays"]])
        XCTAssertEqual(alarms.scheduled.first?.kind, .daily(hour: 6, minute: 45, weekdays: [2, 3, 4, 5, 6]))
    }

    func testABadRepeatDayIsRejected() async {
        let alarms = MockAlarmScheduler()
        do {
            _ = try await setAlarm(alarms, MockNotifier()).run(["hour": 6, "repeat": ["funday"]])
            XCTFail("expected badArgument")
        } catch let e as SkillError {
            if case .badArgument = e {} else { XCTFail("wrong error \(e)") }
        } catch { XCTFail("wrong error \(error)") }
        XCTAssertTrue(alarms.scheduled.isEmpty)
    }

    func testSnoozeMinutesArePassedThrough() async throws {
        let alarms = MockAlarmScheduler()
        _ = try await setAlarm(alarms, MockNotifier()).run(["in_minutes": 5, "snooze_minutes": 3])
        XCTAssertEqual(alarms.scheduled.first?.snoozeMinutes, 3)
    }

    func testMissingTimeIsAnError() async throws {
        let r = try await setAlarm(MockAlarmScheduler(), MockNotifier()).run(["label": "x"])
        XCTAssertEqual(r["scheduled"] as? Bool, false)
        XCTAssertNotNil(r["error"])
    }

    func testDeniedAlarmPermissionFallsBackToANotification() async throws {
        let alarms = MockAlarmScheduler(granted: false), notifier = MockNotifier()
        let r = try await setAlarm(alarms, notifier).run(["in_minutes": 10, "label": "Tea"])
        XCTAssertEqual(r["scheduled"] as? Bool, true)
        XCTAssertEqual(r["native"] as? Bool, false)
        XCTAssertNotNil(r["note"])
        XCTAssertTrue(alarms.scheduled.isEmpty)
        XCTAssertEqual(notifier.posted.count, 1)
        XCTAssertEqual(notifier.posted.first?.title, "Tea")
        XCTAssertEqual(notifier.posted.first?.at, now.addingTimeInterval(600))
        XCTAssertEqual(notifier.posted.first?.sound, true)
    }

    func testUnavailableFrameworkSkipsThePromptAndFallsBack() async throws {
        let alarms = MockAlarmScheduler(available: false), notifier = MockNotifier()
        let r = try await setAlarm(alarms, notifier).run(["in_minutes": 1])
        XCTAssertEqual(r["native"] as? Bool, false)
        XCTAssertEqual(alarms.authorizationRequests, 0, "no permission prompt on a system without AlarmKit")
        XCTAssertEqual(notifier.posted.count, 1)
    }

    func testASchedulingFailureFallsBackToANotification() async throws {
        let alarms = MockAlarmScheduler(), notifier = MockNotifier()
        alarms.scheduleError = SkillError.failed("maximum limit reached")
        let r = try await setAlarm(alarms, notifier).run(["in_minutes": 1])
        XCTAssertEqual(r["native"] as? Bool, false)
        XCTAssertEqual(notifier.posted.count, 1)
        XCTAssertTrue((r["note"] as? String ?? "").contains("maximum limit reached"))
    }

    func testRepeatCannotFallBackToANotification() async throws {
        // A weekly alarm has no notification equivalent here: say so instead of
        // quietly scheduling a single one.
        let alarms = MockAlarmScheduler(granted: false), notifier = MockNotifier()
        let r = try await setAlarm(alarms, notifier).run(["hour": 6, "repeat": ["mon"]])
        XCTAssertEqual(r["scheduled"] as? Bool, false)
        XCTAssertTrue(notifier.posted.isEmpty)
    }

    func testARepeatGivenAsABareStringIsAccepted() async throws {
        let alarms = MockAlarmScheduler()
        _ = try await setAlarm(alarms, MockNotifier()).run(["hour": 6, "repeat": "weekdays"])
        XCTAssertEqual(alarms.scheduled.first?.kind, .daily(hour: 6, minute: 0, weekdays: [2, 3, 4, 5, 6]))
    }

    func testInMinutesWithRepeatIsStillAOneOff() async throws {
        // "in 10 minutes" names an instant, not a time of day — there is
        // nothing to repeat, and the result must not claim otherwise.
        let alarms = MockAlarmScheduler()
        let r = try await setAlarm(alarms, MockNotifier()).run(["in_minutes": 10, "repeat": ["mon"]])
        XCTAssertEqual(alarms.scheduled.first?.kind, .fixed(now.addingTimeInterval(600)))
        XCTAssertNil(r["repeat"], "a one-off alarm must not advertise a repeat")
    }

    func testInMinutesWithRepeatStillFallsBackToANotification() async throws {
        let notifier = MockNotifier()
        let r = try await setAlarm(MockAlarmScheduler(granted: false), notifier).run(["in_minutes": 5, "repeat": ["mon"]])
        XCTAssertEqual(r["scheduled"] as? Bool, true, "a one-off has a perfectly good notification fallback")
        XCTAssertEqual(notifier.posted.count, 1)
    }

    // MARK: set_timer

    func testTimerMinutesBecomeACountdown() async throws {
        let alarms = MockAlarmScheduler()
        let skill = DataSkills.setTimer(alarms, notifier: MockNotifier(), now: { self.now })
        let r = try await skill.run(["minutes": 10, "label": "Pasta"])
        XCTAssertEqual(r["native"] as? Bool, true)
        XCTAssertEqual(alarms.scheduled.first?.kind, .timer(seconds: 600))
        XCTAssertEqual(alarms.scheduled.first?.label, "Pasta")
        XCTAssertEqual(r["seconds"] as? Int, 600)
    }

    func testTimerSecondsAddToMinutes() async throws {
        let alarms = MockAlarmScheduler()
        let skill = DataSkills.setTimer(alarms, notifier: MockNotifier(), now: { self.now })
        _ = try await skill.run(["minutes": 1, "seconds": 30])
        XCTAssertEqual(alarms.scheduled.first?.kind, .timer(seconds: 90))
    }

    func testTimerWithoutADurationIsAnError() async throws {
        let skill = DataSkills.setTimer(MockAlarmScheduler(), notifier: MockNotifier(), now: { self.now })
        let r = try await skill.run([:])
        XCTAssertEqual(r["scheduled"] as? Bool, false)
    }

    func testTimerFallsBackToANotificationWhenDenied() async throws {
        let notifier = MockNotifier()
        let skill = DataSkills.setTimer(MockAlarmScheduler(granted: false), notifier: notifier, now: { self.now })
        let r = try await skill.run(["minutes": 2])
        XCTAssertEqual(r["native"] as? Bool, false)
        XCTAssertEqual(notifier.posted.first?.at, now.addingTimeInterval(120))
        XCTAssertEqual(notifier.posted.first?.title, "Timer")
    }

    // MARK: list_alarms / cancel_alarm

    func testListMergesNativeAndNotificationAlarms() async throws {
        let alarms = MockAlarmScheduler(), notifier = MockNotifier()
        _ = try await alarms.schedule(AlarmSpec(kind: .timer(seconds: 60), label: "Egg"))
        _ = try await setAlarm(MockAlarmScheduler(granted: false), notifier).run(["in_minutes": 5])
        let r = try await DataSkills.listAlarms(alarms, notifier: notifier).run([:])
        let list = try XCTUnwrap(r["alarms"] as? [[String: Any]])
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0]["label"] as? String, "Egg")
        XCTAssertEqual(list[0]["native"] as? Bool, true)
        XCTAssertEqual(list[0]["kind"] as? String, "timer")
        XCTAssertEqual(list[1]["native"] as? Bool, false)
        XCTAssertTrue((list[1]["id"] as? String ?? "").hasPrefix("jc-alarm-"))
    }

    func testCancelByIdRemovesANativeAlarm() async throws {
        let alarms = MockAlarmScheduler()
        let a = try await alarms.schedule(AlarmSpec(kind: .timer(seconds: 60), label: "Egg"))
        let r = try await DataSkills.cancelAlarm(alarms, notifier: MockNotifier()).run(["id": a.id])
        XCTAssertEqual(r["cancelled"] as? Bool, true)
        XCTAssertEqual(alarms.cancelled, [a.id])
        XCTAssertEqual(alarms.stopped, [a.id], "a ringing alarm is silenced too")
    }

    func testCancelANotificationAlarmGoesToTheNotifier() async throws {
        let notifier = MockNotifier()
        let r = try await DataSkills.cancelAlarm(MockAlarmScheduler(), notifier: notifier).run(["id": "jc-alarm-123"])
        XCTAssertEqual(r["cancelled"] as? Bool, true)
        XCTAssertEqual(notifier.cancelled, ["jc-alarm-123"])
    }

    func testAWeeklyAlarmReportsTheNextMatchingWeekday() async throws {
        // 2026-09-07 08:00 UTC is a Monday. A Friday-only alarm rings on the 11th.
        let alarms = MockAlarmScheduler()
        let r = try await setAlarm(alarms, MockNotifier()).run(["hour": 6, "repeat": ["fri"]])
        let at = try XCTUnwrap(r["at"] as? String)
        XCTAssertTrue(at.hasPrefix("2026-09-11"), "expected the next Friday, got \(at)")
        XCTAssertEqual(r["repeat"] as? [String], ["Fri"])
    }

    func testCancelAllClearsEverything() async throws {
        let alarms = MockAlarmScheduler(), notifier = MockNotifier()
        _ = try await alarms.schedule(AlarmSpec(kind: .timer(seconds: 60), label: "a"))
        _ = try await alarms.schedule(AlarmSpec(kind: .timer(seconds: 90), label: "b"))
        _ = try await setAlarm(MockAlarmScheduler(granted: false), notifier).run(["in_minutes": 5])
        let r = try await DataSkills.cancelAlarm(alarms, notifier: notifier).run(["all": true])
        XCTAssertEqual(r["cancelled_count"] as? Int, 3)
        XCTAssertTrue(alarms.existing.isEmpty)
        XCTAssertEqual(notifier.cancelled.count, 1)
    }

    func testCancelUnknownIdReportsFailure() async throws {
        let r = try await DataSkills.cancelAlarm(MockAlarmScheduler(), notifier: MockNotifier()).run(["id": "nope"])
        XCTAssertEqual(r["cancelled"] as? Bool, false)
        XCTAssertNotNil(r["error"])
    }

    func testCancelWithoutArgsIsAnError() async throws {
        let r = try await DataSkills.cancelAlarm(MockAlarmScheduler(), notifier: MockNotifier()).run([:])
        XCTAssertEqual(r["cancelled"] as? Bool, false)
    }
}

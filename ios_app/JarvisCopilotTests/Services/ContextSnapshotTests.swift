import Foundation
import XCTest
@testable import JarvisCopilot

/// The calendar / reminders / time zone snapshot the server's now brief reads.
@MainActor
final class ContextSnapshotTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_790_000_000)

    private func iso(_ date: Date) -> String { DataSkills.isoString(date) }

    func testPayloadShapeAndThrottle() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/devices/mobile/context",
                        json: ["ok": true, "calendar": 1, "reminders": 2, "tz": "Europe/London"])
        let clock = SnapshotClock(base)
        let sources = FakeContextSources(
            events: [CalendarEventRecord(title: "Dentist", notes: "bring card", location: "High St",
                                         start: base.addingTimeInterval(3600),
                                         end: base.addingTimeInterval(7200),
                                         allDay: false, calendar: "Home")],
            reminders: [ReminderRecord(title: "Pay rent", due: base.addingTimeInterval(86_400), list: "Bills"),
                        ReminderRecord(title: "Call mum", due: nil, list: "Family")])
        let snapshot = ContextSnapshot(api: api, sources: sources, now: { clock.now },
                                       timeZone: TimeZone(identifier: "Europe/London")!)

        await snapshot.pushIfDue()

        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(transport.lastRequest?.url?.path, "/api/devices/mobile/context")
        XCTAssertEqual(sources.windows.first?.from, base.addingTimeInterval(-86_400), "from a day back")
        XCTAssertEqual(sources.windows.first?.to, base.addingTimeInterval(14 * 86_400), "to two weeks out")

        let body = transport.lastBody()
        XCTAssertEqual(Set(body.keys), ["tz", "calendar", "reminders", "sent_at"])
        XCTAssertEqual(body["tz"] as? String, "Europe/London")
        XCTAssertEqual(body["sent_at"] as? String, iso(base))

        let calendar = try XCTUnwrap(body["calendar"] as? [[String: Any]])
        XCTAssertEqual(calendar.count, 1)
        XCTAssertEqual(Set(calendar[0].keys), ["title", "start_iso", "end_iso", "all_day", "location", "calendar"],
                       "the list_calendar_events shape, without the notes")
        XCTAssertEqual(calendar[0]["title"] as? String, "Dentist")
        XCTAssertEqual(calendar[0]["start_iso"] as? String, iso(base.addingTimeInterval(3600)))
        XCTAssertEqual(calendar[0]["end_iso"] as? String, iso(base.addingTimeInterval(7200)))
        XCTAssertEqual(calendar[0]["all_day"] as? Bool, false)
        XCTAssertEqual(calendar[0]["location"] as? String, "High St")
        XCTAssertEqual(calendar[0]["calendar"] as? String, "Home")

        let reminders = try XCTUnwrap(body["reminders"] as? [[String: Any]])
        XCTAssertEqual(reminders.count, 2)
        XCTAssertEqual(Set(reminders[0].keys), ["title", "due_iso", "list"])
        XCTAssertEqual(reminders[0]["title"] as? String, "Pay rent")
        XCTAssertEqual(reminders[0]["due_iso"] as? String, iso(base.addingTimeInterval(86_400)))
        XCTAssertEqual(reminders[0]["list"] as? String, "Bills")
        XCTAssertTrue(reminders[1]["due_iso"] is NSNull, "no due date goes as null, not \"\"")

        // Ten minutes later: inside the 15-minute window, nothing goes.
        clock.now = base.addingTimeInterval(10 * 60)
        await snapshot.pushIfDue()
        XCTAssertEqual(transport.requests.count, 1)

        // A forced push (a calendar change) goes anyway.
        await snapshot.pushIfDue(force: true)
        XCTAssertEqual(transport.requests.count, 2)

        // And once the window has passed since that one, a plain push goes again.
        clock.now = base.addingTimeInterval(26 * 60)
        await snapshot.pushIfDue()
        XCTAssertEqual(transport.requests.count, 3)
    }

    /// Coming to the front forces a push only when the last one is over an hour old.
    func testForegroundForcesOnlyWhenTheLastPushIsStale() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/devices/mobile/context", json: ["ok": true])
        let clock = SnapshotClock(base)
        let snapshot = ContextSnapshot(api: api, sources: FakeContextSources(), now: { clock.now },
                                       timeZone: .gmt)

        await snapshot.appForegrounded()
        XCTAssertEqual(transport.requests.count, 1, "the first foreground always pushes")

        clock.now = base.addingTimeInterval(5 * 60)
        await snapshot.appForegrounded()
        XCTAssertEqual(transport.requests.count, 1, "a quick app switch is not a reason to push")

        clock.now = base.addingTimeInterval(61 * 60)
        await snapshot.appForegrounded()
        XCTAssertEqual(transport.requests.count, 2)
    }

    /// A failed POST is logged, never thrown — and it still counts as a try, so a
    /// server that is down isn't hit on every trigger.
    func testAFailedPushIsSilent() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/devices/mobile/context", json: ["error": "down"], status: 500)
        let clock = SnapshotClock(base)
        let snapshot = ContextSnapshot(api: api, sources: FakeContextSources(), now: { clock.now },
                                       timeZone: .gmt)

        await snapshot.pushIfDue()
        await snapshot.pushIfDue()
        XCTAssertEqual(transport.requests.count, 1)
    }
}

@MainActor
private final class SnapshotClock {
    var now: Date
    init(_ now: Date) { self.now = now }
}

@MainActor
private final class FakeContextSources: ContextSources {
    let eventList: [CalendarEventRecord]
    let reminderList: [ReminderRecord]
    private(set) var windows: [(from: Date, to: Date)] = []

    init(events: [CalendarEventRecord] = [], reminders: [ReminderRecord] = []) {
        eventList = events
        reminderList = reminders
    }

    func events(from: Date, to: Date) async -> [CalendarEventRecord] {
        windows.append((from, to))
        return eventList
    }

    func openReminders() async -> [ReminderRecord] { reminderList }
}

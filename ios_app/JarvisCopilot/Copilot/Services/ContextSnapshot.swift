import EventKit
import Foundation

/// One open reminder as the context snapshot sends it.
struct ReminderRecord: Sendable, Equatable {
    let title: String
    let due: Date?
    let list: String
}

/// Where the snapshot's calendar and reminders come from. Neither call may
/// prompt: the snapshot runs from the background (a location fix, a calendar
/// change), where a permission sheet has no one to answer it. No access = empty.
@MainActor
protocol ContextSources: AnyObject {
    func events(from: Date, to: Date) async -> [CalendarEventRecord]
    /// Incomplete reminders — only when Reminders full access is already granted.
    func openReminders() async -> [ReminderRecord]
}

/// Pushes the phone's calendar (yesterday to two weeks out), open reminders and
/// time zone to `/api/devices/mobile/context`, so the server's now brief knows
/// what's on his plate without asking the phone mid-turn.
///
/// Sent on foreground, on a calendar or reminders change and after a location
/// fix — at most every 15 minutes unless forced. A failure is logged, never
/// surfaced: the next trigger tries again.
@MainActor
final class ContextSnapshot {

    static let shared = ContextSnapshot()

    /// A plain push waits at least this long after the last one…
    static let minInterval: TimeInterval = 15 * 60
    /// …and coming to the front forces one when the last is older than this.
    static let foregroundForceAfter: TimeInterval = 60 * 60
    static let lookBack: TimeInterval = 24 * 60 * 60
    static let lookAhead: TimeInterval = 14 * 24 * 60 * 60

    private let api: JarvisAPI
    private let sources: any ContextSources
    private let now: @MainActor () -> Date
    private let timeZone: () -> TimeZone

    /// When the last push was tried. Stamped before the POST, so triggers that
    /// land together (foreground + a calendar change) send once.
    private(set) var lastPushAt: Date?
    private var inFlight = false
    /// A forced push asked for while one was running: run once more after it.
    private var forceAgain = false
    private var storeObserver: NSObjectProtocol?

    init(api: JarvisAPI = .shared,
         sources: (any ContextSources)? = nil,
         now: (@MainActor () -> Date)? = nil,
         timeZone: TimeZone? = nil) {
        self.api = api
        self.sources = sources ?? EventKitContextSources()
        self.now = now ?? { Date() }
        self.timeZone = { timeZone ?? .current }
    }

    /// Watch for calendar and reminders edits (here, in Calendar, or synced in).
    func start() {
        guard storeObserver == nil else { return }
        storeObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged,
                                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { Task { await self?.pushIfDue(force: true) } }
        }
    }

    /// The app came to the front.
    func appForegrounded() async {
        let stale = lastPushAt.map { now().timeIntervalSince($0) > Self.foregroundForceAfter } ?? true
        await pushIfDue(force: stale)
    }

    func pushIfDue(force: Bool = false) async {
        if inFlight {
            if force { forceAgain = true }
            return
        }
        if !force, let lastPushAt, now().timeIntervalSince(lastPushAt) < Self.minInterval { return }
        inFlight = true
        lastPushAt = now()
        do {
            _ = try await api.post("/api/devices/mobile/context", json: await payload())
        } catch {
            JcLog.dropped(JcLog.services, "context snapshot", error)
        }
        inFlight = false
        if forceAgain {
            forceAgain = false
            await pushIfDue(force: true)
        }
    }

    /// The POST body. Events use the `list_calendar_events` field shape.
    func payload() async -> [String: Any] {
        let at = now()
        let events = await sources.events(from: at.addingTimeInterval(-Self.lookBack),
                                          to: at.addingTimeInterval(Self.lookAhead))
        let reminders = await sources.openReminders()
        return [
            "tz": timeZone().identifier,
            "calendar": events.map { event in
                [
                    "title": event.title,
                    "start_iso": event.start.map(DataSkills.isoString) ?? "",
                    "end_iso": event.end.map(DataSkills.isoString) ?? "",
                    "all_day": event.allDay,
                    "location": event.location,
                    "calendar": event.calendar,
                ] as [String: Any]
            },
            "reminders": reminders.map { reminder in
                [
                    "title": reminder.title,
                    "due_iso": reminder.due.map { DataSkills.isoString($0) as Any } ?? NSNull(),
                    "list": reminder.list,
                ] as [String: Any]
            },
            "sent_at": DataSkills.isoString(at),
        ]
    }
}

/// Reminders permission for the Long-term Memory page's "Let Jarvis see Reminders".
enum RemindersAccess {
    /// Never asked yet — the only state where asking shows the system sheet.
    static var notDetermined: Bool {
        EKEventStore.authorizationStatus(for: .reminder) == .notDetermined
    }

    static var granted: Bool {
        EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    }

    /// Shows the system sheet. False on a refusal or a failed request.
    static func request() async -> Bool {
        do {
            return try await EKEventStore().requestFullAccessToReminders()
        } catch {
            JcLog.dropped(JcLog.services, "reminders access", error)
            return false
        }
    }
}

/// EventKit, read only with access already granted.
@MainActor
final class EventKitContextSources: ContextSources {
    /// The same reader `list_calendar_events` uses.
    private let calendar = DefaultCalendarAccess()
    private let store = EKEventStore()
    /// Plenty for two weeks of events or a to-do list.
    static let limit = 200

    func events(from: Date, to: Date) async -> [CalendarEventRecord] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        do {
            return try await calendar.events(from: from, to: to, limit: Self.limit)
        } catch {
            JcLog.dropped(JcLog.services, "context snapshot calendar", error)
            return []
        }
    }

    func openReminders() async -> [ReminderRecord] {
        guard RemindersAccess.granted else { return [] }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil,
                                                               calendars: nil)
        let records: [ReminderRecord] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let out = (reminders ?? []).map { reminder in
                    ReminderRecord(title: reminder.title ?? "",
                                   due: reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) },
                                   list: reminder.calendar?.title ?? "")
                }
                continuation.resume(returning: out)
            }
        }
        // Dated ones first, soonest first; then the undated.
        return Array(records.sorted { a, b in
            switch (a.due, b.due) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            default: return false
            }
        }.prefix(Self.limit))
    }
}

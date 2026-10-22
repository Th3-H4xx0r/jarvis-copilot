import EventKit
import Foundation

/// One open reminder as the context snapshot sends it.
struct ReminderRecord: Sendable, Equatable {
    let title: String
    let due: Date?
    let list: String
}

/// Where the snapshot's calendar and reminders come from. Neither read may
/// prompt: the snapshot runs from the background (a location fix, a calendar
/// change), where a permission sheet has no one to answer it.
///
/// No access = empty (that IS what the phone can see). A read that failed = nil,
/// and nothing is sent: an empty list would wipe the server's snapshot.
@MainActor
protocol ContextSources: AnyObject {
    func events(from: Date, to: Date) async -> [CalendarEventRecord]?
    /// Incomplete reminders — only when Reminders full access is already granted.
    func openReminders() async -> [ReminderRecord]?
    /// The store whose `EKEventStoreChanged` means our data changed. nil = none.
    var changeObject: AnyObject? { get }
    /// Shows the system sheet, on the same store the reads use.
    func requestRemindersAccess() async -> Bool
}

/// Pushes the phone's calendar (yesterday to two weeks out), open reminders and
/// time zone to `/api/devices/mobile/context`, so the server's now brief knows
/// what's on his plate without asking the phone mid-turn.
///
/// Sent on foreground, on a calendar or reminders change and after a location
/// fix — at most every 15 minutes unless forced, and never twice in a minute.
/// A failure is logged, never surfaced: it tries again after two minutes.
@MainActor
final class ContextSnapshot {

    static let shared = ContextSnapshot()

    /// A plain push waits at least this long after the last one…
    static let minInterval: TimeInterval = 15 * 60
    /// …or this long after one the server didn't take…
    static let retryAfterFailure: TimeInterval = 2 * 60
    /// …and even a forced one keeps this gap.
    static let forcedGap: TimeInterval = 60
    /// iCloud / Exchange syncs post change notifications in storms: one push per burst.
    static let changeDebounce: TimeInterval = 20
    /// Coming to the front forces a push when the last is older than this.
    static let foregroundForceAfter: TimeInterval = 60 * 60
    static let lookBack: TimeInterval = 24 * 60 * 60
    static let lookAhead: TimeInterval = 14 * 24 * 60 * 60

    private let api: JarvisAPI
    private let sources: any ContextSources
    private let now: @MainActor () -> Date
    private let timeZone: () -> TimeZone
    private let sleeper: Sleeper

    /// When the last push was sent. Stamped before the POST, so triggers that
    /// land together (foreground + a location fix) send once.
    private(set) var lastPushAt: Date?
    /// When a plain push may go again: 15 min after a sent one, 2 after a failed one.
    private var nextDueAt: Date?
    private var inFlight = false
    private let changeTask = TaskHandle()
    private var storeObserver: NSObjectProtocol?

    init(api: JarvisAPI = .shared,
         sources: (any ContextSources)? = nil,
         now: (@MainActor () -> Date)? = nil,
         timeZone: TimeZone? = nil,
         sleeper: Sleeper? = nil) {
        self.api = api
        self.sources = sources ?? EventKitContextSources()
        self.now = now ?? { Date() }
        self.timeZone = { timeZone ?? .current }
        self.sleeper = sleeper ?? wallClockSleeper
    }

    /// Watch for calendar and reminders edits (here, in Calendar, or synced in) —
    /// on OUR store only: every store in the process posts its own.
    func start() {
        guard storeObserver == nil, let object = sources.changeObject else { return }
        storeObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged,
                                                               object: object, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.storeChanged() }
        }
    }

    func stop() {
        if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
        storeObserver = nil
        changeTask.cancel()
    }

    /// A change: wait for the burst to settle, then for the minute gap, then push.
    func storeChanged() {
        changeTask.replace(Task { [weak self] in
            guard let self else { return }
            do {
                try await self.sleeper(Self.changeDebounce)
                if let last = self.lastPushAt {
                    let wait = Self.forcedGap - self.now().timeIntervalSince(last)
                    if wait > 0 { try await self.sleeper(wait) }
                }
            } catch {
                return   // a newer change replaced this one
            }
            guard !Task.isCancelled else { return }
            // Outside the handle: a later change must not cancel a POST on the wire.
            Task { await self.pushIfDue(force: true) }
        })
    }

    /// The app came to the front.
    func appForegrounded() async {
        let stale = lastPushAt.map { now().timeIntervalSince($0) > Self.foregroundForceAfter } ?? true
        await pushIfDue(force: stale)
    }

    /// "Let Jarvis see Reminders": ask, then send them once the store has them.
    func requestRemindersAccess() async -> Bool {
        let granted = await sources.requestRemindersAccess()
        if granted { storeChanged() }
        return granted
    }

    func pushIfDue(force: Bool = false) async {
        if inFlight {
            // Its data may predate this change: send again once it's done.
            if force { storeChanged() }
            return
        }
        let at = now()
        if let lastPushAt {
            if force {
                if at.timeIntervalSince(lastPushAt) < Self.forcedGap { return }
            } else if let nextDueAt, at < nextDueAt {
                return
            }
        }
        inFlight = true
        defer { inFlight = false }
        guard let body = await payload() else {
            JcLog.services.notice("context snapshot: a calendar or reminders read failed; not sent")
            return
        }
        let sentAt = now()
        lastPushAt = sentAt
        nextDueAt = sentAt.addingTimeInterval(Self.minInterval)
        do {
            _ = try await api.post("/api/devices/mobile/context", json: body)
        } catch {
            nextDueAt = sentAt.addingTimeInterval(Self.retryAfterFailure)
            JcLog.dropped(JcLog.services, "context snapshot", error)
        }
    }

    /// The POST body, or nil when a read failed. Events use the
    /// `list_calendar_events` field shape.
    func payload() async -> [String: Any]? {
        let at = now()
        guard let events = await sources.events(from: at.addingTimeInterval(-Self.lookBack),
                                                to: at.addingTimeInterval(Self.lookAhead)),
              let reminders = await sources.openReminders() else { return nil }
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
/// Asking goes through `ContextSnapshot.requestRemindersAccess`, on the store it reads.
enum RemindersAccess {
    /// Never asked yet — the only state where asking shows the system sheet.
    static var notDetermined: Bool {
        EKEventStore.authorizationStatus(for: .reminder) == .notDetermined
    }

    static var granted: Bool {
        EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    }
}

/// EventKit, read only with access already granted.
///
/// One store, kept for the app's life so its change notifications can be
/// watched. A store made before access was granted reads nothing until it is
/// reset, so it is reset whenever either permission has changed since it last read.
@MainActor
final class EventKitContextSources: ContextSources {
    private let store = EKEventStore()
    /// The same reader `list_calendar_events` uses, on our store.
    private let calendar: DefaultCalendarAccess
    private var eventStatus = EKEventStore.authorizationStatus(for: .event)
    private var reminderStatus = EKEventStore.authorizationStatus(for: .reminder)
    /// Plenty for two weeks of events or a to-do list.
    static let limit = 200

    init() {
        calendar = DefaultCalendarAccess(store: store)
    }

    var changeObject: AnyObject? { store }

    func events(from: Date, to: Date) async -> [CalendarEventRecord]? {
        resetIfAccessChanged()
        guard eventStatus == .fullAccess else { return [] }
        do {
            return try await calendar.events(from: from, to: to, limit: Self.limit)
        } catch {
            JcLog.dropped(JcLog.services, "context snapshot calendar", error)
            return nil
        }
    }

    func openReminders() async -> [ReminderRecord]? {
        resetIfAccessChanged()
        guard reminderStatus == .fullAccess else { return [] }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil,
                                                               calendars: nil)
        let fetched: [ReminderRecord]? = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                // nil is EventKit's "the fetch failed", not "none open".
                let out = reminders?.map { reminder in
                    ReminderRecord(title: reminder.title ?? "",
                                   due: reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) },
                                   list: reminder.calendar?.title ?? "")
                }
                continuation.resume(returning: out)
            }
        }
        guard let records = fetched else { return nil }
        // Dated ones first, soonest first; then the undated.
        return Array(records.sorted { a, b in
            switch (a.due, b.due) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            default: return false
            }
        }.prefix(Self.limit))
    }

    func requestRemindersAccess() async -> Bool {
        do {
            let granted = try await store.requestFullAccessToReminders()
            resetIfAccessChanged()
            return granted
        } catch {
            JcLog.dropped(JcLog.services, "reminders access", error)
            return false
        }
    }

    private func resetIfAccessChanged() {
        let events = EKEventStore.authorizationStatus(for: .event)
        let reminders = EKEventStore.authorizationStatus(for: .reminder)
        guard events != eventStatus || reminders != reminderStatus else { return }
        eventStatus = events
        reminderStatus = reminders
        store.reset()
    }
}

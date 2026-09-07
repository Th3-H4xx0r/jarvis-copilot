import Foundation

/// What a skill asks the system to ring. Framework-free so the skills (and
/// their tests) never touch AlarmKit; `DefaultAlarmScheduler` translates it.
struct AlarmSpec: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// One-off, at an absolute instant.
        case fixed(Date)
        /// Every listed weekday at hour:minute (1 = Sunday … 7 = Saturday, as
        /// `Calendar` numbers them). Empty weekdays = the next occurrence only.
        case daily(hour: Int, minute: Int, weekdays: [Int])
        /// A countdown starting now.
        case timer(seconds: TimeInterval)
    }

    var kind: Kind
    var label: String
    /// Length of a Snooze press. AlarmKit's "post-alert countdown".
    var snoozeMinutes: Int = 9

    /// The next hour:minute after `from` — today if still ahead, else tomorrow.
    static func nextOccurrence(hour: Int, minute: Int, from now: Date,
                               calendar: Calendar = .current) -> Date? {
        var parts = calendar.dateComponents([.year, .month, .day], from: now)
        parts.hour = hour
        parts.minute = minute
        parts.second = 0
        guard let today = calendar.date(from: parts) else { return nil }
        if today > now { return today }
        return calendar.date(byAdding: .day, value: 1, to: today)
    }
}

/// An alarm the system currently knows about, in the skill's vocabulary.
struct ScheduledAlarm: Equatable, Sendable {
    var id: String
    var label: String
    var kind: AlarmSpec.Kind
    /// "scheduled" | "countdown" | "paused" | "alerting" (AlarmKit's states).
    var state: String
    /// When it will next ring, when the system can say.
    var fireDate: Date?
}

/// The system alarm clock behind `set_alarm` / `set_timer` / `list_alarms` /
/// `cancel_alarm`. `DefaultAlarmScheduler` is AlarmKit (iOS 26+);
/// `UnavailableAlarmScheduler` is what older systems get, and the skills then
/// fall back to a notification alarm.
protocol AlarmScheduling: Sendable {
    /// False when the framework is missing (pre-iOS 26). Skills skip straight to
    /// the fallback without asking for permission.
    var isAvailable: Bool { get }
    /// Prompts on first use. False when the user denied; THROWS when the request
    /// itself failed, matching `Notifying`.
    func requestAuthorization() async throws -> Bool
    func schedule(_ spec: AlarmSpec) async throws -> ScheduledAlarm
    func list() async throws -> [ScheduledAlarm]
    func cancel(id: String) async throws
    /// Silence an alarm that is ringing right now.
    func stop(id: String) async throws
}

struct UnavailableAlarmScheduler: AlarmScheduling {
    var isAvailable: Bool { false }
    func requestAuthorization() async throws -> Bool { false }
    func schedule(_ spec: AlarmSpec) async throws -> ScheduledAlarm {
        throw SkillError.unavailable("system alarms need iOS 26")
    }
    func list() async throws -> [ScheduledAlarm] { [] }
    func cancel(id: String) async throws {}
    func stop(id: String) async throws {}
}

/// "mon", "Monday", "weekdays", "weekends", "daily" → Calendar weekday numbers.
enum AlarmWeekdays {
    private static let names: [String: Int] = [
        "sun": 1, "sunday": 1, "mon": 2, "monday": 2, "tue": 3, "tues": 3, "tuesday": 3,
        "wed": 4, "wednesday": 4, "thu": 5, "thur": 5, "thurs": 5, "thursday": 5,
        "fri": 6, "friday": 6, "sat": 7, "saturday": 7,
    ]

    /// Nil when any entry is unrecognised, so a typo is refused instead of
    /// silently scheduling fewer days than asked. Sorted, de-duplicated.
    static func parse(_ words: [String]) -> [Int]? {
        var out = Set<Int>()
        for raw in words {
            let w = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch w {
            case "": continue
            case "daily", "everyday", "every day", "all": out.formUnion(1...7)
            case "weekdays": out.formUnion(2...6)
            case "weekends", "weekend": out.formUnion([1, 7])
            default:
                guard let n = names[w] else { return nil }
                out.insert(n)
            }
        }
        return out.sorted()
    }

    static func name(_ weekday: Int) -> String {
        ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][max(0, min(7, weekday))]
    }
}

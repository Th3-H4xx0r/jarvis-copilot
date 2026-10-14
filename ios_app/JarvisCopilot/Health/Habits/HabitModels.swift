import Foundation

/// At most `count` relapses a day or a month.
struct HabitLimit: Codable, Equatable, Hashable {
    enum Period: String, Codable, CaseIterable { case day, month }
    var per: Period
    var count: Int
}

/// A streak to reach and a limit to stay under; either, both or neither.
struct HabitGoal: Codable, Equatable, Hashable {
    var streakDays: Int?
    var limit: HabitLimit?

    enum CodingKeys: String, CodingKey {
        case streakDays = "streak_days", limit
    }
}

/// A habit being quit, as Jarvis Health keeps it (`habit-<id>`). Chat can
/// create and edit these too, so the server's copy is the one that counts.
struct Habit: Codable, Equatable, Hashable, Identifiable {
    var id: String
    var name: String
    /// When it was quit: the streak runs from here until the first relapse.
    var startedAt: Date
    /// Where its days and months are counted; the phone sends its own.
    var timezone: String
    var goal: HabitGoal
    var createdAt: Date?
    var updatedAt: Date?

    init(id: String = UUID().uuidString.lowercased(), name: String, startedAt: Date = Date().wholeSeconds,
         timezone: String = TimeZone.current.identifier, goal: HabitGoal = HabitGoal(),
         createdAt: Date? = nil, updatedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.startedAt = startedAt
        self.timezone = timezone
        self.goal = goal
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name, timezone, goal
        case startedAt = "started_at", createdAt = "created_at", updatedAt = "updated_at"
    }
}

/// One relapse. `uid` is made here, so a send retried after a timeout is
/// still stored once.
struct HabitRelapse: Codable, Equatable, Hashable, Identifiable {
    var habit: String
    var uid: String
    var at: Date
    var tz: String?
    var note: String?

    var id: String { uid }
}

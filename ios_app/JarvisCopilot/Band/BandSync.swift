import Foundation

/// Reads the band's history — up to three days of daily records and sleep — into the shared
/// `RingDay` store, and reports which days changed (Jarvis Health pushes them).
@MainActor
final class BandSync: ObservableObject {
    @Published private(set) var isSyncing = false
    /// How far the sync under way is, 0…1 (nil when none is) — the page shows it as a percentage.
    @Published private(set) var progress: Double?
    /// What the sync is reading now ("Activity · Yesterday").
    @Published private(set) var stage: String?
    @Published private(set) var lastSync: Date?
    /// How often the band syncs on its own while it is connected; 0 = only when asked.
    @Published var interval: TimeInterval {
        didSet { defaults.set(interval, forKey: Self.intervalKey) }
    }
    var onDaysChanged: ((Set<String>) -> Void)?

    private let session: BandSession
    private let store: () -> RingHistoryStore?
    private let defaults: UserDefaults
    static let lastSyncKey = "jc.band.lastSync"
    static let intervalKey = "jc.band.syncInterval"
    /// How old a sync may be before another starts, unless he picks otherwise.
    static let defaultInterval: TimeInterval = 30 * 60
    /// The choices in the band's settings (0 = manual).
    static let intervals: [TimeInterval] = [15 * 60, 30 * 60, 60 * 60, 2 * 60 * 60, 4 * 60 * 60, 0]

    init(session: BandSession, store: @escaping () -> RingHistoryStore?, defaults: UserDefaults = .standard) {
        self.session = session
        self.store = store
        self.defaults = defaults
        lastSync = defaults.object(forKey: Self.lastSyncKey) as? Date
        interval = defaults.object(forKey: Self.intervalKey) as? TimeInterval ?? Self.defaultInterval
    }

    /// Whether the interval has passed since the last sync (never, when syncing is manual).
    var isStale: Bool {
        guard interval > 0 else { return false }
        return lastSync.map { Date().timeIntervalSince($0) > interval } ?? true
    }

    /// When the periodic sync last set out, reached or not: a band it gave up on is next tried
    /// an interval later, not every minute.
    private(set) var lastAttempt: Date?
    func attempted() { lastAttempt = Date() }

    /// When the next sync on the interval is due (nil when syncing is manual).
    var nextDue: Date? {
        guard interval > 0 else { return nil }
        guard let since = [lastSync, lastAttempt].compactMap({ $0 }).max() else { return Date() }
        return since.addingTimeInterval(interval)
    }

    var isDue: Bool { nextDue.map { $0 <= Date() } ?? false }

    static func label(_ interval: TimeInterval) -> String {
        switch interval {
        case 0: return "Manual"
        case ..<3600: return "\(Int(interval / 60)) min"
        case 3600: return "1 hour"
        default: return "\(Int(interval / 3600)) hours"
        }
    }

    /// Whether the last sync got any answer from the band (`band_sync` reports `ok: false` if not).
    private(set) var lastReached = true
    private var running: Task<Set<String>, Never>?

    /// Pulls `days` days (the band keeps three) and merges them into the store. A sync already
    /// under way is shared rather than started twice.
    @discardableResult
    func sync(days: Int = 3) async -> Set<String> {
        if let running { return await running.value }
        let task = Task { await self.run(days: days) }
        running = task
        defer { running = nil }
        return await task.value
    }

    private func run(days: Int) async -> Set<String> {
        guard let store = store() else { return [] }
        isSyncing = true
        progress = 0
        defer {
            isSyncing = false
            progress = nil
            stage = nil
        }
        let calendar = session.calendar
        var changed: Set<String> = []
        var reached = false
        let count = max(1, min(days, 3))
        for day in 0..<count {
            // A day is its records (most of the wait, reported packet by packet), then its sleep.
            let name = ["Today", "Yesterday"].indices.contains(day) ? ["Today", "Yesterday"][day] : "\(day) days ago"
            stage = "Activity · \(name)"
            let records = try? await session.readDaily(day: day) { [weak self] done in
                self?.advance(to: (Double(day) + 0.85 * done) / Double(count))
            }
            advance(to: (Double(day) + 0.85) / Double(count))
            stage = "Sleep · \(name)"
            let sleep = try? await session.readSleep(day: day)
            advance(to: Double(day + 1) / Double(count))
            if records != nil || sleep != nil { reached = true }
            guard !(records ?? []).isEmpty || !(sleep ?? []).isEmpty else { continue }
            let date = calendar.date(byAdding: .day, value: -day, to: session.now()) ?? session.now()
            let key = RingDates.dayKey(date)
            store.update(key) { existing in
                existing = BandDayMapper.day(existing, records: records ?? [], sleep: sleep ?? [], date: date, calendar: calendar)
                existing.syncedAt = Date()
            }
            changed.insert(key)
        }
        lastReached = reached
        // A sync that reached nothing doesn't count: the next connect tries again.
        if reached {
            lastSync = Date()
            defaults.set(lastSync, forKey: Self.lastSyncKey)
        }
        if !changed.isEmpty { onDaysChanged?(changed) }
        return changed
    }

    /// Progress only moves forward: a read's packets can arrive out of step with its total.
    private func advance(to done: Double) {
        guard let current = progress else { return }
        progress = max(current, min(1, done))
    }
}

/// Changed days, uploaded at most every `every` — or at once while someone is looking (`urgent`).
/// Each finished reading used to send the band's whole day (~38 KB) straight away: about twelve
/// uploads an hour on his schedule, all day in the background. The server's hourly run reads the
/// day from the phone itself, so it never waits longer than that.
@MainActor
final class DayUploadThrottle {
    let every: TimeInterval
    private let send: (Set<String>) async -> Bool
    private let now: () -> Date
    private(set) var pending: Set<String> = []
    private(set) var lastSent: Date?
    private var timer: Task<Void, Never>?

    init(every: TimeInterval = 30 * 60, now: @escaping () -> Date = Date.init,
         send: @escaping (Set<String>) async -> Bool) {
        self.every = every
        self.now = now
        self.send = send
    }

    /// When the held days go up (nil: nothing held).
    var due: Date? { pending.isEmpty ? nil : (lastSent.map { $0.addingTimeInterval(every) } ?? now()) }

    func changed(_ keys: Set<String>, urgent: Bool) {
        pending.formUnion(keys)
        guard let due else { return }
        if urgent || due <= now() {
            flush()
            return
        }
        guard timer == nil else { return }
        let wait = max(1, due.timeIntervalSince(now()))
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else { return }
            self.timer = nil
            self.flush()
        }
    }

    /// Sends what is held now. Days that fail to go up are held for the next send.
    @discardableResult
    func flush() -> Task<Void, Never>? {
        timer?.cancel()
        timer = nil
        guard !pending.isEmpty else { return nil }
        let keys = pending
        pending = []
        lastSent = now()
        return Task { [weak self] in
            guard let self, !(await self.send(keys)) else { return }
            self.pending.formUnion(keys)
        }
    }
}

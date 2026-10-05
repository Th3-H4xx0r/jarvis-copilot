import Foundation

/// Reads the band's history — up to three days of daily records and sleep — into the shared
/// `RingDay` store, and reports which days changed (Jarvis Health pushes them).
@MainActor
final class BandSync: ObservableObject {
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSync: Date?
    var onDaysChanged: ((Set<String>) -> Void)?

    private let session: BandSession
    private let store: () -> RingHistoryStore?
    private let defaults: UserDefaults
    static let lastSyncKey = "jc.band.lastSync"
    /// How old a sync may be before connecting starts another.
    static let staleAfter: TimeInterval = 30 * 60

    init(session: BandSession, store: @escaping () -> RingHistoryStore?, defaults: UserDefaults = .standard) {
        self.session = session
        self.store = store
        self.defaults = defaults
        lastSync = defaults.object(forKey: Self.lastSyncKey) as? Date
    }

    var isStale: Bool { lastSync.map { Date().timeIntervalSince($0) > Self.staleAfter } ?? true }

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
        defer { isSyncing = false }
        let calendar = session.calendar
        var changed: Set<String> = []
        var reached = false
        for day in 0..<max(1, min(days, 3)) {
            let records = try? await session.readDaily(day: day)
            let sleep = try? await session.readSleep(day: day)
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
}

/// Sends band days to Jarvis Health after a sync, whichever wearable leads — as `X5HealthPush`
/// does for the X5.
enum BandHealthPush {
    @MainActor
    @discardableResult
    static func push(_ keys: Set<String>, manager: BandManager) async -> Bool {
        guard let deviceID = manager.deviceID, let store = manager.store, !keys.isEmpty else { return false }
        let client = HealthClient(spaceID: HealthSpace.id(forRing: deviceID))
        for key in keys.sorted() {
            let day = store.day(key)
            guard day.syncedAt != nil else { continue }
            do {
                try await client.pushDay(HealthDayPayload.make(day, key: key, deviceID: deviceID,
                                                               source: WearableKeepAlive.band,
                                                               battery: manager.session.battery))
            } catch {
                JcLog.devices.notice("band: could not push \(key, privacy: .public) to the server")
                return false
            }
        }
        return true
    }
}

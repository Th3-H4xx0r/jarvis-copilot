import Foundation

/// The day skills every ring-like wearable answers from its `RingHistoryStore` (R12, X5, band):
/// one day, one day in Jarvis Health's shape, and the recent days. Each device says how it brings
/// a day up to date.
@MainActor
struct WearableDays {
    let store: RingHistoryStore?
    let connected: Bool
    /// What a day reads before the device has ever connected.
    let noData: String
    /// `source` on a Health day: the wearable's kind.
    let source: String
    let battery: RingBattery?
    let lastSync: Date?
    /// Brings day `daysAgo` up to date when the device can, waiting at most `seconds`.
    let freshen: (_ daysAgo: Int, _ seconds: TimeInterval) async -> Void

    static func dayKey(_ args: [String: Any]) throws -> (key: String, daysAgo: Int) {
        let key = (args["date"] as? String)?.trimmingCharacters(in: .whitespaces) ?? RingDates.dayKey(Date())
        guard let daysAgo = RingDates.daysAgo(key: key) else { throw DeviceError.badArgument("'date' must be YYYY-MM-DD") }
        return (key, daysAgo)
    }

    /// Starts `work` and waits at most `seconds`; the work carries on if it takes longer.
    static func bounded(_ seconds: TimeInterval, _ work: @escaping @MainActor () async -> Void) async -> Bool {
        var finished = false
        Task { @MainActor in
            await work()
            finished = true
        }
        let deadline = Date().addingTimeInterval(seconds)
        while !finished, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return finished
    }

    func day(_ args: [String: Any]) async throws -> [String: Any] {
        let (key, daysAgo) = try Self.dayKey(args)
        let metrics = try RingDayJSON.parseMetrics(args["metrics"])
        let detail = args["detail"] as? Bool ?? false
        guard let store else { return ["date": key, "connected": connected, "note": noData] }
        await freshen(daysAgo, 20)
        let value = store.day(key)
        var out: [String: Any] = ["date": key, "connected": connected,
                                  "summary": RingDayJSON.summary(value.summary, metrics: metrics)]
        if let synced = value.syncedAt { out["synced_at"] = RingDayJSON.iso(synced) }
        if detail { out["detail"] = RingDayJSON.detail(value, metrics: metrics) }
        return out
    }

    func healthDay(_ args: [String: Any]) async throws -> [String: Any] {
        let (key, daysAgo) = try Self.dayKey(args)
        guard let store else { throw DeviceError.notConnected }
        await freshen(daysAgo, 25)
        return HealthDayPayload.make(store.day(key), key: key, source: source, battery: battery)
    }

    func history(_ args: [String: Any]) throws -> [String: Any] {
        let days = max(1, min(30, args["days"] as? Int ?? 7))
        let metrics = try RingDayJSON.parseMetrics(args["metrics"])
        guard let store else { return ["days": [Any](), "connected": connected] }
        let rows: [[String: Any]] = store.recentDays(days).map {
            ["date": $0.date, "timezone": TimeZone.current.identifier,
             "summary": RingDayJSON.summary($0.summary, metrics: metrics)]
        }
        var out: [String: Any] = ["days": rows, "connected": connected]
        if let lastSync { out["last_sync"] = RingDayJSON.iso(lastSync) }
        return out
    }
}

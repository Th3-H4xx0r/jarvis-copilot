import Foundation

/// Clips he deleted from the phone, remembered for two weeks so nothing brings them back. A download
/// still running when he deleted a clip landed seconds later and queued an upload of it, which asked
/// the server every 10 minutes for a week (and kept the loop polling all night); a camera pass or a
/// clean-up could list it again too. UserDefaults is thread-safe, so the upload actor reads it as well.
enum DashcamTombstones {
    static let key = "jc.dashcam.tombstones"
    /// Outlives any download or retry; a clip recorded at the same path after that is a new clip anyway.
    static let lifetime: TimeInterval = 14 * 86400
    /// Add is read-modify-write, and the main actor and the uploader both write.
    private static let lock = NSLock()

    static func add(_ id: String, defaults: UserDefaults = .standard, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        var all = live(defaults, now: now)
        all[id] = now.timeIntervalSince1970
        defaults.set(all, forKey: key)
    }

    /// He asked for the clip again ("Download again"): it may come back.
    static func remove(_ id: String, defaults: UserDefaults = .standard, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        var all = live(defaults, now: now)
        guard all.removeValue(forKey: id) != nil else { return }
        defaults.set(all, forKey: key)
    }

    static func contains(_ id: String, defaults: UserDefaults = .standard, now: Date = Date()) -> Bool {
        guard let at = stored(defaults)[id] else { return false }
        return now.timeIntervalSince1970 - at < lifetime
    }

    /// Every live tombstone, for a pass that checks thousands of listed clips.
    static func ids(defaults: UserDefaults = .standard, now: Date = Date()) -> Set<String> {
        Set(live(defaults, now: now).keys)
    }

    private static func stored(_ defaults: UserDefaults) -> [String: Double] {
        (defaults.dictionary(forKey: key) ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }
    }

    /// Without the expired ones (pruned on every write, so the list never grows past two weeks of deletes).
    private static func live(_ defaults: UserDefaults, now: Date) -> [String: Double] {
        stored(defaults).filter { now.timeIntervalSince1970 - $0.value < lifetime }
    }
}

import Foundation

/// Pure helpers for the offline plan embedded in a Dynamic Island design.
enum IslandOffline {
    /// The data of the timeline keyframe in effect at `nowEpochSeconds` — the
    /// entry with the greatest `at` ≤ now.
    ///
    /// Returns `[:]` when the timeline is empty or the earliest keyframe is
    /// still in the future. Keyframes need not be sorted; malformed entries are
    /// skipped.
    static func currentKeyframeData(_ timeline: [JSONObject],
                                    _ nowEpochSeconds: Int) -> JSONObject {
        var best: JSONObject = [:]
        var bestAt = -Double.infinity
        var found = false
        for keyframe in timeline {
            guard let at = epoch(keyframe["at"]) else { continue }
            if at <= Double(nowEpochSeconds) && at >= bestAt {
                bestAt = at
                best = MoreJSON.map(keyframe["data"])
                found = true
            }
        }
        return found ? best : [:]
    }

    /// A stable content signature for the unified scheduled items
    /// `[{at,title,body,action?}]` (jobs + notifications), so the scheduler only
    /// re-schedules when the list actually changes (the coordinator polls every
    /// ~5 s). The `action` is included so a changed tap-action reschedules.
    static func scheduledItemsSignature(_ items: [JSONObject]) -> String {
        // Control-byte separators (SOH / STX): these never appear in titles,
        // bodies or JSON, so fields and rows can't collide whatever they hold.
        let fieldSeparator = "\u{0001}"
        let rowSeparator = "\u{0002}"
        let parts = items.map { item -> String in
            let at = MoreJSON.text(item["at"])
            let title = MoreJSON.text(item["title"])
            let body = MoreJSON.text(item["body"])
            var action = ""
            if let raw = item["action"], !(raw is NSNull) {
                action = (raw as? JSONObject).map(MoreJSON.canonicalJSON) ?? MoreJSON.text(raw)
            }
            return [at, title, body, action].joined(separator: fieldSeparator)
        }.sorted()
        return parts.joined(separator: rowSeparator)
    }

    private static func epoch(_ value: Any?) -> Double? {
        guard let value, !(value is NSNull) else { return nil }
        if value is Bool { return nil }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }
}

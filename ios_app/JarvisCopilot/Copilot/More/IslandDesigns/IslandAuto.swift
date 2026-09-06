import Foundation

/// The chosen active island: a kind plus the entry id (for `custom`, the design
/// id to render).
struct IslandActive: Equatable, Sendable {
    var id: String?
    /// "voice" | "coding" | "custom" | "none"
    var kind: String

    init(_ id: String?, _ kind: String) {
        self.id = id
        self.kind = kind
    }

    static let none = IslandActive(nil, "none")

    var isCustom: Bool { kind == "custom" }
}

enum IslandAuto {
    /// Decide which island shows right now. Pure.
    ///
    /// Precedence:
    ///   1. a live voice turn always wins (it's restored after);
    ///   2. a PINNED entry shows literally;
    ///   3. AUTO picks the highest-priority enabled entry whose conditions +
    ///      schedule match now (voice is excluded — it only shows on an active
    ///      turn; coding's implicit condition is "sessions live");
    ///   4. nothing matches → none (resting/clear).
    static func selectActiveDesign(catalog: IslandCatalog,
                                   voiceActive: Bool,
                                   codingLive: Bool,
                                   sources: IslandBindings.Sources,
                                   now: Date) -> IslandActive {
        if voiceActive { return IslandActive("voice", "voice") }

        let selection = catalog.selection
        if selection.isPinned {
            let id = selection.pinnedID
            if id == "voice" { return IslandActive("voice", "voice") }
            if id == "coding" { return IslandActive("coding", "coding") }
            if let id, catalog.design(id: id) != nil { return IslandActive(id, "custom") }
            // Pinned to a design that no longer exists → fall through to auto.
        }

        var best: IslandCatalogEntry?
        for entry in catalog.entries {
            if entry.isVoice { continue }              // voice only on an active turn
            if !entry.enabled { continue }
            if entry.isCoding && !codingLive { continue }  // coding's implicit condition
            if !IslandBindings.evaluateCondition(entry.conditions, sources) { continue }
            if !scheduleMatches(entry.schedule, now) { continue }
            if best == nil || entry.priority > best!.priority { best = entry }
        }
        guard let best else { return .none }
        return IslandActive(best.id, best.isCoding ? "coding" : "custom")
    }

    /// A schedule `{days:[1-7]?, from:"HH:MM", to:"HH:MM"}`. Days use Dart's
    /// weekday numbering (Mon=1 … Sun=7). Nil/empty = always. A `from > to`
    /// window wraps past midnight, and a partial window (only one bound) leaves
    /// the time check open.
    static func scheduleMatches(_ schedule: JSONObject?, _ now: Date) -> Bool {
        guard let schedule, !schedule.isEmpty else { return true }

        if let days = schedule["days"] as? [Any], !days.isEmpty {
            let allowed = days.compactMap { value -> Int? in
                if let s = value as? String { return Int(s) }
                guard let d = MoreJSON.double(value), d.isFinite else { return nil }
                return Int(d)
            }
            if !allowed.contains(isoWeekday(now)) { return false }
        }

        guard let from = minutes(schedule["from"]),
              let to = minutes(schedule["to"]) else { return true }

        let components = Calendar.current.dateComponents([.hour, .minute], from: now)
        let current = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        if from <= to { return current >= from && current <= to }
        return current >= from || current <= to     // wraps midnight
    }

    /// Mon=1 … Sun=7, matching Dart's `DateTime.weekday` (Foundation uses
    /// Sun=1 … Sat=7, so it has to be remapped).
    static func isoWeekday(_ date: Date) -> Int {
        let weekday = Calendar.current.component(.weekday, from: date)  // 1 = Sunday
        return weekday == 1 ? 7 : weekday - 1
    }

    private static func minutes(_ hhmm: Any?) -> Int? {
        guard let s = hhmm as? String else { return nil }
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return h * 60 + m
    }
}

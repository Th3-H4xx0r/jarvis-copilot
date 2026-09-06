import Foundation

/// A decoded JSON object as the server actually sends it. The "More" endpoints
/// are loose (ints arrive as strings, whole blocks go missing when a subsystem
/// is off), so most of this layer keeps the raw dictionary around and coerces
/// on read — exactly what the Flutter client did.
typealias JSONObject = [String: Any]

// MARK: - Defensive coercions

enum MoreJSON {
    /// `nil` / `NSNull` / anything non-dictionary → `[:]`.
    static func map(_ value: Any?) -> JSONObject { (value as? JSONObject) ?? [:] }

    /// Every dictionary in a JSON array, non-objects dropped.
    static func mapList(_ value: Any?) -> [JSONObject] {
        guard let array = value as? [Any] else { return [] }
        return array.compactMap { $0 as? JSONObject }
    }

    static func list(_ value: Any?) -> [Any] { (value as? [Any]) ?? [] }

    /// Dart's `'${v ?? ''}'`: nil/null → "", otherwise string interpolation.
    static func text(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return numberText(n) }
        if let b = value as? Bool { return b ? "true" : "false" }
        return "\(value)"
    }

    /// Trimmed text, or nil when there is nothing usable.
    static func nonEmpty(_ value: Any?) -> String? {
        let s = text(value).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    /// `num`, numeric string (tolerating `$` and thousands separators), else nil.
    static func double(_ value: Any?) -> Double? {
        guard let value, !(value is NSNull) else { return nil }
        if let b = value as? Bool { return b ? 1 : 0 }
        if let n = value as? NSNumber { return n.doubleValue }
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String {
            let cleaned = s.replacingOccurrences(of: "$", with: "")
                .replacingOccurrences(of: ",", with: "")
                .trimmingCharacters(in: .whitespaces)
            return Double(cleaned)
        }
        return nil
    }

    /// Coerce to `Int`, truncating toward zero like Dart's `num.toInt()`.
    static func int(_ value: Any?, or fallback: Int = 0) -> Int {
        guard let d = double(value) else { return fallback }
        guard d.isFinite else { return fallback }
        return Int(d)
    }

    /// True only for a real `true`; every other value (including absent) is false.
    static func isTrue(_ value: Any?) -> Bool { (value as? Bool) == true }

    /// True only for a real `false` — used for the server's `available != false`
    /// fail-soft convention, where *missing* must not read as unavailable.
    static func isFalse(_ value: Any?) -> Bool { (value as? Bool) == false }

    /// `[String]` from a JSON array of anything, stringified, blanks dropped.
    static func stringList(_ value: Any?) -> [String] {
        list(value).map { text($0) }.filter { !$0.isEmpty }
    }

    /// Pull a list out of a response envelope: the first present key, else the
    /// `data` key `APIResponse.object()` synthesises when the body was a bare
    /// JSON array (the Flutter client tolerated both shapes everywhere).
    static func envelopeList(_ body: JSONObject, _ keys: String...) -> Any? {
        for key in keys {
            if let value = body[key], !(value is NSNull) { return value }
        }
        return body["data"]
    }

    /// Canonical (sorted-key) JSON for a dictionary — deterministic across runs,
    /// so content signatures survive app restarts.
    static func canonicalJSON(_ object: JSONObject) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    /// FNV-1a over UTF-8. Deterministic (unlike `String.hashValue`, which is
    /// seeded per process) so a cached signature is still valid after a relaunch.
    static func stableHash(_ s: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return Int(bitPattern: UInt(truncatingIfNeeded: hash))
    }

    private static func numberText(_ n: NSNumber) -> String {
        // Integral doubles must print like Dart ("3" for 3, "0.9" for 0.9).
        if CFNumberIsFloatType(n) {
            let d = n.doubleValue
            if d == d.rounded() && abs(d) < 1e15 { return String(Int(d)) }
            return "\(d)"
        }
        return n.stringValue
    }
}

// MARK: - Semantic colour tokens

/// A palette slot, not a colour. This layer must not import SwiftUI or depend on
/// `JcTheme` (wave-2 owns that), so anything the Flutter code expressed as a
/// `JcTheme.*` constant is expressed here as the token name and mapped to a real
/// colour in the view.
enum MoreTone: String, Equatable, Sendable, CaseIterable {
    case text, muted, accent, accentAlt, cyan, blue, primaryBlue
    case success, amber, slate, danger
}

// MARK: - Timestamps

/// Timestamp parsing + relative formatting shared by the More screens. Accepts
/// epoch seconds, epoch milliseconds, numeric strings and ISO-8601 (with or
/// without a timezone; without one it is read as local time, like Dart).
enum RelativeTime {
    static func parse(_ ts: Any?) -> Date? {
        guard let ts, !(ts is NSNull) else { return nil }
        if let date = ts as? Date { return date }
        if let n = numeric(ts) { return fromEpoch(n) }
        let s = MoreJSON.text(ts).trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return nil }
        if let n = Double(s) { return fromEpoch(n) }
        return parseISOString(s)
    }

    /// "just now" / "5m ago" / "2h ago" / "3d ago", or `YYYY-MM-DD` past a week.
    /// Empty string for anything unparseable. Future timestamps (clock skew)
    /// read as "just now".
    static func format(_ ts: Any?, now: Date = Date()) -> String {
        guard let date = parse(ts) else { return "" }
        let secs = Int(now.timeIntervalSince(date))
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        if secs < 86400 { return "\(secs / 3600)h ago" }
        if secs < 604_800 { return "\(secs / 86400)d ago" }
        return isoDate(date)
    }

    /// Local `YYYY-MM-DD`, locale-independent.
    static func isoDate(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// `Jun 21, 2026, 3:07 PM` in local time, locale-independent (the Flutter
    /// client hand-rolled this so the string never shifts with the device locale).
    static func absolute(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let month = months[max(0, min(11, (c.month ?? 1) - 1))]
        let hour24 = c.hour ?? 0
        let hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12
        let ampm = hour24 < 12 ? "AM" : "PM"
        return String(format: "%@ %d, %d, %d:%02d %@",
                      month, c.day ?? 0, c.year ?? 0, hour12, c.minute ?? 0, ampm)
    }

    static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                         "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    private static func numeric(_ v: Any) -> Double? {
        if v is String || v is Bool { return nil }
        if let n = v as? NSNumber { return n.doubleValue }
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        return nil
    }

    /// >= 1e12 is already milliseconds; anything smaller is seconds.
    private static func fromEpoch(_ n: Double) -> Date {
        let seconds = n >= 1e12 ? n / 1000 : n
        return Date(timeIntervalSince1970: seconds)
    }

    /// ISO-8601 only (no epoch fallback) — some callers must try ISO first so a
    /// bare number keeps its epoch meaning.
    static func parseISOString(_ s: String) -> Date? {
        for formatter in isoFormatters {
            if let d = formatter.date(from: s) { return d }
        }
        for format in localFormats {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    private static let isoFormatters: [ISO8601DateFormatter] = {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return [plain, withFraction]
    }()

    private static let localFormats = [
        "yyyy-MM-dd'T'HH:mm:ss.SSS",
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd'T'HH:mm",
        "yyyy-MM-dd",
    ]
}

// MARK: - Cancellable task slot

/// A cancellable slot for one in-flight `Task`.
///
/// `@MainActor` stores need to cancel their work from `deinit`, which is
/// *nonisolated* — so the task can't live in a plain `var`. An immutable
/// `Sendable let` is reachable from any context, hence this tiny box.
/// Replacing the task cancels whatever it displaced.
final class TaskHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    /// Bumped on every `replace`, so a finishing task only clears the slot when
    /// it is still the one the slot holds.
    private var generation = 0

    /// Install a new task, cancelling the one it replaces.
    func replace(_ new: Task<Void, Never>?) {
        lock.lock()
        generation += 1
        let id = generation
        let previous = task
        task = new
        lock.unlock()
        previous?.cancel()
        guard let new else { return }
        // Clear the slot when the task ends on its OWN (a stream that closed, a
        // loop that returned) rather than only when something replaces it.
        // Without this `isActive` stays true forever after a poller's loop
        // exits, and every `guard !handle.isActive else { return }` re-arm —
        // `ChatStore.setListPolling`, `CronsStore.syncPoll`,
        // `ServerLogsStore.syncTimer` — wedges permanently.
        Task { [weak self] in
            await new.value
            self?.clear(generation: id)
        }
    }

    /// Drop the task this generation installed, if it is still the current one.
    private func clear(generation id: Int) {
        lock.lock()
        if id == generation { task = nil }
        lock.unlock()
    }

    func cancel() { replace(nil) }

    var current: Task<Void, Never>? {
        lock.lock(); defer { lock.unlock() }
        return task
    }

    var isActive: Bool { current != nil }

    /// Await the in-flight task, if any (tests, and scene-phase handoffs).
    func wait() async { await current?.value }
}

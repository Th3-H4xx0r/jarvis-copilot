import Foundation

/// Value coercions shared by every Coding model, mirroring
/// `coding_models.dart`'s `_str/_asInt/_asDouble/_asBool`.
///
/// The payloads come out of SQLite, so booleans arrive as `0/1`, numbers arrive
/// as strings, and absent keys mean "use the default". The Dart parser's exact
/// tolerances are load-bearing, so they're reproduced here and exercised
/// directly by `CodingModelsTests`.
enum CodingJSON {

    /// Dart's `_str`: nil for absent/null **and for the empty string**.
    static func str(_ v: Any?) -> String? {
        guard let v, !(v is NSNull) else { return nil }
        let s = stringify(v)
        return s.isEmpty ? nil : s
    }

    /// Dart's `(j[k] ?? fallback).toString()` — only null/absent falls back, an
    /// explicit empty string stays empty.
    static func text(_ v: Any?, _ fallback: String = "") -> String {
        guard let v, !(v is NSNull) else { return fallback }
        return stringify(v)
    }

    static func double(_ v: Any?) -> Double? {
        guard let v, !(v is NSNull) else { return nil }
        if isBoolean(v) { return nil } // Dart: `bool is! num`, then tryParse fails
        if let n = v as? NSNumber { return n.doubleValue }
        return Double(stringify(v))
    }

    /// Dart's `_asInt`: truncates a double, parses an integral string, else 0.
    static func int(_ v: Any?) -> Int {
        guard let v, !(v is NSNull), !isBoolean(v) else { return 0 }
        if let n = v as? NSNumber { return Int(n.doubleValue) }
        return Int(stringify(v)) ?? 0
    }

    /// The Live Activity coordinator's `_asInt(v, dflt)` — note it *rounds*
    /// fractional numbers (percentages) instead of truncating.
    static func int(_ v: Any?, or fallback: Int) -> Int {
        guard let v, !(v is NSNull), !isBoolean(v) else { return fallback }
        if let n = v as? NSNumber { return Int(n.doubleValue.rounded()) }
        return Int(stringify(v)) ?? fallback
    }

    /// Dart's `_asBool`: real bools pass through, numbers are `!= 0`, and the
    /// strings `true`/`1`/`yes` count (SQLite hands us all three shapes).
    static func bool(_ v: Any?) -> Bool {
        guard let v, !(v is NSNull) else { return false }
        if isBoolean(v) { return (v as? NSNumber)?.boolValue ?? false }
        if let n = v as? NSNumber { return n.doubleValue != 0 }
        return ["true", "1", "yes"].contains(stringify(v).lowercased())
    }

    /// `_asBool` with a default for the "absent means true" fields
    /// (`attached`, `online`).
    static func bool(_ v: Any?, or fallback: Bool) -> Bool {
        (v == nil || v is NSNull) ? fallback : bool(v)
    }

    static func dict(_ v: Any?) -> [String: Any]? { v as? [String: Any] }

    /// Dart's `(x as List?)?.whereType<Map>()` — non-object entries are dropped.
    static func maps(_ v: Any?) -> [[String: Any]] {
        (v as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }

    /// Dart's `(x as List).map((e) => e.toString())`.
    static func strings(_ v: Any?) -> [String] {
        (v as? [Any])?.map { stringify($0) } ?? []
    }

    /// `DateTime.tryParse` for the handful of shapes the server emits.
    static func date(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss.SSS",
                       "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss.SSSSSS",
                       "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    // MARK: internals

    /// `Object.toString()` for the JSON scalars, keeping Dart's int/double/bool
    /// spellings ("1" vs "1.0" vs "true") since some of these strings are
    /// re-parsed as numbers downstream.
    static func stringify(_ v: Any) -> String {
        if let s = v as? String { return s }
        if isBoolean(v) { return ((v as? NSNumber)?.boolValue ?? false) ? "true" : "false" }
        if let n = v as? NSNumber {
            let type = String(cString: n.objCType)
            if type == "d" || type == "f" {
                let d = n.doubleValue
                return d == d.rounded() && abs(d) < 1e15 ? "\(Int64(d)).0" : "\(d)"
            }
            return "\(n.int64Value)"
        }
        return "\(v)"
    }

    /// `NSNumber(1) as? Bool` succeeds, so the only reliable boolean test on a
    /// JSONSerialization value is the CoreFoundation type id.
    static func isBoolean(_ v: Any) -> Bool {
        guard let n = v as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    /// `path.split('/').last`, tolerating trailing slashes and an empty result.
    static func basename(_ path: String) -> String {
        let trimmed = path.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard !trimmed.isEmpty else { return "" }
        return String(trimmed.split(separator: "/").last ?? "")
    }
}

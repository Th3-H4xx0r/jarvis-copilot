import Foundation

/// Small regex + argument-coercion helpers shared by the ported phone-skills
/// logic.
///
/// The Flutter original leans on Dart's `RegExp` and `Object.toString()`
/// everywhere; keeping equivalents in one place is what lets the grammar files
/// stay a line-for-line port instead of being rewritten around
/// `NSRegularExpression`'s range API.

/// One regex match, groups flattened to optional strings (index 0 = the whole
/// match) so call sites read like Dart's `match.group(n)`.
struct RxMatch {
    let groups: [String?]
    func group(_ index: Int) -> String? {
        index >= 0 && index < groups.count ? groups[index] : nil
    }
}

struct Rx {
    /// Nil when the pattern didn't compile. A grammar file with one bad literal
    /// must not take the whole app down mid-invoke — `try!` here crashed the
    /// process for what is only ever a dead rule — so an unusable pattern
    /// degrades to "matches nothing" and is logged once, at construction.
    private let regex: NSRegularExpression?

    /// True when the pattern compiled. Tests assert on this; production code
    /// treats an invalid pattern as a rule that simply never fires.
    var isValid: Bool { regex != nil }

    init(_ pattern: String, caseInsensitive: Bool = true) {
        var options: NSRegularExpression.Options = []
        if caseInsensitive { options.insert(.caseInsensitive) }
        if let compiled = try? NSRegularExpression(pattern: pattern, options: options) {
            regex = compiled
        } else {
            regex = nil
            JcLog.skills.error("invalid regex literal, rule disabled: \(pattern, privacy: .public)")
        }
    }

    func hasMatch(_ text: String) -> Bool {
        guard let regex else { return false }
        return regex.firstMatch(in: text, options: [], range: Self.range(text)) != nil
    }

    func firstMatch(_ text: String) -> RxMatch? {
        guard let regex,
              let m = regex.firstMatch(in: text, options: [], range: Self.range(text)) else { return nil }
        return Self.match(m, in: text)
    }

    func allMatches(_ text: String) -> [RxMatch] {
        guard let regex else { return [] }
        return regex.matches(in: text, options: [], range: Self.range(text))
            .map { Self.match($0, in: text) }
    }

    /// Dart's `String.replaceFirst(RegExp, replacement)`.
    func replacingFirst(in text: String, with replacement: String = "") -> String {
        guard let regex,
              let m = regex.firstMatch(in: text, options: [], range: Self.range(text)),
              let r = Range(m.range, in: text) else { return text }
        return text.replacingCharacters(in: r, with: replacement)
    }

    private static func range(_ text: String) -> NSRange {
        NSRange(text.startIndex..<text.endIndex, in: text)
    }

    private static func match(_ result: NSTextCheckingResult, in text: String) -> RxMatch {
        var groups: [String?] = []
        for i in 0..<result.numberOfRanges {
            let r = result.range(at: i)
            if r.location == NSNotFound {
                groups.append(nil)                       // group didn't participate
            } else if let swiftRange = Range(r, in: text) {
                groups.append(String(text[swiftRange]))
            } else {
                groups.append(nil)
            }
        }
        return RxMatch(groups: groups)
    }
}

/// Coercions for the loosely-typed `[String: Any]` argument maps that arrive
/// over the bridge. Mirrors what the Dart side gets for free.
enum SkillArgs {
    /// Dart's `(value ?? '').toString()`: a JSON `null`/absent value is "",
    /// numbers print without a spurious `.0`, booleans as `true`/`false`.
    static func text(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        if let s = value as? String { return s }
        // A Swift `Bool` must not fall through to NSNumber (which prints 1/0).
        if type(of: value) == Bool.self, let b = value as? Bool { return b ? "true" : "false" }
        if let n = value as? NSNumber {
            if CFGetTypeID(n as CFTypeRef) == CFBooleanGetTypeID() {
                return n.boolValue ? "true" : "false"
            }
            return n.stringValue
        }
        return String(describing: value)
    }

    static func string(_ args: [String: Any], _ key: String) -> String {
        text(args[key])
    }

    /// Dart's `args[key] is num` — deliberately rejects strings and booleans so
    /// a skill never silently accepts `"5"` where a number is required.
    static func number(_ args: [String: Any], _ key: String) -> Double? {
        guard let value = args[key] else { return nil }
        if type(of: value) == Bool.self { return nil }
        guard let n = value as? NSNumber,
              CFGetTypeID(n as CFTypeRef) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }

    static func int(_ args: [String: Any], _ key: String) -> Int? {
        number(args, key).map { Int($0) }
    }

    static func bool(_ args: [String: Any], _ key: String) -> Bool? {
        guard let value = args[key] else { return nil }
        if type(of: value) == Bool.self { return value as? Bool }
        if let n = value as? NSNumber, CFGetTypeID(n as CFTypeRef) == CFBooleanGetTypeID() {
            return n.boolValue
        }
        return nil
    }

    static func intList(_ args: [String: Any], _ key: String) -> [Int]? {
        guard let raw = args[key] as? [Any], !raw.isEmpty else { return nil }
        return raw.map { element in
            guard let n = element as? NSNumber,
                  CFGetTypeID(n as CFTypeRef) != CFBooleanGetTypeID() else { return 0 }
            return n.intValue
        }
    }

    /// Title-case each whitespace-separated word, leaving the rest of the
    /// spelling alone ("wells fargo" → "Wells Fargo").
    static func titleCase(_ s: String) -> String {
        s.split(separator: " ", omittingEmptySubsequences: true)
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

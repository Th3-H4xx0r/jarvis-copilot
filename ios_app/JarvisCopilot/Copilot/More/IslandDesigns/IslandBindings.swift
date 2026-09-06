import Foundation

/// Binding resolution + condition evaluation for Dynamic Island designs.
///
/// The widget reads element values out of the pushed `data` map (both `{"$":k}`
/// and `{"src":k}` look up `data[k]`). This file is the AWAKE-path upstream
/// resolver: it merges server-resolved values with whatever live sources the
/// client knows, and evaluates auto-rule conditions against that same source
/// map. Pure and side-effect free.
enum IslandBindings {
    /// The client's live source values, keyed by the same strings a design binds
    /// to (`battery.level`, `coding.fleet`, …).
    typealias Sources = JSONObject

    /// Build the `data` map to push for `design`: server values overlaid with any
    /// client-known source values the design actually references. Unknown
    /// sources are simply absent → the widget renders nothing for them.
    static func resolveData(_ design: IslandDesign,
                            sources: Sources,
                            serverData: JSONObject) -> JSONObject {
        var out = serverData
        for key in collectSourceKeys(design.raw) where sources.keys.contains(key) {
            out[key] = sources[key]
        }
        return out
    }

    /// Every `{"src": k}` key referenced anywhere in a design tree.
    static func collectSourceKeys(_ node: Any?) -> Set<String> {
        var keys: Set<String> = []
        collect(node, into: &keys)
        return keys
    }

    private static func collect(_ node: Any?, into keys: inout Set<String>) {
        if let object = node as? JSONObject {
            if let src = object["src"] as? String, !src.isEmpty { keys.insert(src) }
            for value in object.values { collect(value, into: &keys) }
        } else if let list = node as? [Any] {
            for value in list { collect(value, into: &keys) }
        }
    }

    /// Evaluate a condition expression against `sources`.
    ///
    /// A nil/empty expression is `true` (no condition = always). Unknown ops and
    /// missing operands are `false` — fail safe, so a design never spuriously
    /// activates.
    static func evaluateCondition(_ expr: JSONObject?, _ sources: Sources) -> Bool {
        guard let expr, !expr.isEmpty else { return true }
        switch MoreJSON.text(expr["op"]) {
        case "and":
            return items(expr).allSatisfy { evaluateCondition($0, sources) }
        case "or":
            return items(expr).contains { evaluateCondition($0, sources) }
        case "not":
            return !evaluateCondition(expr["item"] as? JSONObject, sources)
        case "exists":
            return operand(expr["a"], sources) != nil
        case "eq":
            return equals(operand(expr["a"], sources), operand(expr["b"], sources))
        case "ne":
            return !equals(operand(expr["a"], sources), operand(expr["b"], sources))
        case "gt":
            return compare(operand(expr["a"], sources), operand(expr["b"], sources)) == 1
        case "lt":
            return compare(operand(expr["a"], sources), operand(expr["b"], sources)) == -1
        case "between":
            guard let v = number(operand(expr["a"], sources)),
                  let lo = number(expr["lo"]), let hi = number(expr["hi"]) else { return false }
            return v >= lo && v <= hi
        default:
            return false
        }
    }

    private static func items(_ expr: JSONObject) -> [JSONObject] {
        MoreJSON.mapList(expr["items"])
    }

    /// Resolve an operand: a binding (`{"$":k}` / `{"src":k}`) reads from
    /// sources; anything else is a literal.
    private static func operand(_ value: Any?, _ sources: Sources) -> Any? {
        if let object = value as? JSONObject {
            guard let key = (object["$"] ?? object["src"]) as? String else { return nil }
            guard let resolved = sources[key], !(resolved is NSNull) else { return nil }
            return resolved
        }
        if value is NSNull { return nil }
        return value
    }

    private static func equals(_ a: Any?, _ b: Any?) -> Bool {
        if a == nil || b == nil { return a == nil && b == nil }
        if let na = number(a), let nb = number(b) { return na == nb }
        return MoreJSON.text(a) == MoreJSON.text(b)
    }

    /// -1 / 0 / 1, or nil when either side isn't numeric.
    private static func compare(_ a: Any?, _ b: Any?) -> Int? {
        guard let na = number(a), let nb = number(b) else { return nil }
        if na < nb { return -1 }
        if na > nb { return 1 }
        return 0
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value, !(value is NSNull) else { return nil }
        if let b = value as? Bool { return b ? 1 : 0 }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }
}

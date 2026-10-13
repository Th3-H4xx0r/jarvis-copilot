import Foundation

/// A decoded JSON value and the little bit of formatting the chat UI does with it.
/// Split out of ``ChatModels`` because it is about JSON, not about chat.

/// A decoded JSON value. Tool arguments arrive as arbitrary JSON, and the UI both
/// renders them (pretty-printed in the expanded tool card) and diffs them — which
/// `[String: Any]` can do neither of.
enum JSONValue: Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    /// Wrap anything `JSONSerialization` can hand back.
    init(_ any: Any?) {
        switch any {
        case nil, is NSNull:
            self = .null
        case let v as JSONValue:
            self = v
        case let s as String:
            self = .string(s)
        case let n as NSNumber:
            // A JSON `true` bridges to NSNumber as well, and `n as? Bool` would
            // happily turn the number 1 into `true` — only the CoreFoundation
            // type tells them apart.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) } else { self = .number(n.doubleValue) }
        case let a as [Any]:
            self = .array(a.map(JSONValue.init))
        case let d as [String: Any]:
            self = .object(d.mapValues(JSONValue.init))
        default:
            self = .string("\(any!)")
        }
    }

    var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }

    /// Back to Foundation, for re-encoding a body.
    var anyValue: Any {
        switch self {
        case .string(let s): return s
        case .bool(let b): return b
        case .number(let d):
            // Keep integers integral so they re-encode as `20`, not `20.0`.
            if d == d.rounded(), abs(d) < 1e15 { return Int(d) }
            return d
        case .array(let a): return a.map(\.anyValue)
        case .object(let o): return o.mapValues(\.anyValue)
        case .null: return NSNull()
        }
    }

    /// One-line human form; containers fall back to compact JSON.
    var displayText: String {
        switch self {
        case .string(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .number: return "\(anyValue)"
        case .array, .object:
            guard let data = try? JSONSerialization.data(withJSONObject: anyValue, options: [.sortedKeys]) else { return "…" }
            return String(decoding: data, as: UTF8.self)
        }
    }
}

/// Codable, so a model can carry keys it doesn't know (a newer server's) through
/// a decode and re-encode untouched (``HarnessNode``).
extension JSONValue: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        // Bool before Double: a JSON `true` must not come back as the number 1.
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let d = try? c.decode(Double.self) { self = .number(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .bool(let b): try c.encode(b)
        case .number(let d):
            if d == d.rounded(), abs(d) < 1e15 { try c.encode(Int(d)) } else { try c.encode(d) }
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        case .null: try c.encodeNil()
        }
    }
}

// Literal conformances so argument dictionaries read naturally in code and tests.
extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
                     ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(floatLiteral value: Double) { self = .number(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension Dictionary where Key == String, Value == JSONValue {
    var anyDictionary: [String: Any] { mapValues(\.anyValue) }

    /// Indented JSON for the expanded tool card.
    var prettyJSON: String {
        guard !isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: anyDictionary,
                                                     options: [.prettyPrinted, .sortedKeys])
        else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// One short line out of the arguments, for a tool row the server gave no
    /// preview for: the first three keys, values clipped.
    var previewLine: String {
        guard !isEmpty else { return "" }
        return keys.sorted().prefix(3).map { key in
            var text = self[key]?.displayText ?? ""
            if text.count > 40 { text = text.prefix(39) + "…" }
            return "\(key): \(text)"
        }.joined(separator: " · ")
    }
}

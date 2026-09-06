import Foundation
import SwiftUI
import CryptoKit
import UIKit


// ══════════════════════════════════════════════════════════════════════════
// MARK: - Dynamic Island Designs — data-driven renderer (JCDesignView)
// ══════════════════════════════════════════════════════════════════════════
//
// When ContentState.mode == "custom", the activity renders a declarative layout
// tree instead of the hard-coded voice/coding views. The tree is NOT in the
// ContentState (4KB cap) — it's cached on-device by the Runner app under the
// shared App Group `island/design-<id>.json` and read here (a SEPARATE process).
// The ContentState carries only {designId, designVersion, data}; `data` is a
// JSON object string of the live values bound into the tree via ValueRefs.
//
// Animation inside a Live Activity is limited to Text(timerInterval:),
// ProgressView, content-update transitions, and SF-Symbol .symbolEffect (iOS 17+
// only) — everything else is static between pushes. The renderer never crashes
// and never goes blank: a missing/corrupt design falls back to the app name +
// data.title; unknown node types are skipped; recursion/count are clamped.

// ── App Group container access ───────────────────────────────────────────────
enum JCDesignCache {
    /// MUST match Runner.entitlements + JarvisWidget.entitlements +
    /// `JarvisShared.appGroupID`, which both targets compile.
    static let appGroupId = JarvisShared.appGroupID

    /// The highest `schema` this renderer understands. A design written by a
    /// newer server is REFUSED rather than half-rendered: every decoder below is
    /// deliberately lenient (unknown keys are dropped, bad types fall back), so a
    /// schema 2 tree would silently render as a mangled schema 1 one — worse
    /// than falling back to the built-in island view.
    static let supportedSchema = 1

    /// Read + decode `island/design-<id>.json`. Returns nil if missing, corrupt,
    /// or written to a schema this build cannot render.
    static func load(_ designId: String) -> JCDesign? {
        guard !designId.isEmpty,
              let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroupId) else { return nil }
        // `JarvisShared` is compiled into both targets, so the writer and this
        // reader can never disagree about the filename.
        let file = container
            .appendingPathComponent("island", isDirectory: true)
            .appendingPathComponent(JarvisShared.designFileName(designId))
        guard let data = try? Data(contentsOf: file),
              let design = try? JSONDecoder().decode(JCDesign.self, from: data),
              design.schema <= supportedSchema else { return nil }
        return design
    }
}

// ── App Group image cache (read-only in the widget) ──────────────────────────
// Remote island images are downloaded by the app into
// `<AppGroupContainer>/island/images/<sha256(url)>` by
// `IslandImageCache` in the app). The widget extension cannot fetch at render
// time, so it only ever READS the pre-downloaded file; the hash MUST match.
enum JCImageCache {
    static let appGroupId = JCDesignCache.appGroupId

    static func fileName(for url: String) -> String {
        SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The cached file for a remote image URL, or nil if not (yet) downloaded.
    static func localFile(for source: String) -> URL? {
        guard source.hasPrefix("http"),
              let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroupId) else { return nil }
        let file = container
            .appendingPathComponent("island/images", isDirectory: true)
            .appendingPathComponent(fileName(for: source))
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }
}

// ── Decodable layout model ───────────────────────────────────────────────────

/// Top-level cached design object.
struct JCDesign: Decodable {
    var schema: Int = 1
    var id: String = ""
    var version: Int = 0
    var name: String = ""
    var icon: String = ""
    var tint: String = ""
    var presentations: JCPresentations = JCPresentations()

    enum CodingKeys: String, CodingKey {
        case schema, id, version, name, icon, tint, presentations
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = (try? c.decode(Int.self, forKey: .schema)) ?? 1
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        version = (try? c.decode(Int.self, forKey: .version)) ?? 0
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        icon = (try? c.decode(String.self, forKey: .icon)) ?? ""
        tint = (try? c.decode(String.self, forKey: .tint)) ?? ""
        presentations = (try? c.decode(JCPresentations.self, forKey: .presentations))
            ?? JCPresentations()
    }
    init() {}
}

struct JCPresentations: Decodable {
    var expanded: JCNode?
    var lockScreen: JCNode?
    var compactLeading: JCNode?
    var compactTrailing: JCNode?
    var minimal: JCNode?

    enum CodingKeys: String, CodingKey {
        case expanded, lockScreen, compactLeading, compactTrailing, minimal
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        expanded = try? c.decode(JCNode.self, forKey: .expanded)
        lockScreen = try? c.decode(JCNode.self, forKey: .lockScreen)
        compactLeading = try? c.decode(JCNode.self, forKey: .compactLeading)
        compactTrailing = try? c.decode(JCNode.self, forKey: .compactTrailing)
        minimal = try? c.decode(JCNode.self, forKey: .minimal)
    }
    init() {}
}

/// A node in the layout tree: `{type, ...props, style?, when?}`. The `type` is a
/// dynamic string (forward-compat: unknown types render as a placeholder/omit),
/// so props are decoded leniently into a loosely-typed bag.
struct JCNode: Decodable {
    var type: String = ""
    var style: JCStyle?
    var when: JCJSON?          // condition; nil = always shown
    var props: [String: JCJSON] = [:]

    /// Convenience prop accessors (all optional / tolerant of missing keys).
    func ref(_ key: String) -> JCValueRef? { props[key].map(JCValueRef.init) }
    func node(_ key: String) -> JCNode? { props[key]?.asNode() }
    func nodes(_ key: String) -> [JCNode] { props[key]?.asNodeArray() ?? [] }
    func string(_ key: String) -> String? { props[key]?.asString }
    func int(_ key: String) -> Int? { props[key]?.asInt }
    func double(_ key: String) -> Double? { props[key]?.asDouble }
    func bool(_ key: String) -> Bool? { props[key]?.asBool }

    private struct DynKey: CodingKey {
        var stringValue: String; var intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: DynKey.self) else {
            return  // not an object → empty placeholder node
        }
        for key in c.allKeys {
            switch key.stringValue {
            case "type":
                type = (try? c.decode(String.self, forKey: key)) ?? ""
            case "style":
                style = try? c.decode(JCStyle.self, forKey: key)
            case "when":
                when = try? c.decode(JCJSON.self, forKey: key)
            default:
                if let v = try? c.decode(JCJSON.self, forKey: key) {
                    props[key.stringValue] = v
                }
            }
        }
    }
    init(type: String) { self.type = type }
}

/// Per-node visual overrides — all optional.
struct JCStyle: Decodable {
    var color: String?
    var font: String?
    var size: Double?
    var weight: String?
    var opacity: Double?
    var padding: Double?
    var align: String?
    var tint: String?
    var width: Double?
    var height: Double?
    var minHeight: Double?  // force a container to fill toward the ~144pt cap

    enum CodingKeys: String, CodingKey {
        case color, font, size, weight, opacity, padding, align, tint, width,
             height, minHeight
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        color = try? c.decode(String.self, forKey: .color)
        font = try? c.decode(String.self, forKey: .font)
        size = try? c.decode(Double.self, forKey: .size)
        weight = try? c.decode(String.self, forKey: .weight)
        opacity = try? c.decode(Double.self, forKey: .opacity)
        padding = try? c.decode(Double.self, forKey: .padding)
        align = try? c.decode(String.self, forKey: .align)
        tint = try? c.decode(String.self, forKey: .tint)
        width = try? c.decode(Double.self, forKey: .width)
        height = try? c.decode(Double.self, forKey: .height)
        minHeight = try? c.decode(Double.self, forKey: .minHeight)
    }
}

/// A tolerant JSON value (used for props, ValueRefs, conditions, list rows).
indirect enum JCJSON: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JCJSON])
    case object([String: JCJSON])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JCJSON].self) { self = .array(a); return }
        if let o = try? c.decode([String: JCJSON].self) { self = .object(o); return }
        self = .null
    }

    var asString: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return JCJSON.numberString(n)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }
    var asDouble: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }
    var asInt: Int? { asDouble.map { Int($0) } }
    var asBool: Bool? {
        switch self {
        case .bool(let b): return b
        case .number(let n): return n != 0
        case .string(let s): return s == "true" || s == "1"
        default: return nil
        }
    }
    var asObject: [String: JCJSON]? { if case .object(let o) = self { return o }; return nil }
    var asArray: [JCJSON]? { if case .array(let a) = self { return a }; return nil }

    func asNode() -> JCNode? {
        guard let o = asObject else { return nil }
        return JCJSON.decodeNode(from: o)
    }
    func asNodeArray() -> [JCNode]? {
        guard let a = asArray else { return nil }
        return a.compactMap { $0.asNode() }
    }

    /// Re-encode an object value back into a JCNode (props were captured as JCJSON
    /// so nested child nodes need re-materializing through the JCNode decoder).
    static func decodeNode(from obj: [String: JCJSON]) -> JCNode? {
        guard let data = try? JSONEncoder().encode(JCJSONBox(obj)) else { return nil }
        return try? JSONDecoder().decode(JCNode.self, from: data)
    }

    static func numberString(_ n: Double) -> String {
        if n == n.rounded() && abs(n) < 1e15 { return String(Int(n)) }
        return String(n)
    }
}

/// Encodable wrapper so a captured JCJSON object can be re-serialized (to feed
/// the JCNode decoder for nested children). Only the object case is needed.
struct JCJSONBox: Encodable {
    let obj: [String: JCJSON]
    init(_ obj: [String: JCJSON]) { self.obj = obj }
    struct DynKey: CodingKey {
        var stringValue: String; var intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynKey.self)
        for (k, v) in obj {
            try JCJSON.encodeValue(v, into: &c, key: DynKey(stringValue: k)!)
        }
    }
}

extension JCJSON {
    fileprivate static func encodeValue(
        _ v: JCJSON, into c: inout KeyedEncodingContainer<JCJSONBox.DynKey>,
        key: JCJSONBox.DynKey
    ) throws {
        switch v {
        case .string(let s): try c.encode(s, forKey: key)
        case .number(let n): try c.encode(n, forKey: key)
        case .bool(let b): try c.encode(b, forKey: key)
        case .null: try c.encodeNil(forKey: key)
        case .array(let a): try c.encode(JCJSONArrayBox(a), forKey: key)
        case .object(let o): try c.encode(JCJSONBox(o), forKey: key)
        }
    }
}

struct JCJSONArrayBox: Encodable {
    let arr: [JCJSON]
    init(_ arr: [JCJSON]) { self.arr = arr }
    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        for v in arr {
            switch v {
            case .string(let s): try c.encode(s)
            case .number(let n): try c.encode(n)
            case .bool(let b): try c.encode(b)
            case .null: try c.encodeNil()
            case .array(let a): try c.encode(JCJSONArrayBox(a))
            case .object(let o): try c.encode(JCJSONBox(o))
            }
        }
    }
}

// ── ValueRef resolution + binding context ────────────────────────────────────

/// A ValueRef: literal, `{"$":"key"}`, `{"$row":"field"}`, or `{"src":...}` (the
/// last resolves UPSTREAM — the widget treats an unresolved src as missing).
/// Optional transforms: `"fmt":"{}%"` and `"map":{"working":"#34c759",...}`.
struct JCValueRef {
    let raw: JCJSON
    init(_ raw: JCJSON) { self.raw = raw }

    /// Resolve to a display string, or nil when missing/unbound.
    func string(_ ctx: JCBindingContext) -> String? {
        resolve(ctx).flatMap { applyTransforms($0, kind: .string) }
    }
    /// Resolve to a number (0–100 progress, gauge values, etc.), or nil.
    func double(_ ctx: JCBindingContext) -> Double? {
        guard let v = resolve(ctx) else { return nil }
        if case .string = v, let s = applyTransforms(v, kind: .string) { return Double(s) }
        return v.asDouble
    }
    func array(_ ctx: JCBindingContext) -> [JCJSON]? { resolve(ctx)?.asArray }

    /// The raw bound JCJSON (literal or looked-up), before fmt/map.
    func resolve(_ ctx: JCBindingContext) -> JCJSON? {
        switch raw {
        case .object(let o):
            if let key = o["$"]?.asString { return ctx.data[key] }
            if let field = o["$row"]?.asString { return ctx.row?[field] }
            // A source binding resolves to data[key] too — the coordinator (awake)
            // or server (suspended) places the resolved value under the src key.
            // Absent → nil (renders as missing), never a crash.
            if let key = o["src"]?.asString { return ctx.data[key] }
            // On-device CLOCK binding: computed from Date() at render time, so it's
            // correct OFFLINE on every render/glance (no server push). Flows through
            // the normal map/fmt pipeline. See jcResolveClock.
            if o["clock"] != nil { return jcResolveClock(o) }
            return raw  // a plain object literal (rare) — pass through
        default:
            return raw  // literal string/number/bool
        }
    }

    private enum Kind { case string }
    private func applyTransforms(_ v: JCJSON, kind: Kind) -> String? {
        var s: String?
        // map: value → mapped string (e.g. state → hex color, or label).
        if case .object(let o) = raw, let mapObj = o["map"]?.asObject,
           let key = v.asString, let mapped = mapObj[key]?.asString {
            s = mapped
        } else {
            s = v.asString
        }
        guard var out = s else { return nil }
        // fmt: "{}" placeholder substitution (e.g. "{}%").
        if case .object(let o) = raw, let fmt = o["fmt"]?.asString {
            out = fmt.replacingOccurrences(of: "{}", with: out)
        }
        return out
    }

    /// Mapped color hex for ValueRefs whose map yields color strings.
    func color(_ ctx: JCBindingContext) -> Color? {
        guard let s = string(ctx) else { return nil }
        return jcParseColor(s)
    }
}

/// Holds the decoded `data` dict + the current `$row` (inside a list template).
struct JCBindingContext {
    let data: [String: JCJSON]
    var row: [String: JCJSON]?

    init(dataJSON: String) {
        if let d = dataJSON.data(using: .utf8),
           let obj = try? JSONDecoder().decode([String: JCJSON].self, from: d) {
            data = obj
        } else {
            data = [:]
        }
        row = nil
    }
    private init(data: [String: JCJSON], row: [String: JCJSON]?) {
        self.data = data; self.row = row
    }
    func withRow(_ row: [String: JCJSON]) -> JCBindingContext {
        JCBindingContext(data: data, row: row)
    }
}

// ── Color + condition helpers ────────────────────────────────────────────────

/// Parse a color: #rrggbb / #rrggbbaa hex, or a small named palette that matches
/// the coding-mode colors. Returns nil for unknown.
func jcParseColor(_ s: String) -> Color? {
    let t = s.trimmingCharacters(in: .whitespaces)
    if t.hasPrefix("#") {
        let hex = String(t.dropFirst())
        guard let val = UInt64(hex, radix: 16) else { return nil }
        let r, g, b, a: Double
        switch hex.count {
        case 6:
            r = Double((val >> 16) & 0xff) / 255
            g = Double((val >> 8) & 0xff) / 255
            b = Double(val & 0xff) / 255
            a = 1
        case 8:
            r = Double((val >> 24) & 0xff) / 255
            g = Double((val >> 16) & 0xff) / 255
            b = Double((val >> 8) & 0xff) / 255
            a = Double(val & 0xff) / 255
        default:
            return nil
        }
        return Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
    switch t.lowercased() {
    case "white": return .white
    case "black": return .black
    case "clear": return .clear
    case "green": return jcCodingColor("working")
    case "purple", "violet": return jcCodingColor("waiting")
    case "grey", "gray": return jcCodingColor("idle")
    case "red": return jcUsage5Color
    case "blue": return jcUsageWeekColor
    case "cyan": return jcStateColor("listening")
    case "pink": return jcStateColor("speaking")
    default: return nil
    }
}

/// On-device clock-driven value, computed from `Date()` so a design updates OFFLINE
/// on each render/glance (no server push). Returns a JCJSON that flows through the
/// normal string/double/color (map/fmt) pipeline. Unknown kind / bad timestamps →
/// nil (node renders empty) or a safe default; never crashes.
func jcResolveClock(_ o: [String: JCJSON]) -> JCJSON? {
    guard let kind = o["clock"]?.asString else { return nil }
    let now = Date()
    switch kind {
    case "phase":
        // value of the latest key whose `at` <= now; else `default`.
        var best: (Date, JCJSON)?
        for k in (o["keys"]?.asArray ?? []) {
            guard let ko = k.asObject, let at = jcParseDate(ko["at"]), at <= now else { continue }
            if best == nil || at > best!.0 { best = (at, ko["value"] ?? .null) }
        }
        if let b = best { return b.1 }
        return o["default"]
    case "fraction":
        guard let to = jcParseDate(o["to"]) else { return JCJSON.number(0) }
        guard let from = jcParseDate(o["from"]), to > from else {
            return JCJSON.number(now >= to ? 1 : 0)
        }
        return JCJSON.number(jcClamp01(now.timeIntervalSince(from) / to.timeIntervalSince(from)))
    case "remaining":
        guard let to = jcParseDate(o["to"]) else { return nil }
        return JCJSON.number(max(0, to.timeIntervalSince(now)))
    case "elapsed":
        guard let from = jcParseDate(o["from"]) else { return nil }
        return JCJSON.number(max(0, now.timeIntervalSince(from)))
    case "index":
        // 0-based index of the current segment; `keys` are sorted segment START times.
        let ts = (o["keys"]?.asArray ?? []).compactMap { jcParseDate($0) }.sorted()
        if ts.isEmpty { return JCJSON.number(0) }
        let passed = ts.filter { $0 <= now }.count
        return JCJSON.number(Double(max(0, min(ts.count - 1, passed - 1))))
    default:
        return nil
    }
}

/// Evaluate a `when` condition expression against the binding context. Unknown /
/// malformed → true (fail-open so a typo doesn't blank the whole design).
func jcEvalCondition(_ expr: JCJSON?, _ ctx: JCBindingContext) -> Bool {
    guard let expr = expr else { return true }
    guard let o = expr.asObject, let op = o["op"]?.asString else { return true }
    func operand(_ key: String) -> JCJSON? {
        guard let v = o[key] else { return nil }
        return JCValueRef(v).resolve(ctx)
    }
    switch op {
    case "and":
        return (o["items"]?.asArray ?? []).allSatisfy { jcEvalCondition($0, ctx) }
    case "or":
        return (o["items"]?.asArray ?? []).contains { jcEvalCondition($0, ctx) }
    case "not":
        return !jcEvalCondition(o["item"], ctx)
    case "exists":
        return operand("a") != nil
    case "eq":
        return (operand("a")?.asString) == (operand("b")?.asString)
    case "ne":
        return (operand("a")?.asString) != (operand("b")?.asString)
    case "gt":
        if let a = operand("a")?.asDouble, let b = operand("b")?.asDouble { return a > b }
        return false
    case "lt":
        if let a = operand("a")?.asDouble, let b = operand("b")?.asDouble { return a < b }
        return false
    case "between":
        if let v = operand("a")?.asDouble,
           let lo = operand("lo")?.asDouble, let hi = operand("hi")?.asDouble {
            return v >= lo && v <= hi
        }
        return false
    // On-device TIME conditions (operand = now), so a node can appear/switch at a
    // boundary OFFLINE. fail-open (true) on an unparseable `at` so a typo doesn't
    // blank the node.
    case "after":
        guard let at = jcParseDate(operand("at")) else { return true }
        return Date() >= at
    case "before":
        guard let at = jcParseDate(operand("at")) else { return true }
        return Date() < at
    default:
        return true
    }
}

// ── The renderer ─────────────────────────────────────────────────────────────

/// Recursive renderer with depth/count safety clamps. Build one per render pass
/// (the count is mutated). Unknown node types render nothing. Never crashes.

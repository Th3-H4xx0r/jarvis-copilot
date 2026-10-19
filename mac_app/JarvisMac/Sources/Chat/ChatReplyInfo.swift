import Foundation

// What the quiet line under a settled reply says, ported from the phone
// (ChatTurnStats, HarnessMeta, HarnessFormat): who answered, its tokens in
// and out, and how long it took.

/// One reply's numbers: tokens in (with the cached share), tokens out, time.
struct ChatTurnStats: Equatable {
    /// Uncached input tokens as the API counts them.
    var inputTokens: Int?
    /// Prompt tokens served from the provider's cache (read + write).
    var cachedTokens: Int?
    var outputTokens: Int?
    var durationMs: Int?
    /// The server metered this turn by estimate, not by count.
    var estimated = false

    var isEmpty: Bool { inputTokens == nil && outputTokens == nil && durationMs == nil }
    var hasTokens: Bool { inputTokens != nil || outputTokens != nil }

    /// Everything the model read this turn: uncached input plus cached prompt.
    var promptTokens: Int { (inputTokens ?? 0) + (cachedTokens ?? 0) }

    /// "40.2k in (98% cached) · 12 out · 3.2 s" (the time left off when
    /// something else on the line already says it).
    func line(time: Bool = true) -> String {
        var parts: [String] = []
        if hasTokens {
            var inPart = "\(estimated ? "~" : "")\(Self.compact(promptTokens)) in"
            if let cachedTokens, cachedTokens > 0, promptTokens > 0 {
                inPart += " (\(Int((Double(cachedTokens) / Double(promptTokens) * 100).rounded()))% cached)"
            }
            parts.append("\(inPart) · \(Self.compact(outputTokens ?? 0)) out")
        }
        if time, let durationMs { parts.append(Self.seconds(durationMs)) }
        return parts.joined(separator: " · ")
    }

    static func compact(_ n: Int) -> String {
        n >= 1_000 ? String(format: "%.1fk", Double(n) / 1_000) : "\(n)"
    }

    static func seconds(_ ms: Int) -> String {
        ms < 1_000 ? "\(ms) ms" : String(format: "%.1f s", Double(ms) / 1_000)
    }

    /// Usage from a metering / usage / done frame. The frames nest it
    /// differently (top level, `usage`, `data`, `data.usage`), and `turn` is
    /// this turn alone while the outer numbers are the session's totals — so
    /// the first nest that carries a count is read whole. `turnOnly` skips the
    /// totals (the live metering frames, which would read as this reply's).
    @discardableResult
    mutating func absorb(usage object: [String: Any], turnOnly: Bool = false) -> Bool {
        let usage = object["usage"] as? [String: Any], data = object["data"] as? [String: Any]
        let dataUsage = data?["usage"] as? [String: Any]
        var nests = [usage?["turn"], dataUsage?["turn"], object["turn"]].compactMap { $0 as? [String: Any] }
        if !turnOnly { nests += [object, usage, data, dataUsage].compactMap { $0 } }
        guard let nest = nests.first(where: {
            Self.int($0, Self.inputKeys) != nil || Self.int($0, Self.outputKeys) != nil
        }) else { return false }
        let before = self
        setTokens(from: nest)
        if let e = nest["estimated"] as? Bool { estimated = e }
        return self != before
    }

    /// What the server stored on a reply (`_turnUsage`, `_turnDuration`).
    init?(stored m: [String: Any]) {
        if let usage = m["_turnUsage"] as? [String: Any] { setTokens(from: usage) }
        if let seconds = (m["_turnDuration"] as? NSNumber)?.doubleValue { durationMs = Int(seconds * 1_000) }
        if isEmpty { return nil }
    }

    init(inputTokens: Int? = nil, cachedTokens: Int? = nil, outputTokens: Int? = nil, durationMs: Int? = nil,
         estimated: Bool = false) {
        self.inputTokens = inputTokens
        self.cachedTokens = cachedTokens
        self.outputTokens = outputTokens
        self.durationMs = durationMs
        self.estimated = estimated
    }

    private mutating func setTokens(from nest: [String: Any]) {
        inputTokens = Self.int(nest, Self.inputKeys)
        outputTokens = Self.int(nest, Self.outputKeys)
        let cached = (Self.int(nest, ["cache_read_tokens", "cache_read_input_tokens"]) ?? 0)
            + (Self.int(nest, ["cache_write_tokens", "cache_creation_input_tokens"]) ?? 0)
        cachedTokens = cached > 0 ? cached : nil
    }

    private static let inputKeys = ["input_tokens", "prompt_tokens", "input"]
    private static let outputKeys = ["output_tokens", "completion_tokens", "output"]

    private static func int(_ nest: [String: Any], _ keys: [String]) -> Int? {
        for key in keys {
            if let n = nest[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.intValue }
        }
        return nil
    }
}

/// Which wire a Route picked (`_meta.route`): its label, the router's
/// confidence, and why it failed when it fell back to the default wire.
struct HarnessRoute: Equatable {
    var label: String
    var by: String?
    var model: String?
    var confidence: Double?
    var ms: Int?
    var error: String?

    init(label: String, by: String? = nil, model: String? = nil, confidence: Double? = nil,
         ms: Int? = nil, error: String? = nil) {
        self.label = label
        self.by = by
        self.model = model
        self.confidence = confidence
        self.ms = ms
        self.error = error
    }

    init?(json: [String: Any]?) {
        guard let json, let label = json["label"] as? String, !label.isEmpty else { return nil }
        self.init(label: label, by: json["by"] as? String, model: json["model"] as? String,
                  confidence: (json["confidence"] as? NSNumber)?.doubleValue,
                  ms: (json["ms"] as? NSNumber)?.intValue, error: json["error"] as? String)
    }
}

/// Who answered a reply: the server's `_meta` on the stored message, or the
/// stream's closing `turn_meta` frame — the harness node's model, how long it
/// took, the route it took, whether it handed off.
struct HarnessMeta: Equatable {
    var kind: String?
    var model: String?
    var ms: Int?
    var handedOff: Bool?
    var note: String?
    var node: String?
    var route: HarnessRoute?

    init(kind: String? = nil, model: String? = nil, ms: Int? = nil, handedOff: Bool? = nil,
         note: String? = nil, node: String? = nil, route: HarnessRoute? = nil) {
        self.kind = kind
        self.model = model
        self.ms = ms
        self.handedOff = handedOff
        self.note = note
        self.node = node
        self.route = route
    }

    init?(json: [String: Any]?) {
        guard let json, let model = json["model"] as? String, !model.isEmpty else { return nil }
        self.init(kind: json["kind"] as? String, model: model, ms: (json["ms"] as? NSNumber)?.intValue,
                  handedOff: json["handed_off"] as? Bool, note: json["note"] as? String,
                  node: json["node"] as? String, route: HarnessRoute(json: json["route"] as? [String: Any]))
    }

    /// A reply a background or review step posted on its own.
    var isBackground: Bool { kind == "background" || kind == "review" }
}

/// The "answered by" words, the same as the phone's and the web's
/// (`HarnessFormat.answeredBy`): "Claude Opus 5.5 · 3.2 s · routed deep 82% · handed off".
enum HarnessFormat {
    static func shortModel(_ ref: String) -> String {
        var m = ref
        if m.hasPrefix("@"), let colon = m.firstIndex(of: ":") { m = String(m[m.index(after: colon)...]) }
        let parts = m.lowercased().split(separator: "-").map(String.init)
        if parts.count >= 3, parts[0] == "claude", ["opus", "sonnet", "haiku"].contains(parts[1]),
           let major = Int(parts[2]) {
            var version = "\(major)"
            if parts.count >= 4, let minor = Int(parts[3]), parts[3].count <= 2 { version += ".\(minor)" }
            return "Claude \(parts[1].prefix(1).uppercased())\(parts[1].dropFirst()) \(version)"
        }
        return m
    }

    static func answeredBy(_ meta: HarnessMeta?) -> String {
        guard let meta, let model = meta.model, !model.isEmpty else { return "" }
        var parts = [shortModel(model)]
        if meta.isBackground, let kind = meta.kind { parts.append(kind) }
        if let ms = meta.ms, ms > 0 { parts.append(seconds(ms)) }
        if !meta.isBackground, let route = meta.route { parts.append(routedText(route)) }
        if meta.handedOff == true { parts.append("handed off") }
        if let note = meta.note, !note.isEmpty { parts.append(note) }
        return parts.joined(separator: " · ")
    }

    /// "routed deep 82%" — which wire a Route picked; a failed router took the default wire.
    static func routedText(_ route: HarnessRoute) -> String {
        if let error = route.error, !error.isEmpty { return "routed default (router failed)" }
        guard let confidence = route.confidence else { return "routed \(route.label)" }
        return "routed \(route.label) \(Int((confidence * 100).rounded()))%"
    }

    private static func seconds(_ ms: Int) -> String {
        let s = Double(ms) / 1000
        return s < 10 ? String(format: "%.1f s", s) : "\(Int(s.rounded())) s"
    }
}

/// What the server stored with this turn's reply — who answered (`_meta`),
/// its numbers (`_turnUsage`, `_turnDuration`) and its reasoning — for a reply
/// taken from the record rather than the stream (the done frame's session, a
/// re-attach's snapshot).
struct ChatReplyRecord: Equatable {
    var meta: HarnessMeta?
    var stats: ChatTurnStats?
    var reasoning = ""

    /// From this turn's assistant messages (after the last thing you said), newest first.
    init?(messages: [[String: Any]]) {
        for m in messages.reversed() {
            let role = m["role"] as? String
            if role == "user" { break }
            guard role == "assistant" else { continue }
            if meta == nil { meta = HarnessMeta(json: m["_meta"] as? [String: Any]) }
            if stats == nil { stats = ChatTurnStats(stored: m) }
            if reasoning.isEmpty { reasoning = m["thinking"] as? String ?? m["reasoning"] as? String ?? "" }
        }
        guard meta != nil || stats != nil || !reasoning.isEmpty else { return nil }
    }
}

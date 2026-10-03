import Foundation

/// Who answered a reply, from the server's `_meta` (stored on the message) or
/// the stream's closing `turn_meta` frame: the harness node's model, how long it
/// took, and whether it handed off or was a background / review reply.
struct HarnessMeta: Equatable, Hashable, Sendable {
    var kind: String?
    var model: String?
    var ms: Int?
    var handedOff: Bool?
    var note: String?
    var node: String?

    init(kind: String? = nil, model: String? = nil, ms: Int? = nil, handedOff: Bool? = nil,
         note: String? = nil, node: String? = nil) {
        self.kind = kind
        self.model = model
        self.ms = ms
        self.handedOff = handedOff
        self.note = note
        self.node = node
    }

    init?(json: [String: Any]?) {
        guard let json, let model = json["model"] as? String, !model.isEmpty else { return nil }
        self.init(kind: json["kind"] as? String,
                  model: model,
                  ms: (json["ms"] as? NSNumber)?.intValue,
                  handedOff: json["handed_off"] as? Bool,
                  note: json["note"] as? String,
                  node: json["node"] as? String)
    }

    /// A reply a background or review step posted on its own.
    var isBackground: Bool { kind == "background" || kind == "review" }
}

/// The "answered by" line under a reply. Same output as the web's
/// `HarnessFormat.answeredBy` (webui/static/harness_format.js).
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
        if meta.handedOff == true { parts.append("handed off") }
        if let note = meta.note, !note.isEmpty { parts.append(note) }
        return parts.joined(separator: " · ")
    }

    private static func seconds(_ ms: Int) -> String {
        let s = Double(ms) / 1000
        return s < 10 ? String(format: "%.1f s", s) : "\(Int(s.rounded())) s"
    }
}

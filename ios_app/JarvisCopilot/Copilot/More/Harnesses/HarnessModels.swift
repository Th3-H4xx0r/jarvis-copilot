import Foundation

/// An agent harness: a graph of model steps the server runs for a turn
/// (`agent/harness/schema.py` is the one validator; the app only edits and
/// displays). Node types: message (start), answer, route, background, review,
/// computer (drives the Mac). Edge `when`: always · handoff · default ·
/// label:<name> · slow:<s> · tools:<n> · hands (an Answer/Background model gets
/// a Computer node's `computer_do` tool) · stuck (where a Computer node's
/// unfinished job goes).
struct AgentHarness: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var icon: String?
    var builtin: Bool?
    var version: Int?
    var nodes: [HarnessNode]
    var edges: [HarnessEdge]
    var problems: [HarnessProblem]?

    var isBuiltin: Bool { builtin ?? false }
    var title: String { [icon, name].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " ") }

    func problems(forNode id: String) -> [HarnessProblem] {
        (problems ?? []).filter { $0.node == id }
    }

    func node(_ id: String) -> HarnessNode? { nodes.first { $0.id == id } }
}

enum HarnessNodeType: String, Codable, CaseIterable, Hashable {
    case message, answer, route, background, review, computer

    var label: String {
        switch self {
        case .message: return "Message"
        case .answer: return "Answer"
        case .route: return "Route"
        case .background: return "Background"
        case .review: return "Review"
        case .computer: return "Computer"
        }
    }

    /// The Add-step menu's icon.
    var symbol: String {
        switch self {
        case .message: return "bubble.left"
        case .answer: return "text.bubble"
        case .route: return "arrow.triangle.branch"
        case .background: return "clock.arrow.circlepath"
        case .review: return "checkmark.seal"
        case .computer: return "desktopcomputer"
        }
    }
}

/// `"lean" | "all" | "none"` or a list of toolset names.
enum HarnessTools: Codable, Hashable {
    case preset(String)
    case toolsets([String])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .preset(s); return }
        self = .toolsets(try c.decode([String].self))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .preset(let s): try c.encode(s)
        case .toolsets(let l): try c.encode(l)
        }
    }
}

/// A route rule value: keywords / regex / surface text, or a has-attachment flag.
enum HarnessRuleValue: Codable, Hashable {
    case string(String)
    case bool(Bool)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        self = .string((try? c.decode(String.self)) ?? "")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .bool(let b): try c.encode(b)
        }
    }

    var text: String {
        switch self {
        case .string(let s): return s
        case .bool(let b): return b ? "yes" : "no"
        }
    }
}

struct HarnessRule: Codable, Hashable {
    var match: String
    var value: HarnessRuleValue?
    var label: String
}

/// One step. A Computer node uses `model` (a DECISION model; nil = the first
/// one available), `fallbackModel` (a chat model for steps it's unsure about;
/// nil = the calling node's own model) and `maxSteps` (default 30).
struct HarnessNode: Codable, Identifiable, Hashable {
    var id: String
    var type: HarnessNodeType
    var x: Double
    var y: Double
    var model: String?
    var tools: HarnessTools?
    var deliver: String?
    var by: String?
    var rules: [HarnessRule]?
    var labels: [String]?
    /// What each Route label means (`label → text`), shown to a model router so it picks well.
    var labelDescriptions: [String: String]?
    var instructions: String?
    var label: String?
    var fallbackModel: String?
    var maxSteps: Int?
    /// Keys this app doesn't know (a newer server's), sent back untouched on save.
    var extra: [String: JSONValue]?

    init(id: String, type: HarnessNodeType, x: Double, y: Double) {
        self.id = id
        self.type = type
        self.x = x
        self.y = y
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, type, x, y, model, tools, deliver, by, rules, labels, instructions, label
        case labelDescriptions = "label_descriptions"
        case fallbackModel = "fallback_model"
        case maxSteps = "max_steps"
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decode(HarnessNodeType.self, forKey: .type)
        x = try c.decode(Double.self, forKey: .x)
        y = try c.decode(Double.self, forKey: .y)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        tools = try c.decodeIfPresent(HarnessTools.self, forKey: .tools)
        deliver = try c.decodeIfPresent(String.self, forKey: .deliver)
        by = try c.decodeIfPresent(String.self, forKey: .by)
        rules = try c.decodeIfPresent([HarnessRule].self, forKey: .rules)
        labels = try c.decodeIfPresent([String].self, forKey: .labels)
        instructions = try c.decodeIfPresent(String.self, forKey: .instructions)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        labelDescriptions = try c.decodeIfPresent([String: String].self, forKey: .labelDescriptions)
        fallbackModel = try c.decodeIfPresent(String.self, forKey: .fallbackModel)
        maxSteps = try c.decodeIfPresent(Int.self, forKey: .maxSteps)
        let known = Set(CodingKeys.allCases.map(\.stringValue))
        let all = try decoder.container(keyedBy: AnyKey.self)
        var rest: [String: JSONValue] = [:]
        for key in all.allKeys where !known.contains(key.stringValue) {
            rest[key.stringValue] = try all.decode(JSONValue.self, forKey: key)
        }
        extra = rest.isEmpty ? nil : rest
    }

    /// The order the synthesized encoder used, then the unknown keys.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(type, forKey: .type)
        try c.encode(x, forKey: .x)
        try c.encode(y, forKey: .y)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(tools, forKey: .tools)
        try c.encodeIfPresent(deliver, forKey: .deliver)
        try c.encodeIfPresent(by, forKey: .by)
        try c.encodeIfPresent(rules, forKey: .rules)
        try c.encodeIfPresent(labels, forKey: .labels)
        try c.encodeIfPresent(instructions, forKey: .instructions)
        try c.encodeIfPresent(label, forKey: .label)
        try c.encodeIfPresent(labelDescriptions, forKey: .labelDescriptions)
        try c.encodeIfPresent(fallbackModel, forKey: .fallbackModel)
        try c.encodeIfPresent(maxSteps, forKey: .maxSteps)
        guard let extra, !extra.isEmpty else { return }
        var rest = encoder.container(keyedBy: AnyKey.self)
        for (key, value) in extra.sorted(by: { $0.key < $1.key }) {
            try rest.encode(value, forKey: AnyKey(stringValue: key))
        }
    }
}

struct HarnessEdge: Codable, Hashable {
    var from: String
    var to: String
    var when: String

    /// Wires that aren't the plain flow are drawn dashed: a hand-off, a Computer
    /// node's tool link (`hands`) and where its unfinished job goes (`stuck`).
    var isDashed: Bool { ["handoff", "hands", "stuck"].contains(when) }

    init(from: String, to: String, when: String = "always") {
        self.from = from
        self.to = to
        self.when = when
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        from = try c.decode(String.self, forKey: .from)
        to = try c.decode(String.self, forKey: .to)
        when = (try? c.decode(String.self, forKey: .when)) ?? "always"
    }

    enum CodingKeys: String, CodingKey { case from, to, when }
}

/// One validation problem from the server; `node`/`edge` say where to draw it.
struct HarnessProblem: Codable, Hashable {
    var node: String?
    var edge: Int?
    var message: String
}

/// `GET /api/harnesses`. `assignments` holds the EFFECTIVE harness per surface
/// (`default`, `voice`, `chat`; older servers send just voice/chat), and
/// `overrides` the Voice/Chat picks of their own ("" = same as the default),
/// absent on servers from before the one default.
struct HarnessSnapshot: Codable {
    var harnesses: [AgentHarness]
    var assignments: [String: String]
    var overrides: [String: String]?
}

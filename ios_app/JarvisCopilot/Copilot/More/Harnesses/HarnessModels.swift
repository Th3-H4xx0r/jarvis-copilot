import Foundation

/// An agent harness: a graph of model steps the server runs for a turn
/// (`webui/api/harness_schema.py` is the one validator; the app only edits and
/// displays). Node types: message (start), answer, route, background, review.
/// Edge `when`: always · handoff · default · label:<name> · slow:<s> · tools:<n>.
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
    case message, answer, route, background, review

    var label: String {
        switch self {
        case .message: return "Message"
        case .answer: return "Answer"
        case .route: return "Route"
        case .background: return "Background"
        case .review: return "Review"
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
    var instructions: String?
    var label: String?
    var fallbackModel: String?
    var maxSteps: Int?

    init(id: String, type: HarnessNodeType, x: Double, y: Double) {
        self.id = id
        self.type = type
        self.x = x
        self.y = y
    }

    enum CodingKeys: String, CodingKey {
        case id, type, x, y, model, tools, deliver, by, rules, labels, instructions, label
        case fallbackModel = "fallback_model"
        case maxSteps = "max_steps"
    }
}

struct HarnessEdge: Codable, Hashable {
    var from: String
    var to: String
    var when: String

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

struct HarnessSnapshot: Codable {
    var harnesses: [AgentHarness]
    var assignments: [String: String]
}

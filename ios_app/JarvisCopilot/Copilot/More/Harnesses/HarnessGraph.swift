import CoreGraphics
import Foundation

/// Pure edits on a harness graph — the editor calls these, the server validates
/// on save. Same rules as the web's `HarnessGraph` (webui/static/harness_graph.js).
enum HarnessGraph {
    static func newHarness(id: String, name: String) -> AgentHarness {
        AgentHarness(id: id, name: name, icon: nil, builtin: nil, version: nil,
                     nodes: [HarnessNode(id: "in", type: .message, x: 40, y: 40)], edges: [], problems: nil)
    }

    static func defaults(for type: HarnessNodeType) -> HarnessNode {
        var n = HarnessNode(id: "", type: type, x: 0, y: 0)
        switch type {
        case .answer:
            n.tools = .preset("lean")
            n.model = ""
        case .route:
            n.by = "rules"
            n.rules = []
            n.labels = []
        case .background:
            n.tools = .preset("all")
            n.model = ""
            n.deliver = "speak_or_notify"
        case .review:
            n.model = ""
            n.deliver = "post_if_changed"
        case .message:
            break
        }
        return n
    }

    /// Adds a node of `type` at `point`; returns its new id (`<type>-<n>`).
    @discardableResult
    static func addNode(_ h: inout AgentHarness, type: HarnessNodeType, at point: CGPoint) -> String {
        var n = 1
        while h.nodes.contains(where: { $0.id == "\(type.rawValue)-\(n)" }) { n += 1 }
        var node = defaults(for: type)
        node.id = "\(type.rawValue)-\(n)"
        node.x = point.x.rounded()
        node.y = point.y.rounded()
        h.nodes.append(node)
        return node.id
    }

    /// Removes a node and every wire touching it. The start node stays.
    static func removeNode(_ h: inout AgentHarness, id: String) {
        guard let node = h.node(id), node.type != .message else { return }
        h.nodes.removeAll { $0.id == id }
        h.edges.removeAll { $0.from == id || $0.to == id }
    }

    /// False for a self wire, a duplicate, or an unknown end.
    @discardableResult
    static func connect(_ h: inout AgentHarness, from: String, to: String, when: String) -> Bool {
        guard from != to, h.node(from) != nil, h.node(to) != nil,
              !h.edges.contains(where: { $0.from == from && $0.to == to }) else { return false }
        h.edges.append(HarnessEdge(from: from, to: to, when: when.isEmpty ? "always" : when))
        return true
    }

    static func disconnect(_ h: inout AgentHarness, index: Int) {
        guard h.edges.indices.contains(index) else { return }
        h.edges.remove(at: index)
    }

    static func duplicate(_ h: AgentHarness, id: String, name: String) -> AgentHarness {
        var c = h
        c.id = id
        c.name = name
        c.builtin = nil
        c.version = nil
        c.problems = nil
        return c
    }

    /// The condition a new wire starts with: a Route's first wire is `default`,
    /// later ones get the next unused label; Answer → Background is a hand-off;
    /// everything else runs `always`.
    static func defaultWhen(_ h: AgentHarness, from: String, to: String? = nil) -> String {
        guard let source = h.node(from) else { return "always" }
        if source.type == .route {
            let used = Set(h.edges.filter { $0.from == from }.map(\.when))
            if !used.contains("default") { return "default" }
            let labels = (source.labels ?? []) + (source.rules ?? []).map(\.label)
            if let free = labels.first(where: { !used.contains("label:\($0)") }) { return "label:\(free)" }
            var n = 1
            while used.contains("label:route-\(n)") { n += 1 }
            return "label:route-\(n)"
        }
        if source.type == .answer, let to, h.node(to)?.type == .background { return "handoff" }
        return "always"
    }
}

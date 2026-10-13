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
        case .computer:
            // No model = the first decision model; no fallback = the calling node's model.
            n.maxSteps = 30
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
    /// Answer/Background → Computer gives that model the Mac (`hands`); Computer →
    /// Answer is where an unfinished Mac job goes (`stuck`); everything else runs `always`.
    static func defaultWhen(_ h: AgentHarness, from: String, to: String? = nil) -> String {
        guard let source = h.node(from) else { return "always" }
        if source.type == .route {
            let used = Set(h.edges.filter { $0.from == from }.map(\.when))
            if !used.contains("default") { return "default" }
            let labels = (source.labels ?? []) + (source.rules ?? []).map(\.label)
            if let free = labels.first(where: { !used.contains("label:\($0)") }) { return "label:\(free)" }
            var n = (source.labels ?? []).count + 1
            while labels.contains("path-\(n)") || used.contains("label:path-\(n)") { n += 1 }
            return "label:path-\(n)"
        }
        let target = to.flatMap { h.node($0)?.type }
        if source.type == .answer, target == .background { return "handoff" }
        if source.type == .answer || source.type == .background, target == .computer { return "hands" }
        if source.type == .computer, target == .answer { return "stuck" }
        return "always"
    }

    /// The conditions the wire sheet offers for wire `index`. A wire into a
    /// Computer node from an Answer/Background node is only ever its `hands`, and
    /// a Computer node's wire to an Answer node only ever `stuck`.
    static func wireChoices(_ h: AgentHarness, edge index: Int) -> [String] {
        guard h.edges.indices.contains(index), let source = h.node(h.edges[index].from) else { return [] }
        let target = h.node(h.edges[index].to)?.type
        switch source.type {
        case .route:
            return ["default"] + wireLabelChoices(h, edge: index).map { "label:\($0)" }
        case .answer:
            return target == .computer ? ["hands"] : ["always", "handoff", "slow:20", "tools:5"]
        case .background:
            return target == .computer ? ["hands"] : ["always"]
        case .computer:
            return target == .answer ? ["stuck"] : ["always"]
        case .message, .review:
            return ["always"]
        }
    }

    /// How a wire's condition reads on the canvas and in the wire sheet.
    static func wireTitle(_ when: String) -> String {
        switch when {
        case "hands": return "Hands"
        case "stuck": return "When stuck"
        default: return when
        }
    }

    /// A Background step's only wires out are `hands` to a Computer step.
    static func canWire(_ h: AgentHarness, from: String, to: String) -> Bool {
        h.node(from)?.type != .background || h.node(to)?.type == .computer
    }

    /// Wires `from` → `to` with ``defaultWhen``. A label made up for a Route's new
    /// wire joins the Route's labels, so a model router can pick it (the web's
    /// `nextWhen` does the same). False when ``connect`` refuses the wire.
    @discardableResult
    static func wire(_ h: inout AgentHarness, from: String, to: String) -> Bool {
        let when = defaultWhen(h, from: from, to: to)
        guard connect(&h, from: from, to: to, when: when) else { return false }
        if when.hasPrefix("label:"), let i = h.nodes.firstIndex(where: { $0.id == from }) {
            let label = String(when.dropFirst("label:".count))
            let known = (h.nodes[i].labels ?? []) + (h.nodes[i].rules ?? []).map(\.label)
            if !known.contains(label) { h.nodes[i].labels = (h.nodes[i].labels ?? []) + [label] }
        }
        return true
    }

    // MARK: Route labels

    /// Renames a Route's label, carrying its description, its rules and every
    /// `label:<old>` wire out of the Route along. A blank name, or one another label
    /// or rule already has (the two would then share their wires for good), is refused: false.
    /// A name only a stray wire carries (its label is on no list, so nothing could
    /// pick it) is fine when this label has no wire of its own: the label adopts that wire.
    @discardableResult
    static func renameLabel(_ h: inout AgentHarness, node id: String, from old: String, to name: String) -> Bool {
        guard let i = h.nodes.firstIndex(where: { $0.id == id }),
              let labels = h.nodes[i].labels, labels.contains(old) else { return false }
        let new = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if new == old { return true }
        let ruleLabels = (h.nodes[i].rules ?? []).map(\.label)
        if new.isEmpty || labels.contains(new) || ruleLabels.contains(new) { return false }
        let wired = h.edges.filter { $0.from == id }.compactMap(wireLabel)
        if wired.contains(new) && wired.contains(old) { return false }
        carry(&h, node: i, from: old, to: new)
        return true
    }

    /// Retypes a Route wire's label without the Route's labels and wires drifting
    /// apart: a free name renames the label the wire had (description, rules and
    /// all), a label no other wire has just takes the wire, and a stray wire's new
    /// name joins the labels. Blank, or a name another wire has, is refused: false.
    @discardableResult
    static func relabelWire(_ h: inout AgentHarness, edge index: Int, to name: String) -> Bool {
        guard h.edges.indices.contains(index), let old = wireLabel(h.edges[index]),
              let i = h.nodes.firstIndex(where: { $0.id == h.edges[index].from }),
              h.nodes[i].type == .route else { return false }
        let new = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if new.isEmpty { return false }
        if new == old { return true }
        let node = h.nodes[i]
        let others = h.edges.indices.filter { $0 != index && h.edges[$0].from == node.id }
            .compactMap { wireLabel(h.edges[$0]) }
        let taken = Set((node.labels ?? []) + (node.rules ?? []).map(\.label) + others + [old])
        let canPick = pickable(node)
        if !taken.contains(new), canPick.contains(old), !others.contains(old) {
            carry(&h, node: i, from: old, to: new)
            return true
        }
        if others.contains(new) { return false }
        if canPick.contains(new) {
            h.edges[index].when = "label:\(new)"
            return true
        }
        if taken.contains(new) { return false }
        h.nodes[i].labels = (node.labels ?? []) + [new]
        h.edges[index].when = "label:\(new)"
        return true
    }

    /// The labels the wire sheet offers for a Route wire: the ones the Route can
    /// pick by that no other wire of the Route already has.
    static func wireLabelChoices(_ h: AgentHarness, edge index: Int) -> [String] {
        guard h.edges.indices.contains(index), let node = h.node(h.edges[index].from) else { return [] }
        let others = Set(h.edges.indices.filter { $0 != index && h.edges[$0].from == node.id }
            .compactMap { wireLabel(h.edges[$0]) })
        return pickable(node).filter { !others.contains($0) }
    }

    /// The labels a Route can pick a wire by: a model router only its labels,
    /// rules also their rules' labels (in order, once each).
    static func pickable(_ node: HarnessNode) -> [String] {
        let all = (node.labels ?? []) + (node.by == "model" ? [] : (node.rules ?? []).map(\.label))
        var seen = Set<String>()
        return all.filter { seen.insert($0).inserted }
    }

    private static func wireLabel(_ e: HarnessEdge) -> String? {
        e.when.hasPrefix("label:") ? String(e.when.dropFirst("label:".count)) : nil
    }

    /// old → new everywhere on node `i`: the label, its description, its rules, its wires.
    private static func carry(_ h: inout AgentHarness, node i: Int, from old: String, to new: String) {
        let id = h.nodes[i].id
        if let index = h.nodes[i].labels?.firstIndex(of: old) { h.nodes[i].labels?[index] = new }
        if let note = h.nodes[i].labelDescriptions?.removeValue(forKey: old) {
            h.nodes[i].labelDescriptions?[new] = note
        }
        // A rules Route picks the wire its rule names, so the rules move too.
        for r in (h.nodes[i].rules ?? []).indices where h.nodes[i].rules?[r].label == old {
            h.nodes[i].rules?[r].label = new
        }
        for e in h.edges.indices where h.edges[e].from == id && h.edges[e].when == "label:\(old)" {
            h.edges[e].when = "label:\(new)"
        }
    }

    /// Adds the next free `path-N` label (free of the labels and the Route's wires),
    /// the name the web gives a label it makes for a new wire.
    @discardableResult
    static func addLabel(_ h: inout AgentHarness, node id: String) -> String? {
        guard let i = h.nodes.firstIndex(where: { $0.id == id }) else { return nil }
        let labels = h.nodes[i].labels ?? []
        let used = Set(h.edges.filter { $0.from == id }.map(\.when))
        var n = labels.count + 1
        while labels.contains("path-\(n)") || used.contains("label:path-\(n)") { n += 1 }
        h.nodes[i].labels = labels + ["path-\(n)"]
        return "path-\(n)"
    }

    /// Removes labels and their descriptions. Their wires stay (a model router can no
    /// longer pick them; delete the wire too if it should go).
    static func removeLabels(_ h: inout AgentHarness, node id: String, at offsets: IndexSet) {
        guard let i = h.nodes.firstIndex(where: { $0.id == id }), let all = h.nodes[i].labels else { return }
        let gone = all.indices.filter { offsets.contains($0) }.map { all[$0] }
        let labels = all.indices.filter { !offsets.contains($0) }.map { all[$0] }
        h.nodes[i].labels = labels
        for label in gone where !labels.contains(label) { h.nodes[i].labelDescriptions?[label] = nil }
        if h.nodes[i].labelDescriptions?.isEmpty == true { h.nodes[i].labelDescriptions = nil }
        // Its wires go too: left behind, the router could never pick them.
        let dropped = Set(gone.filter { !labels.contains($0) }.map { "label:\($0)" })
        h.edges.removeAll { $0.from == id && dropped.contains($0.when) }
    }

    /// Sets what a label means; blank text clears it (and an empty map is dropped, not saved as `{}`).
    static func describeLabel(_ h: inout AgentHarness, node id: String, label: String, as text: String) {
        guard let i = h.nodes.firstIndex(where: { $0.id == id }) else { return }
        var notes = h.nodes[i].labelDescriptions ?? [:]
        notes[label] = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        h.nodes[i].labelDescriptions = notes.isEmpty ? nil : notes
    }
}

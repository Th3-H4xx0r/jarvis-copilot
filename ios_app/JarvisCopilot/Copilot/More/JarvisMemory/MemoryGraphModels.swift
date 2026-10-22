import CoreGraphics
import Foundation

// The memory map's wire shapes and the graph the canvas draws. Contract:
// docs/superpowers/specs/2026-10-22-memory-graph-and-sources-design.md, "Server API".
// Entity ids are TEXT on the server and recall ids INTEGER, so every id is read
// through `MoreJSON.text` and kept as a string.

/// What a node is. `me` is the virtual "You" in the middle; the server never
/// sends it as a node.
enum MemoryEntityKind: String, CaseIterable, Identifiable, Sendable {
    case person, place, org, event, topic, me

    var id: String { rawValue }

    /// The five the type chips filter on, in the order the query string lists them.
    static let filterable: [MemoryEntityKind] = [.person, .place, .org, .event, .topic]

    init(wire: String) { self = MemoryEntityKind(rawValue: wire.lowercased()) ?? .topic }

    var label: String {
        switch self {
        case .person: return "Person"
        case .place: return "Place"
        case .org: return "Organisation"
        case .event: return "Event"
        case .topic: return "Topic"
        case .me: return "You"
        }
    }

    /// The chip's name: plural.
    var chipLabel: String {
        switch self {
        case .person: return "People"
        case .place: return "Places"
        case .org: return "Orgs"
        case .event: return "Events"
        case .topic: return "Topics"
        case .me: return "You"
        }
    }

    var symbol: String {
        switch self {
        case .person: return "person"
        case .place: return "mappin"
        case .org: return "building.2"
        case .event: return "calendar"
        case .topic: return "tag"
        case .me: return "person.crop.circle"
        }
    }
}

struct MemoryGraphCenter: Equatable, Sendable {
    var id: String
    var label: String
    var type: String

    init(id: String, label: String, type: String) {
        self.id = id
        self.label = label
        self.type = type
    }

    /// No center (or a broken one) is the You view.
    init(json: JSONObject) {
        let id = MoreJSON.text(json["id"])
        self.id = id.isEmpty ? MemoryGraph.meID : id
        let label = MoreJSON.text(json["label"])
        self.label = label.isEmpty && self.id == MemoryGraph.meID ? "You" : label
        let type = MoreJSON.text(json["type"])
        self.type = type.isEmpty && self.id == MemoryGraph.meID ? "me" : type
    }
}

struct MemoryGraphNode: Identifiable, Equatable, Sendable {
    var id: String
    var label: String
    var type: String
    var weight: Int
    var pinned: Bool
    var eventStart: Date?

    init(id: String, label: String, type: String, weight: Int, pinned: Bool = false, eventStart: Date? = nil) {
        self.id = id
        self.label = label
        self.type = type
        self.weight = weight
        self.pinned = pinned
        self.eventStart = eventStart
    }

    init(json: JSONObject) {
        id = MoreJSON.text(json["id"])
        label = MoreJSON.text(json["label"])
        type = MoreJSON.text(json["type"])
        weight = max(0, MoreJSON.int(json["weight"]))
        pinned = MoreJSON.isTrue(json["pinned"])
        eventStart = RelativeTime.parse(json["event_start"])
    }

    var kind: MemoryEntityKind { id == MemoryGraph.meID ? .me : MemoryEntityKind(wire: type) }
}

/// An undirected link. `a`/`b` keep the server's order; `key` doesn't care.
struct MemoryGraphEdge: Equatable, Hashable, Sendable {
    var a: String
    var b: String
    var weight: Int

    var key: MemoryEdgeKey { MemoryEdgeKey(a, b) }

    init(a: String, b: String, weight: Int) {
        self.a = a
        self.b = b
        self.weight = weight
    }

    init?(json: JSONObject) {
        let a = MoreJSON.text(json["a"]), b = MoreJSON.text(json["b"])
        guard !a.isEmpty, !b.isEmpty else { return nil }
        self.init(a: a, b: b, weight: max(0, MoreJSON.int(json["weight"])))
    }
}

/// One key per unordered pair.
struct MemoryEdgeKey: Hashable, Sendable {
    let lo: String
    let hi: String
    init(_ x: String, _ y: String) { (lo, hi) = x <= y ? (x, y) : (y, x) }
}

/// `GET graph` and `GET graph/highlight`.
struct MemoryGraphPayload: Equatable, Sendable {
    var center: MemoryGraphCenter
    var nodes: [MemoryGraphNode]
    var edges: [MemoryGraphEdge]
    /// Entity ids a recall lit up (highlight endpoint only).
    var highlight: [String]

    init(json: JSONObject) {
        center = MemoryGraphCenter(json: MoreJSON.map(json["center"]))
        nodes = MoreJSON.mapList(json["nodes"]).map(MemoryGraphNode.init(json:)).filter { !$0.id.isEmpty }
        edges = MoreJSON.mapList(json["edges"]).compactMap(MemoryGraphEdge.init(json:))
        highlight = MoreJSON.stringList(json["highlight"])
    }
}

// MARK: - Entity

struct MemoryEntity: Equatable, Sendable {
    var id: String
    var type: String
    var label: String
    var aliases: [String]
    var pinned: Bool
    var eventStart: Date?
    var eventEnd: Date?
    var summary: String

    init(json: JSONObject) {
        id = MoreJSON.text(json["id"])
        type = MoreJSON.text(json["type"])
        label = MoreJSON.text(json["label"] ?? json["canonical"])
        aliases = MoreJSON.stringList(json["aliases"])
        pinned = MoreJSON.isTrue(json["pinned"])
        eventStart = RelativeTime.parse(json["event_start"])
        eventEnd = RelativeTime.parse(json["event_end"])
        summary = MoreJSON.text(json["summary"])
    }

    var kind: MemoryEntityKind { MemoryEntityKind(wire: type) }
}

/// One memory linked to an entity.
struct MemoryEntityMemory: Identifiable, Equatable, Sendable {
    var id: String
    var body: String
    var createdAt: Date?
    var eventStart: Date?
    var kind: String
    var source: String
    var role: String
    /// Out of date (superseded by something newer).
    var past: Bool

    init(json: JSONObject) {
        id = MoreJSON.text(json["id"])
        body = MoreJSON.text(json["body"])
        createdAt = RelativeTime.parse(json["created_at"])
        eventStart = RelativeTime.parse(json["event_start"])
        kind = MoreJSON.text(json["kind"])
        source = MoreJSON.text(json["source"])
        role = MoreJSON.text(json["role"])
        past = MoreJSON.isTrue(json["past"])
    }

    /// The source family in plain English ("imessage:chat" → "iMessage").
    var sourceLabel: String { MemorySourceFilter.label(forSource: source) }

    /// When it happened if it is an event, else when it was saved.
    var when: Date? { eventStart ?? createdAt }
}

struct MemoryEntityNeighbor: Identifiable, Equatable, Sendable {
    var id: String
    var label: String
    var type: String
    var weight: Int

    init(id: String, label: String, type: String, weight: Int) {
        self.id = id
        self.label = label
        self.type = type
        self.weight = weight
    }

    init(json: JSONObject) {
        self.init(id: MoreJSON.text(json["id"]), label: MoreJSON.text(json["label"]),
                  type: MoreJSON.text(json["type"]), weight: MoreJSON.int(json["weight"]))
    }

    var kind: MemoryEntityKind { MemoryEntityKind(wire: type) }
}

/// `GET entity?id=`.
struct MemoryEntityDetail: Equatable, Sendable {
    var entity: MemoryEntity
    var memories: [MemoryEntityMemory]
    var neighbors: [MemoryEntityNeighbor]

    init(json: JSONObject) {
        entity = MemoryEntity(json: MoreJSON.map(json["entity"]))
        // The server sends newest first; sorted again so the sheet never depends on it.
        let rows = MoreJSON.mapList(json["memories"]).map(MemoryEntityMemory.init(json:)).filter { !$0.id.isEmpty }
        memories = rows.enumerated().sorted { l, r in
            let a = l.element.createdAt ?? .distantPast, b = r.element.createdAt ?? .distantPast
            return a != b ? a > b : l.offset < r.offset
        }.map(\.element)
        neighbors = MoreJSON.mapList(json["neighbors"]).map(MemoryEntityNeighbor.init(json:)).filter { !$0.id.isEmpty }
    }
}

// MARK: - Recalls

/// One turn where recall injected memories: "why did Jarvis know that".
struct MemoryRecall: Identifiable, Equatable, Sendable {
    var id: String
    var ts: Date?
    var sessionID: String
    var query: String
    var memoryIDs: [String]
    var entityIDs: [String]
    var ms: Int?

    init(id: String, ts: Date? = nil, sessionID: String = "", query: String,
         memoryIDs: [String] = [], entityIDs: [String] = [], ms: Int? = nil) {
        self.id = id
        self.ts = ts
        self.sessionID = sessionID
        self.query = query
        self.memoryIDs = memoryIDs
        self.entityIDs = entityIDs
        self.ms = ms
    }

    init(json: JSONObject) {
        id = MoreJSON.text(json["id"])
        ts = RelativeTime.parse(json["ts"])
        sessionID = MoreJSON.text(json["session_id"])
        query = MoreJSON.text(json["query"])
        memoryIDs = MoreJSON.stringList(json["memory_ids"])
        entityIDs = MoreJSON.stringList(json["entity_ids"])
        ms = MoreJSON.double(json["ms"]).map { Int($0) }
    }

    /// `{recalls:[…]}`; anything else (an old server, `available:false`) is none.
    static func list(_ json: JSONObject) -> [MemoryRecall] {
        MoreJSON.mapList(json["recalls"]).map(MemoryRecall.init(json:)).filter { !$0.id.isEmpty }
    }

    /// The question as the user typed it, without a rules block.
    var title: String {
        let q = MemoryRecallMatch.normalize(query)
        return q.isEmpty ? "A Jarvis reply" : q
    }
}

/// One transcript message, as the chip matching needs it. Assistant turns
/// carry no text (only user messages are compared).
struct MemoryRecallTurn: Equatable, Sendable {
    var isUser: Bool
    var text: String
    /// When it was said, if known (a stored message has its timestamp).
    var time: Date?

    init(isUser: Bool, text: String, time: Date? = nil) {
        self.isUser = isUser
        self.text = text
        self.time = time
    }
}

/// Which Jarvis replies get the "memories used" chip.
enum MemoryRecallMatch {
    /// The server's `strip_injected`: a bracketed block of 40+ characters ending
    /// "]" then a blank line (it may hold its own brackets), however many lead.
    private static let injected = try! NSRegularExpression(
        pattern: #"\A\s*\[.{40,}?\]\s*\n\s*\n"#, options: [.dotMatchesLineSeparators])

    /// A recall is logged just after the question is sent; this much clock skew
    /// between the phone's message time and the server's is tolerated.
    static let skew: TimeInterval = 120

    /// His own words: leading instruction blocks dropped, then trimmed.
    static func normalize(_ text: String) -> String {
        var s = text
        while let m = injected.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let range = Range(m.range, in: s) {
            s = String(s[range.upperBound...])
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Assistant row index → the recall behind it. The chip goes under the LAST
    /// assistant message of a turn (a turn can be several). A question asked more
    /// than once pairs by time — each recall goes to the latest matching question
    /// sent before it — and, without times, oldest-first in order.
    static func chips(turns: [MemoryRecallTurn], recalls: [MemoryRecall]) -> [Int: MemoryRecall] {
        guard !recalls.isEmpty, !turns.isEmpty else { return [:] }
        // Each question: its normalized text, when, and the reply row its chip goes on.
        struct Question { let text: String; let time: Date?; let reply: Int }
        var questions: [Question] = []
        var open: (text: String, time: Date?)?
        for (index, turn) in turns.enumerated() {
            if turn.isUser {
                open = (normalize(turn.text), turn.time)
                continue
            }
            let lastOfTurn = index + 1 >= turns.count || turns[index + 1].isUser
            if lastOfTurn, let q = open, !q.text.isEmpty {
                questions.append(Question(text: q.text, time: q.time, reply: index))
                open = nil
            }
        }
        guard !questions.isEmpty else { return [:] }
        var out: [Int: MemoryRecall] = [:]
        var used = Set<Int>()   // indexes into `questions`
        // Oldest recall first, so in-order pairing stays stable.
        for recall in recalls.reversed() {
            let key = normalize(recall.query)
            guard !key.isEmpty else { continue }
            let candidates = questions.indices.filter { questions[$0].text == key && !used.contains($0) }
            guard !candidates.isEmpty else { continue }
            var pick = candidates[0]
            if let ts = recall.ts, candidates.contains(where: { questions[$0].time != nil }) {
                // The latest stored question sent before the recall; a question
                // with no time yet (sent this visit) is newer than every stored one.
                let before = candidates.filter {
                    guard let t = questions[$0].time else { return false }
                    return t <= ts.addingTimeInterval(skew)
                }
                if let latest = before.last {
                    pick = latest
                } else if let fresh = candidates.first(where: { questions[$0].time == nil }) {
                    pick = fresh
                } else {
                    continue   // every matching question came after it
                }
            }
            used.insert(pick)
            out[questions[pick].reply] = recall
        }
        return out
    }
}

// MARK: - Filters

enum MemoryTimeRange: String, CaseIterable, Identifiable, Sendable {
    case week, month, year, all
    var id: String { rawValue }

    var label: String {
        switch self {
        case .week: return "Week"
        case .month: return "Month"
        case .year: return "Year"
        case .all: return "All time"
        }
    }

    var days: Int? {
        switch self {
        case .week: return 7
        case .month: return 30
        case .year: return 365
        case .all: return nil
        }
    }
}

enum MemorySourceFilter: String, CaseIterable, Identifiable, Sendable {
    case all, imessage, live, chats, calendar, email, health, location, integrations, dashcam, saved
    var id: String { rawValue }

    /// The server's source family prefix; nil = every source.
    var family: String? {
        switch self {
        case .all: return nil
        case .chats: return "fact"
        case .integrations: return "cron"
        case .saved: return "tool"
        default: return rawValue
        }
    }

    var label: String {
        switch self {
        case .all: return "All sources"
        case .imessage: return "iMessage"
        case .live: return "Live"
        case .chats: return "Chats"
        case .calendar: return "Calendar"
        case .email: return "Email"
        case .health: return "Health"
        case .location: return "Location"
        case .integrations: return "Integrations"
        case .dashcam: return "Dashcam"
        case .saved: return "Saved"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "square.stack"
        case .imessage: return "message"
        case .live: return "waveform"
        case .chats: return "bubble.left.and.bubble.right"
        case .calendar: return "calendar"
        case .email: return "envelope"
        case .health: return "heart"
        case .location: return "location"
        case .integrations: return "puzzlepiece"
        case .dashcam: return "car"
        case .saved: return "bookmark"
        }
    }

    /// A memory's raw source ("imessage:chat:…", "fact", "cron:job") in plain English.
    static func label(forSource source: String) -> String {
        let family = source.split(separator: ":").first.map(String.init)?.lowercased() ?? ""
        if family.isEmpty { return "" }
        if family == "builtin" { return "Built-in" }
        return allCases.first { $0.family == family }?.label ?? family
    }
}

struct MemoryGraphFilters: Equatable, Sendable {
    static let limit = 40

    var types: Set<MemoryEntityKind> = Set(MemoryEntityKind.filterable)
    var time: MemoryTimeRange = .all
    var source: MemorySourceFilter = .all

    var isDefault: Bool { self == MemoryGraphFilters() }

    /// Flip one type chip; the last one on stays on (an empty map helps no one).
    mutating func toggle(_ kind: MemoryEntityKind) {
        if types.contains(kind) {
            if types.count > 1 { types.remove(kind) }
        } else {
            types.insert(kind)
        }
    }

    func query(center: String, limit: Int = MemoryGraphFilters.limit, now: Date = Date()) -> [String: String] {
        var q = ["center": center, "limit": String(limit)]
        let chosen = MemoryEntityKind.filterable.filter(types.contains)
        if chosen.count < MemoryEntityKind.filterable.count, !chosen.isEmpty {
            q["types"] = chosen.map(\.rawValue).joined(separator: ",")
        }
        if let days = time.days {
            q["since"] = String(Int(now.timeIntervalSince1970) - days * 86_400)
        }
        if let family = source.family { q["source"] = family }
        return q
    }
}

// MARK: - The graph on the canvas

/// Nodes and edges as the canvas holds them, across reloads, expansions and
/// fixes. A value type so every rule is testable without a view.
struct MemoryGraph: Equatable, Sendable {
    static let meID = "me"
    /// The most nodes the phone draws after expansions (You included).
    static let cap = 80

    private(set) var nodeIDs: [String] = []
    private var nodesByID: [String: MemoryGraphNode] = [:]
    private var edgesByKey: [MemoryEdgeKey: MemoryGraphEdge] = [:]
    private var edgeOrder: [MemoryEdgeKey] = []
    /// Nodes whose neighbours were merged in; never dropped by the cap.
    private(set) var expanded: Set<String> = []
    /// Entity ids a recall lit up; everything else dims.
    private(set) var highlight: Set<String> = []

    init() {}

    var nodes: [MemoryGraphNode] { nodeIDs.compactMap { nodesByID[$0] } }
    var edges: [MemoryGraphEdge] { edgeOrder.compactMap { edgesByKey[$0] } }
    var isEmpty: Bool { nodeIDs.count <= 1 }
    var maxWeight: Int { nodesByID.values.filter { $0.id != Self.meID }.map(\.weight).max() ?? 0 }

    func node(_ id: String) -> MemoryGraphNode? { nodesByID[id] }
    func edge(_ a: String, _ b: String) -> MemoryGraphEdge? { edgesByKey[MemoryEdgeKey(a, b)] }

    /// Neighbours of one node on the canvas.
    func neighbors(of id: String) -> [String] {
        edges.compactMap { $0.a == id ? $0.b : ($0.b == id ? $0.a : nil) }
    }

    /// A fresh view: You plus the payload.
    mutating func replace(with payload: MemoryGraphPayload) {
        self = MemoryGraph()
        insert(MemoryGraphNode(id: Self.meID, label: "You", type: "me", weight: 0))
        if payload.center.id != Self.meID {
            insert(centerNode(payload.center, payload: payload))
            expanded.insert(payload.center.id)
        }
        for node in payload.nodes { insert(node) }
        for edge in payload.edges { addEdge(edge) }
        highlight = Set(payload.highlight).intersection(nodesByID.keys)
        enforceCap(keeping: [])
    }

    /// Expand in place: new nodes and edges join, existing ones keep their data
    /// (and the stronger weight). Answers the ids that are new on the canvas.
    @discardableResult
    mutating func merge(_ payload: MemoryGraphPayload) -> [String] {
        var added: [String] = []
        let centerID = payload.center.id
        if nodesByID[centerID] == nil {
            insert(centerNode(payload.center, payload: payload))
            added.append(centerID)
        }
        if centerID != Self.meID { expanded.insert(centerID) }
        for node in payload.nodes {
            if var existing = nodesByID[node.id] {
                existing.weight = max(existing.weight, node.weight)
                if existing.label.isEmpty { existing.label = node.label }
                nodesByID[node.id] = existing
            } else {
                insert(node)
                added.append(node.id)
            }
        }
        for edge in payload.edges { addEdge(edge) }
        enforceCap(keeping: Set(payload.nodes.map(\.id)).union([centerID]))
        return added.filter { nodesByID[$0] != nil }
    }

    /// `from` was merged into `into` on the server: `from` goes, its edges move
    /// to `into` (self-loops dropped, doubled edges folded together).
    /// `survivor` names `into` when it isn't on the canvas yet.
    mutating func mergeNode(_ from: String, into: String, survivor: MemoryEntity? = nil) {
        guard from != into, let gone = nodesByID[from] else { return }
        if var target = nodesByID[into] {
            target.weight += gone.weight
            target.pinned = target.pinned || gone.pinned
            if let survivor { apply(survivor, to: &target) }
            nodesByID[into] = target
        } else {
            var target = gone
            target.id = into
            if let survivor { apply(survivor, to: &target) }
            nodesByID[into] = target
            if let index = nodeIDs.firstIndex(of: from) { nodeIDs.insert(into, at: index) }
        }
        let moving = edges.filter { $0.a == from || $0.b == from }
        for edge in moving { removeEdge(edge.key) }
        for edge in moving {
            let other = edge.a == from ? edge.b : edge.a
            guard other != into else { continue }
            let key = MemoryEdgeKey(into, other)
            if var existing = edgesByKey[key] {
                existing.weight += edge.weight
                edgesByKey[key] = existing
            } else {
                edgesByKey[key] = MemoryGraphEdge(a: edge.a == from ? into : edge.a,
                                                  b: edge.b == from ? into : edge.b, weight: edge.weight)
                edgeOrder.append(key)
            }
        }
        nodesByID[from] = nil
        nodeIDs.removeAll { $0 == from }
        if expanded.remove(from) != nil { expanded.insert(into) }
        if highlight.remove(from) != nil { highlight.insert(into) }
    }

    /// A rename, pin or alias change saved on the server.
    mutating func update(_ entity: MemoryEntity) {
        guard var node = nodesByID[entity.id] else { return }
        apply(entity, to: &node)
        nodesByID[entity.id] = node
    }

    mutating func clearHighlight() { highlight = [] }

    /// One memory no longer links to `id`.
    mutating func memoryUnlinked(from id: String) {
        guard var node = nodesByID[id] else { return }
        node.weight = max(0, node.weight - 1)
        nodesByID[id] = node
        let key = MemoryEdgeKey(Self.meID, id)
        if var edge = edgesByKey[key] {
            edge.weight = max(0, edge.weight - 1)
            edgesByKey[key] = edge
        }
    }

    // MARK: Internals

    private func apply(_ entity: MemoryEntity, to node: inout MemoryGraphNode) {
        if !entity.label.isEmpty { node.label = entity.label }
        if !entity.type.isEmpty { node.type = entity.type }
        node.pinned = entity.pinned
    }

    private func centerNode(_ center: MemoryGraphCenter, payload: MemoryGraphPayload) -> MemoryGraphNode {
        // The expand payload doesn't weigh its center; its strongest link is a fair stand-in.
        let weight = payload.edges.filter { $0.a == center.id || $0.b == center.id }.map(\.weight).max() ?? 1
        return MemoryGraphNode(id: center.id, label: center.label, type: center.type, weight: weight)
    }

    private mutating func insert(_ node: MemoryGraphNode) {
        guard nodesByID[node.id] == nil else { return }
        nodesByID[node.id] = node
        nodeIDs.append(node.id)
    }

    private mutating func addEdge(_ edge: MemoryGraphEdge) {
        guard edge.a != edge.b, nodesByID[edge.a] != nil, nodesByID[edge.b] != nil else { return }
        let key = edge.key
        if var existing = edgesByKey[key] {
            existing.weight = max(existing.weight, edge.weight)
            edgesByKey[key] = existing
        } else {
            edgesByKey[key] = edge
            edgeOrder.append(key)
        }
    }

    private mutating func removeEdge(_ key: MemoryEdgeKey) {
        edgesByKey[key] = nil
        edgeOrder.removeAll { $0 == key }
    }

    /// Over the cap, the lightest nodes go first — never You, an expanded node, a
    /// lit one, or (while anything else can go) what just came into view.
    private mutating func enforceCap(keeping fresh: Set<String>) {
        let over = nodeIDs.count - Self.cap
        guard over > 0 else { return }
        let protected = expanded.union(highlight).union([Self.meID])
        func lightest(_ ids: [String]) -> [String] {
            ids.enumerated().sorted { l, r in
                let a = nodesByID[l.element]?.weight ?? 0, b = nodesByID[r.element]?.weight ?? 0
                return a != b ? a < b : l.offset > r.offset   // equal weight: the newest-listed first
            }.map(\.element)
        }
        let old = lightest(nodeIDs.filter { !protected.contains($0) && !fresh.contains($0) })
        let new = lightest(nodeIDs.filter { !protected.contains($0) && fresh.contains($0) })
        let drop = Set((old + new).prefix(over))
        nodeIDs.removeAll { drop.contains($0) }
        for id in drop { nodesByID[id] = nil }
        for key in edgeOrder where drop.contains(key.lo) || drop.contains(key.hi) { edgesByKey[key] = nil }
        edgeOrder.removeAll { edgesByKey[$0] == nil }
    }
}

/// The "Merge into…" list: same-type nodes on the canvas plus the entity's
/// neighbours, itself excluded, filtered by a search.
enum MemoryMergeTargets {
    struct Target: Identifiable, Equatable {
        var id: String
        var label: String
        var weight: Int
    }

    static func list(for id: String, kind: MemoryEntityKind, graph: MemoryGraph,
                     neighbors: [MemoryEntityNeighbor], search: String) -> [Target] {
        var seen: Set<String> = [id, MemoryGraph.meID]
        var out: [Target] = []
        for node in graph.nodes where node.kind == kind && seen.insert(node.id).inserted {
            out.append(Target(id: node.id, label: node.label, weight: node.weight))
        }
        for n in neighbors where n.kind == kind && seen.insert(n.id).inserted {
            out.append(Target(id: n.id, label: n.label, weight: n.weight))
        }
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty { out = out.filter { $0.label.localizedCaseInsensitiveContains(q) } }
        return out
    }
}

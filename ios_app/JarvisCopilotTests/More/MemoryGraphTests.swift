import Foundation
import XCTest
@testable import JarvisCopilot

/// The memory map screen: response shapes, filters → query, the graph merge
/// rules, the force layout, and the store against a mocked server.
@MainActor
final class MemoryGraphTests: XCTestCase {

    // MARK: Fixtures

    private static let graphJSON: JSONObject = [
        "center": ["id": "me", "label": "You", "type": "me"],
        "nodes": [
            ["id": "e1", "label": "Sam", "type": "person", "weight": 12, "pinned": true, "event_start": NSNull()],
            ["id": "e2", "label": "Leeds", "type": "place", "weight": 4, "pinned": false,
             "event_start": NSNull()],
            ["id": "e3", "label": "Sam's birthday", "type": "event", "weight": 2, "pinned": false,
             "event_start": 1_790_000_000],
        ],
        "edges": [
            ["a": "me", "b": "e1", "weight": 12],
            ["a": "me", "b": "e2", "weight": 4],
            ["a": "me", "b": "e3", "weight": 2],
            ["a": "e1", "b": "e3", "weight": 2],
        ],
    ]

    private static func node(_ id: String, _ weight: Int, type: String = "person") -> JSONObject {
        ["id": id, "label": id.uppercased(), "type": type, "weight": weight, "pinned": false]
    }

    /// `center=me` with `count` nodes n0…, weights count…1.
    private static func meGraph(_ count: Int, prefix: String = "n") -> MemoryGraphPayload {
        let nodes = (0..<count).map { node("\(prefix)\($0)", count - $0) }
        let edges: [JSONObject] = (0..<count).map { ["a": "me", "b": "\(prefix)\($0)", "weight": count - $0] }
        return MemoryGraphPayload(json: ["center": ["id": "me", "label": "You", "type": "me"],
                                         "nodes": nodes, "edges": edges])
    }

    /// An expansion of `center` with `count` fresh neighbours.
    private static func expansion(of center: String, label: String = "X", count: Int,
                                  prefix: String, weight: Int = 1) -> MemoryGraphPayload {
        let nodes = (0..<count).map { node("\(prefix)\($0)", weight) }
        let edges: [JSONObject] = (0..<count).map { ["a": center, "b": "\(prefix)\($0)", "weight": weight] }
        return MemoryGraphPayload(json: ["center": ["id": center, "label": label, "type": "person"],
                                         "nodes": nodes, "edges": edges])
    }

    // MARK: Decoding

    func testTheGraphPayloadDecodes() throws {
        let payload = MemoryGraphPayload(json: Self.graphJSON)
        XCTAssertEqual(payload.center, MemoryGraphCenter(id: "me", label: "You", type: "me"))
        XCTAssertEqual(payload.nodes.map(\.id), ["e1", "e2", "e3"])
        let sam = try XCTUnwrap(payload.nodes.first)
        XCTAssertEqual(sam.label, "Sam")
        XCTAssertEqual(sam.kind, .person)
        XCTAssertEqual(sam.weight, 12)
        XCTAssertTrue(sam.pinned)
        XCTAssertNil(sam.eventStart)
        XCTAssertEqual(payload.nodes[2].eventStart, Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(payload.edges.count, 4)
        XCTAssertEqual(payload.edges[3], MemoryGraphEdge(a: "e1", b: "e3", weight: 2))
        XCTAssertTrue(payload.highlight.isEmpty)
    }

    func testTheHighlightPayloadCarriesItsEntityIDs() {
        var json = Self.graphJSON
        json["highlight"] = ["e1", "e3"]
        XCTAssertEqual(MemoryGraphPayload(json: json).highlight, ["e1", "e3"])
    }

    func testAMalformedGraphPayloadIsEmptyNotACrash() {
        let payload = MemoryGraphPayload(json: ["nodes": "nope", "edges": [["a": "x"]], "center": NSNull()])
        XCTAssertEqual(payload.center.id, "me", "no center = the You view")
        XCTAssertTrue(payload.nodes.isEmpty)
        XCTAssertTrue(payload.edges.isEmpty, "an edge needs both ends")
    }

    func testNumericEntityIDsReadAsStrings() {
        let payload = MemoryGraphPayload(json: [
            "center": ["id": 7, "label": "Sam", "type": "person"],
            "nodes": [["id": 9, "label": "Leeds", "type": "place", "weight": "3"]],
            "edges": [["a": 7, "b": 9, "weight": 3]],
        ])
        XCTAssertEqual(payload.center.id, "7")
        XCTAssertEqual(payload.nodes.first?.id, "9")
        XCTAssertEqual(payload.nodes.first?.weight, 3)
        XCTAssertEqual(payload.edges.first, MemoryGraphEdge(a: "7", b: "9", weight: 3))
    }

    func testTheEntityDetailDecodesNewestFirst() throws {
        let detail = MemoryEntityDetail(json: [
            "entity": ["id": "e1", "type": "person", "label": "Sam", "aliases": ["Sammy", "S"],
                       "pinned": true, "event_start": NSNull(), "event_end": NSNull(), "summary": "A friend"],
            "memories": [
                ["id": "m1", "body": "Old", "created_at": 1_700_000_000, "event_start": NSNull(),
                 "kind": "fact", "source": "imessage:chat", "role": "subject", "past": true],
                ["id": "m2", "body": "New", "created_at": 1_790_000_000, "event_start": 1_790_100_000,
                 "kind": "event", "source": "live", "role": "", "past": false],
            ],
            "neighbors": [["id": "e2", "label": "Leeds", "type": "place", "weight": 3]],
        ])
        XCTAssertEqual(detail.entity.id, "e1")
        XCTAssertEqual(detail.entity.label, "Sam")
        XCTAssertEqual(detail.entity.kind, .person)
        XCTAssertEqual(detail.entity.aliases, ["Sammy", "S"])
        XCTAssertTrue(detail.entity.pinned)
        XCTAssertEqual(detail.entity.summary, "A friend")
        XCTAssertEqual(detail.memories.map(\.id), ["m2", "m1"], "newest first")
        let old = try XCTUnwrap(detail.memories.last)
        XCTAssertTrue(old.past)
        XCTAssertEqual(old.source, "imessage:chat")
        XCTAssertEqual(old.sourceLabel, "iMessage")
        XCTAssertEqual(old.role, "subject")
        XCTAssertEqual(detail.memories.first?.eventStart, Date(timeIntervalSince1970: 1_790_100_000))
        XCTAssertEqual(detail.neighbors, [MemoryEntityNeighbor(id: "e2", label: "Leeds", type: "place", weight: 3)])
    }

    func testTheRecallsDecode() throws {
        let recalls = MemoryRecall.list([
            "recalls": [
                ["id": 12, "ts": 1_790_000_000.5, "session_id": "s1", "query": "What did Sam say?",
                 "memory_ids": ["m1", "m2"], "entity_ids": ["e1"], "ms": 84],
                ["id": 11, "ts": 1_789_000_000, "session_id": "s2", "query": "Leeds?",
                 "memory_ids": [], "entity_ids": NSNull(), "ms": NSNull()],
            ],
        ])
        XCTAssertEqual(recalls.map(\.id), ["12", "11"])
        let first = try XCTUnwrap(recalls.first)
        XCTAssertEqual(first.sessionID, "s1")
        XCTAssertEqual(first.query, "What did Sam say?")
        XCTAssertEqual(first.memoryIDs, ["m1", "m2"])
        XCTAssertEqual(first.entityIDs, ["e1"])
        XCTAssertEqual(first.ms, 84)
        XCTAssertEqual(first.ts?.timeIntervalSince1970 ?? 0, 1_790_000_000.5, accuracy: 0.01)
        XCTAssertEqual(recalls[1].entityIDs, [])
        XCTAssertNil(recalls[1].ms)
        XCTAssertTrue(MemoryRecall.list(["available": false]).isEmpty)
    }

    func testTheEntityResponsesDecode() {
        let entity = MemoryEntity(json: ["id": "e1", "type": "org", "label": "Acme", "aliases": NSNull()])
        XCTAssertEqual(entity.kind, .org)
        XCTAssertEqual(entity.aliases, [])
        XCTAssertFalse(entity.pinned)
    }

    // MARK: Filters → query

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testDefaultFiltersAskForEverything() {
        let q = MemoryGraphFilters().query(center: "me", now: now)
        XCTAssertEqual(q, ["center": "me", "limit": "40"])
    }

    func testTypeChipsBecomeAStableCommaList() {
        var f = MemoryGraphFilters()
        f.types = [.event, .person]
        XCTAssertEqual(f.query(center: "me", now: now)["types"], "person,event")
        f.toggle(.topic)
        XCTAssertEqual(f.query(center: "me", now: now)["types"], "person,event,topic")
    }

    func testTheLastTypeChipCannotBeTurnedOff() {
        var f = MemoryGraphFilters()
        f.types = [.place]
        f.toggle(.place)
        XCTAssertEqual(f.types, [.place])
    }

    func testTimeMenuSetsSince() {
        var f = MemoryGraphFilters()
        let day = 86_400
        for (range, days) in [(MemoryTimeRange.week, 7), (.month, 30), (.year, 365)] {
            f.time = range
            XCTAssertEqual(f.query(center: "me", now: now)["since"], String(1_800_000_000 - days * day))
        }
        f.time = .all
        XCTAssertNil(f.query(center: "me", now: now)["since"])
    }

    func testSourceMenuUsesTheServersFamilies() {
        let expected: [MemorySourceFilter: String?] = [
            .all: nil, .imessage: "imessage", .live: "live", .chats: "fact", .calendar: "calendar",
            .email: "email", .health: "health", .location: "location", .integrations: "cron",
            .dashcam: "dashcam", .saved: "tool",
        ]
        XCTAssertEqual(Set(MemorySourceFilter.allCases), Set(expected.keys))
        for (source, family) in expected {
            var f = MemoryGraphFilters()
            f.source = source
            XCTAssertEqual(f.query(center: "e9", now: now)["source"], family, "\(source)")
            XCTAssertEqual(f.query(center: "e9", now: now)["center"], "e9")
        }
    }

    // MARK: Graph merging

    func testAFreshGraphHasYouPlusItsNodes() {
        var graph = MemoryGraph()
        graph.replace(with: MemoryGraphPayload(json: Self.graphJSON))
        XCTAssertEqual(graph.nodeIDs.first, "me")
        XCTAssertEqual(Set(graph.nodeIDs), ["me", "e1", "e2", "e3"])
        XCTAssertEqual(graph.node("me")?.kind, .me)
        XCTAssertEqual(graph.node("me")?.label, "You")
        XCTAssertEqual(graph.edges.count, 4)
    }

    func testExpandMergesWithoutDuplicates() {
        var graph = MemoryGraph()
        graph.replace(with: MemoryGraphPayload(json: Self.graphJSON))
        let expand = MemoryGraphPayload(json: [
            "center": ["id": "e1", "label": "Sam", "type": "person"],
            "nodes": [Self.node("e2", 3, type: "place"), Self.node("e4", 2)],
            "edges": [
                ["a": "e1", "b": "e2", "weight": 3],
                ["a": "e1", "b": "e4", "weight": 2],
                ["a": "e3", "b": "e1", "weight": 5],   // the e1–e3 edge, written the other way round
            ],
        ])
        let added = graph.merge(expand)
        XCTAssertEqual(added, ["e4"])
        XCTAssertEqual(graph.nodeIDs.filter { $0 == "e2" }.count, 1)
        XCTAssertEqual(Set(graph.nodeIDs), ["me", "e1", "e2", "e3", "e4"])
        XCTAssertEqual(graph.node("e2")?.label, "Leeds", "an existing node keeps its data")
        XCTAssertEqual(graph.node("e2")?.weight, 4, "and the larger weight")
        XCTAssertEqual(graph.edges.count, 6, "me–e1, me–e2, me–e3, e1–e3, e1–e2, e1–e4")
        XCTAssertEqual(graph.edge("e1", "e3")?.weight, 5, "one edge per pair, the stronger weight")
        XCTAssertTrue(graph.expanded.contains("e1"))
    }

    func testExpandingANodeNotOnTheCanvasAddsIt() {
        var graph = MemoryGraph()
        graph.replace(with: MemoryGraphPayload(json: Self.graphJSON))
        let added = graph.merge(Self.expansion(of: "zz", label: "Zed", count: 2, prefix: "q"))
        XCTAssertEqual(Set(added), ["zz", "q0", "q1"])
        XCTAssertEqual(graph.node("zz")?.label, "Zed")
    }

    func testMergeIntoRemovesFromAndRepointsItsEdges() {
        var graph = MemoryGraph()
        graph.replace(with: MemoryGraphPayload(json: Self.graphJSON))
        _ = graph.merge(MemoryGraphPayload(json: [
            "center": ["id": "e3", "label": "Sam's birthday", "type": "event"],
            "nodes": [Self.node("e5", 1)],
            "edges": [["a": "e3", "b": "e5", "weight": 1]],
        ]))
        // e3 merges into e1: me–e3 and me–e1 fold together, e1–e3 would be a
        // self-loop and goes, e3–e5 becomes e1–e5.
        graph.mergeNode("e3", into: "e1")
        XCTAssertNil(graph.node("e3"))
        XCTAssertFalse(graph.edges.contains { $0.a == "e3" || $0.b == "e3" })
        XCTAssertNil(graph.edge("e1", "e1"))
        XCTAssertNotNil(graph.edge("e1", "e5"))
        XCTAssertEqual(graph.edge("me", "e1")?.weight, 14, "both edges to You fold into one")
        XCTAssertEqual(graph.node("e1")?.weight, 14)
        XCTAssertEqual(graph.edges.filter { Set([$0.a, $0.b]) == ["me", "e1"] }.count, 1)
    }

    func testMergeIntoAnEntityOffTheCanvasRenamesItInPlace() {
        var graph = MemoryGraph()
        graph.replace(with: MemoryGraphPayload(json: Self.graphJSON))
        graph.mergeNode("e2", into: "e9", survivor: MemoryEntity(json: ["id": "e9", "type": "place",
                                                                       "label": "Leeds, UK"]))
        XCTAssertNil(graph.node("e2"))
        XCTAssertEqual(graph.node("e9")?.label, "Leeds, UK")
        XCTAssertNotNil(graph.edge("me", "e9"))
    }

    func testTheGraphIsCappedAtEighty() {
        var graph = MemoryGraph()
        graph.replace(with: Self.meGraph(40))
        XCTAssertEqual(graph.nodeIDs.count, 41)
        _ = graph.merge(Self.expansion(of: "n0", count: 40, prefix: "a", weight: 50))
        XCTAssertLessThanOrEqual(graph.nodeIDs.count, MemoryGraph.cap)
        _ = graph.merge(Self.expansion(of: "a0", count: 40, prefix: "b", weight: 60))
        XCTAssertEqual(graph.nodeIDs.count, MemoryGraph.cap)
        XCTAssertNotNil(graph.node("me"), "You always stays")
        XCTAssertNotNil(graph.node("n0"), "expanded nodes stay")
        XCTAssertNotNil(graph.node("a0"), "expanded nodes stay")
        XCTAssertNotNil(graph.node("b39"), "what was just expanded into view stays")
        XCTAssertNil(graph.node("n39"), "the lightest non-expanded node went first")
        let ids = Set(graph.nodeIDs)
        XCTAssertTrue(graph.edges.allSatisfy { ids.contains($0.a) && ids.contains($0.b) },
                      "no edge points at a dropped node")
    }

    func testHighlightIsKept() {
        var graph = MemoryGraph()
        var json = Self.graphJSON
        json["highlight"] = ["e1", "e3"]
        graph.replace(with: MemoryGraphPayload(json: json))
        XCTAssertEqual(graph.highlight, ["e1", "e3"])
        graph.mergeNode("e3", into: "e1")
        XCTAssertEqual(graph.highlight, ["e1"])
    }

    // MARK: Layout

    private func fortyNodeGraph() -> MemoryGraph {
        var graph = MemoryGraph()
        var payload = Self.meGraph(39)
        // Some cross links so it is not a plain star.
        for i in stride(from: 0, to: 36, by: 3) {
            payload.edges.append(MemoryGraphEdge(a: "n\(i)", b: "n\(i + 1)", weight: 2))
            payload.edges.append(MemoryGraphEdge(a: "n\(i)", b: "n\(i + 2)", weight: 1))
        }
        graph.replace(with: payload)
        return graph
    }

    func testTheLayoutSettlesWithYouAtTheCenter() {
        let graph = fortyNodeGraph()
        XCTAssertEqual(graph.nodeIDs.count, 40)
        var sim = MemoryGraphSimulation()
        sim.sync(with: graph)
        var energy = Double.infinity
        var steps = 0
        while steps < MemoryGraphSimulation.maxSteps, !sim.isSettled {
            energy = sim.step()
            steps += 1
            XCTAssertEqual(sim.position("me"), .zero, "You never moves")
        }
        XCTAssertTrue(sim.isSettled, "settled within \(MemoryGraphSimulation.maxSteps) steps")
        XCTAssertLessThan(energy, MemoryGraphSimulation.settleEnergy)
        XCTAssertLessThan(sim.kineticEnergy, MemoryGraphSimulation.settleEnergy)
        // It spread out: nobody sits on top of You.
        for id in graph.nodeIDs where id != "me" {
            let p = sim.position(id) ?? .zero
            XCTAssertGreaterThan((p.x * p.x + p.y * p.y).squareRoot(), 20, id)
            XCTAssertTrue(p.x.isFinite && p.y.isFinite)
        }
    }

    func testASettledLayoutStopsStepping() {
        var sim = MemoryGraphSimulation()
        sim.sync(with: fortyNodeGraph())
        sim.run(steps: MemoryGraphSimulation.maxSteps)
        XCTAssertTrue(sim.isSettled)
        let before = sim.position("n5")
        XCTAssertEqual(sim.step(), 0, "a settled layout does no work")
        XCTAssertEqual(sim.position("n5"), before)
    }

    func testExpandingKeepsExistingPositions() {
        var graph = fortyNodeGraph()
        var sim = MemoryGraphSimulation()
        sim.sync(with: graph)
        sim.run(steps: MemoryGraphSimulation.maxSteps)
        let before = sim.position("n3")
        _ = graph.merge(Self.expansion(of: "n3", count: 5, prefix: "x"))
        sim.sync(with: graph)
        XCTAssertEqual(sim.position("n3"), before, "a merge does not reset positions")
        XCTAssertFalse(sim.isSettled, "new nodes wake the layout")
        let p = sim.position("x0") ?? .zero
        let anchor = before ?? .zero
        XCTAssertLessThan(hypot(p.x - anchor.x, p.y - anchor.y), 80, "new nodes start beside what they hang off")
        sim.sync(with: graph)
        sim.run(steps: MemoryGraphSimulation.maxSteps)
        XCTAssertTrue(sim.isSettled)
        XCTAssertEqual(sim.position("me"), .zero)
    }

    func testRemovedNodesLeaveTheLayout() {
        var graph = fortyNodeGraph()
        var sim = MemoryGraphSimulation()
        sim.sync(with: graph)
        graph.mergeNode("n1", into: "n0")
        sim.sync(with: graph)
        XCTAssertNil(sim.position("n1"))
        XCTAssertNotNil(sim.position("n0"))
    }

    func testCoincidentNodesDoNotProduceNaN() {
        var graph = MemoryGraph()
        graph.replace(with: Self.meGraph(3))
        var sim = MemoryGraphSimulation()
        sim.sync(with: graph)
        sim.setPosition("n0", CGPoint(x: 10, y: 10))
        sim.setPosition("n1", CGPoint(x: 10, y: 10))
        sim.run(steps: 50)
        for id in graph.nodeIDs {
            let p = sim.position(id) ?? .zero
            XCTAssertTrue(p.x.isFinite && p.y.isFinite, id)
        }
    }

    func testHitTestingFindsTheNodeUnderAFinger() {
        var graph = MemoryGraph()
        graph.replace(with: Self.meGraph(3))
        var sim = MemoryGraphSimulation()
        sim.sync(with: graph)
        sim.setPosition("n0", CGPoint(x: 100, y: 0))
        sim.setPosition("n1", CGPoint(x: -100, y: 0))
        sim.setPosition("n2", CGPoint(x: 0, y: 100))
        let view = MemoryGraphViewport(size: CGSize(width: 400, height: 400), pan: .zero, zoom: 1)
        XCTAssertEqual(view.toWorld(CGPoint(x: 300, y: 200)), CGPoint(x: 100, y: 0))
        XCTAssertEqual(MemoryGraphHitTest.node(at: CGPoint(x: 302, y: 203), graph: graph, sim: sim,
                                               viewport: view), "n0")
        XCTAssertEqual(MemoryGraphHitTest.node(at: CGPoint(x: 200, y: 200), graph: graph, sim: sim,
                                               viewport: view), "me")
        XCTAssertNil(MemoryGraphHitTest.node(at: CGPoint(x: 380, y: 380), graph: graph, sim: sim,
                                             viewport: view))
        let zoomed = MemoryGraphViewport(size: CGSize(width: 400, height: 400), pan: CGSize(width: 10, height: 0),
                                         zoom: 2)
        XCTAssertEqual(zoomed.toWorld(CGPoint(x: 410, y: 200)), CGPoint(x: 100, y: 0))
        XCTAssertEqual(zoomed.toScreen(CGPoint(x: 100, y: 0)), CGPoint(x: 410, y: 200))
    }

    func testNodeRadiusGrowsWithTheSquareRootOfWeight() {
        let small = MemoryGraphStyle.radius(weight: 1, maxWeight: 100)
        let mid = MemoryGraphStyle.radius(weight: 25, maxWeight: 100)
        let big = MemoryGraphStyle.radius(weight: 100, maxWeight: 100)
        XCTAssertLessThan(small, mid)
        XCTAssertLessThan(mid, big)
        XCTAssertEqual((mid - MemoryGraphStyle.minRadius) / (big - MemoryGraphStyle.minRadius), 0.5,
                       accuracy: 0.001, "sqrt(25/100) = 0.5")
        XCTAssertEqual(MemoryGraphStyle.radius(weight: 0, maxWeight: 0), MemoryGraphStyle.minRadius)
    }

    // MARK: API

    func testTheGraphRequestCarriesTheFilters() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/jarvis-memory/graph", json: Self.graphJSON)
        var filters = MemoryGraphFilters()
        filters.types = [.person]
        filters.source = .imessage
        let payload = try await JarvisMemoryAPI(api: api).graph(center: "me", filters: filters, now: now)
        XCTAssertEqual(payload.nodes.count, 3)
        XCTAssertEqual(transport.lastMethod, "GET")
        XCTAssertEqual(transport.lastPath, "/api/jarvis-memory/graph")
        XCTAssertEqual(transport.lastQuery, ["center": "me", "limit": "40", "types": "person", "source": "imessage"])
    }

    func testTheEndpointsUseTheContract() async throws {
        let (api, transport) = JarvisAPI.mocked()
        let entity: JSONObject = ["id": "e1", "type": "person", "label": "Sam", "aliases": ["Sammy"], "pinned": true]
        transport.route("/api/jarvis-memory/graph/highlight", json: Self.graphJSON)
        transport.route("/api/jarvis-memory/entity/merge", json: ["ok": true, "entity": entity])
        transport.route("/api/jarvis-memory/entity/unlink", json: ["ok": true])
        transport.route("/api/jarvis-memory/entity", json: ["entity": entity, "memories": [], "neighbors": []])
        transport.route("/api/jarvis-memory/recalls", json: ["recalls": []])
        let memory = JarvisMemoryAPI(api: api)

        _ = try await memory.highlight(recallID: "12")
        XCTAssertEqual(transport.path(0), "/api/jarvis-memory/graph/highlight")
        XCTAssertEqual(transport.query(0), ["recall": "12"])

        _ = try await memory.entity("e1")
        XCTAssertEqual(transport.method(1), "GET")
        XCTAssertEqual(transport.path(1), "/api/jarvis-memory/entity")
        XCTAssertEqual(transport.query(1), ["id": "e1", "limit": "50"])

        let saved = try await memory.updateEntity("e1", label: "Samuel", aliases: ["Sam"], pinned: true)
        XCTAssertEqual(saved.label, "Sam")
        XCTAssertEqual(transport.method(2), "POST")
        XCTAssertEqual(transport.path(2), "/api/jarvis-memory/entity")
        assertJSONEqual(transport.body(2), ["id": "e1", "label": "Samuel", "aliases": ["Sam"], "pinned": true])

        _ = try await memory.updateEntity("e1", pinned: false)
        assertJSONEqual(transport.body(3), ["id": "e1", "pinned": false], "only what changed is sent")

        let survivor = try await memory.mergeEntity(from: "e3", into: "e1")
        XCTAssertEqual(survivor.id, "e1")
        XCTAssertEqual(transport.path(4), "/api/jarvis-memory/entity/merge")
        assertJSONEqual(transport.body(4), ["from": "e3", "into": "e1"])

        try await memory.unlink(memoryID: "m1", entityID: "e1")
        XCTAssertEqual(transport.path(5), "/api/jarvis-memory/entity/unlink")
        assertJSONEqual(transport.body(5), ["memory_id": "m1", "entity_id": "e1"])

        _ = try await memory.recalls(limit: 100, sessionID: "s1")
        XCTAssertEqual(transport.path(6), "/api/jarvis-memory/recalls")
        XCTAssertEqual(transport.query(6), ["limit": "100", "session_id": "s1"])
        _ = try await memory.recalls()
        XCTAssertEqual(transport.query(7), ["limit": "30"])
    }

    // MARK: Store

    func testTheStoreLoadsYouAtTheCenterAndReloadsOnAFilterChange() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/jarvis-memory/graph", json: Self.graphJSON)
        let store = MemoryGraphStore(api: JarvisMemoryAPI(api: api), now: { self.now })
        await store.load()
        XCTAssertEqual(Set(store.graph.nodeIDs), ["me", "e1", "e2", "e3"])
        XCTAssertEqual(transport.query(0)["center"], "me")
        XCTAssertFalse(store.isSettled, "a fresh graph has to lay out")

        var filters = store.filters
        filters.time = .week
        await store.setFilters(filters)
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(transport.query(1)["since"], String(1_800_000_000 - 7 * 86_400))
    }

    func testTheStoreExpandsInPlace() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/jarvis-memory/graph") { request in
            let center = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "center" }?.value
            let json: JSONObject = center == "me" ? Self.graphJSON : [
                "center": ["id": "e1", "label": "Sam", "type": "person"],
                "nodes": [Self.node("e7", 2)], "edges": [["a": "e1", "b": "e7", "weight": 2]],
            ]
            return MockTransport.Reply(body: try! JSONSerialization.data(withJSONObject: json))
        }
        let store = MemoryGraphStore(api: JarvisMemoryAPI(api: api), now: { self.now })
        await store.load()
        store.layout.run(steps: MemoryGraphSimulation.maxSteps)
        let samAt = store.layout.position("e1")
        await store.expand("e1")
        XCTAssertEqual(transport.query(1)["center"], "e1")
        XCTAssertNotNil(store.graph.node("e7"))
        XCTAssertEqual(store.layout.position("e1"), samAt)
        XCTAssertFalse(store.isSettled)
    }

    func testTheStoreShowsARecallHighlighted() async throws {
        let (api, transport) = JarvisAPI.mocked()
        var json = Self.graphJSON
        json["highlight"] = ["e1"]
        transport.route("/api/jarvis-memory/graph/highlight", json: json)
        let store = MemoryGraphStore(api: JarvisMemoryAPI(api: api), now: { self.now })
        await store.showRecall(MemoryRecall(id: "12", query: "Sam?"))
        XCTAssertEqual(transport.path(0), "/api/jarvis-memory/graph/highlight")
        XCTAssertEqual(transport.query(0), ["recall": "12"])
        XCTAssertEqual(store.graph.highlight, ["e1"])
        XCTAssertEqual(store.recall?.id, "12")
    }

    func testTheStoreMergesAndRenames() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/jarvis-memory/graph", json: Self.graphJSON)
        transport.route("/api/jarvis-memory/entity") { request in
            // Closure routes match by substring and win over JSON routes, so the
            // merge endpoint is answered here too.
            if request.url?.path == "/api/jarvis-memory/entity/merge" {
                let merged: JSONObject = ["ok": true, "entity": ["id": "e1", "type": "person", "label": "Sam"]]
                return MockTransport.Reply(body: try! JSONSerialization.data(withJSONObject: merged))
            }
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? JSONObject ?? [:]
            // Renaming e2 onto a name e9 already has merges it there.
            let entity: JSONObject = body["id"] as? String == "e2"
                ? ["id": "e9", "type": "place", "label": "Leeds"]
                : ["id": body["id"] ?? "", "type": "person", "label": body["label"] ?? "Sam",
                   "pinned": body["pinned"] ?? false]
            return MockTransport.Reply(body: try! JSONSerialization.data(withJSONObject: ["entity": entity]))
        }
        let store = MemoryGraphStore(api: JarvisMemoryAPI(api: api), now: { self.now })
        await store.load()

        let merged = await store.merge("e3", into: "e1")
        XCTAssertTrue(merged)
        XCTAssertNil(store.graph.node("e3"))

        _ = await store.rename("e1", to: "Samuel")
        XCTAssertEqual(store.graph.node("e1")?.label, "Samuel")

        let survivor = await store.rename("e2", to: "Leeds")
        XCTAssertEqual(survivor?.id, "e9")
        XCTAssertNil(store.graph.node("e2"))
        XCTAssertNotNil(store.graph.node("e9"))

        _ = await store.setPinned("e1", true)
        XCTAssertEqual(store.graph.node("e1")?.pinned, true)
    }

    func testAFailedMergeLeavesTheCanvasAlone() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/jarvis-memory/graph", json: Self.graphJSON)
        transport.route("/api/jarvis-memory/entity/merge", json: ["error": "types must match"], status: 400)
        let store = MemoryGraphStore(api: JarvisMemoryAPI(api: api), now: { self.now })
        await store.load()
        let merged = await store.merge("e2", into: "e1")
        XCTAssertFalse(merged)
        XCTAssertNotNil(store.graph.node("e2"))
        XCTAssertNotNil(store.toast)
    }

    func testTheNodeSheetUnlinksAMemory() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/jarvis-memory/entity/unlink", json: ["ok": true])
        transport.route("/api/jarvis-memory/entity", json: [
            "entity": ["id": "e1", "type": "person", "label": "Sam"],
            "memories": [["id": "m1", "body": "A", "created_at": 1], ["id": "m2", "body": "B", "created_at": 2]],
            "neighbors": [],
        ])
        let sheet = MemoryEntitySheetModel(id: "e1", api: JarvisMemoryAPI(api: api))
        await sheet.load()
        XCTAssertEqual(sheet.detail?.memories.map(\.id), ["m2", "m1"])
        await sheet.unlink("m1")
        XCTAssertEqual(sheet.detail?.memories.map(\.id), ["m2"])
        assertJSONEqual(transport.body(1), ["memory_id": "m1", "entity_id": "e1"])
    }

    func testMergeTargetsAreSameTypeAndSearchable() {
        var graph = MemoryGraph()
        graph.replace(with: MemoryGraphPayload(json: [
            "center": ["id": "me", "label": "You", "type": "me"],
            "nodes": [Self.node("p1", 3), Self.node("p2", 2), Self.node("pl", 2, type: "place")],
            "edges": [],
        ]))
        let neighbors = [MemoryEntityNeighbor(id: "p3", label: "Samantha", type: "person", weight: 1),
                         MemoryEntityNeighbor(id: "p2", label: "P2", type: "person", weight: 1)]
        let all = MemoryMergeTargets.list(for: "p1", kind: .person, graph: graph, neighbors: neighbors, search: "")
        XCTAssertEqual(all.map(\.id), ["p2", "p3"], "same type, not itself, no duplicates")
        let found = MemoryMergeTargets.list(for: "p1", kind: .person, graph: graph, neighbors: neighbors,
                                            search: "sam")
        XCTAssertEqual(found.map(\.id), ["p3"])
    }

    // MARK: Review fixes

    func testAFailedFilterChangeRollsBackAndSays() async throws {
        let (api, transport) = JarvisAPI.mocked()
        var fail = false
        transport.route("/api/jarvis-memory/graph") { _ in
            fail ? MockTransport.Reply(status: 500, body: Data("{}".utf8))
                 : MockTransport.Reply(body: try! JSONSerialization.data(withJSONObject: Self.graphJSON))
        }
        let store = MemoryGraphStore(api: JarvisMemoryAPI(api: api), now: { self.now })
        await store.load()
        fail = true
        var filters = store.filters
        filters.time = .week
        await store.setFilters(filters)
        XCTAssertEqual(store.filters.time, .all, "the chips go back to what the map shows")
        XCTAssertNotNil(store.toast, "with a graph on screen the error is a toast")
        XCTAssertNil(store.error)
        XCTAssertNotNil(store.graph.node("e1"), "the old graph stays")
    }

    func testARecallThatIsGoneSaysSoAndShowsTheNormalView() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/jarvis-memory/graph/highlight", json: ["error": "not found"], status: 404)
        transport.route("/api/jarvis-memory/graph", json: Self.graphJSON)
        let store = MemoryGraphStore(api: JarvisMemoryAPI(api: api), now: { self.now })
        await store.showRecall(MemoryRecall(id: "99", query: "Old"))
        XCTAssertNil(store.recall)
        XCTAssertEqual(store.toast, MemoryGraphStore.recallGoneMessage)
        XCTAssertNotNil(store.graph.node("e1"), "the normal You view")
        XCTAssertTrue(store.graph.highlight.isEmpty)
        XCTAssertNil(store.error)
    }

    func testAnExpandThatLandsAfterAReloadIsIgnored() async throws {
        let inner = MockTransport()
        let gated = GatedTransport(inner: inner, gate: "center=e1")
        let api = JarvisAPI(credentials: TestCredentials(), transport: gated)
        inner.route("/api/jarvis-memory/graph") { request in
            let expand = request.url?.query?.contains("center=e1") == true
            let json: JSONObject = expand ? [
                "center": ["id": "e1", "label": "Sam", "type": "person"],
                "nodes": [Self.node("e7", 2)], "edges": [["a": "e1", "b": "e7", "weight": 2]],
            ] : Self.graphJSON
            return MockTransport.Reply(body: try! JSONSerialization.data(withJSONObject: json))
        }
        let store = MemoryGraphStore(api: JarvisMemoryAPI(api: api), now: { self.now })
        await store.load()
        let expanding = Task { await store.expand("e1") }
        await servicesWaitUntil { gated.parked }
        await store.load()
        gated.open()
        await expanding.value
        XCTAssertNil(store.graph.node("e7"), "the graph was reloaded under it")
        XCTAssertFalse(store.graph.expanded.contains("e1"))
    }

    func testSheetErrorsShowInTheSheet() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/jarvis-memory/graph", json: Self.graphJSON)
        transport.route("/api/jarvis-memory/entity", json: ["error": "nope"], status: 500)
        let store = MemoryGraphStore(api: JarvisMemoryAPI(api: api), now: { self.now })
        await store.load()
        store.sheetOpen = true
        let pinned = await store.setPinned("e2", true)
        XCTAssertNil(pinned)
        XCTAssertNotNil(store.sheetToast, "shown in the sheet")
        XCTAssertNil(store.toast, "not in the map's toast under the sheet")
        XCTAssertEqual(store.graph.node("e2")?.pinned, false)
        store.sheetOpen = false
        _ = await store.rename("e2", to: "X")
        XCTAssertNotNil(store.toast)
    }

    func testUnlinkingAMemoryLightensTheNode() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/jarvis-memory/graph", json: Self.graphJSON)
        let store = MemoryGraphStore(api: JarvisMemoryAPI(api: api), now: { self.now })
        await store.load()
        store.memoryUnlinked(from: "e1")
        XCTAssertEqual(store.graph.node("e1")?.weight, 11)
        XCTAssertEqual(store.graph.edge("me", "e1")?.weight, 11)
    }

    func testTheSheetReportsWhetherAnUnlinkWorked() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/jarvis-memory/entity/unlink", json: ["error": "x"], status: 500)
        transport.route("/api/jarvis-memory/entity", json: [
            "entity": ["id": "e1", "type": "person", "label": "Sam"],
            "memories": [["id": "m1", "body": "A", "created_at": 1]], "neighbors": [],
        ])
        let sheet = MemoryEntitySheetModel(id: "e1", api: JarvisMemoryAPI(api: api))
        await sheet.load()
        let ok = await sheet.unlink("m1")
        XCTAssertFalse(ok)
        XCTAssertEqual(sheet.detail?.memories.map(\.id), ["m1"])
        XCTAssertNotNil(sheet.toast)
    }
}

/// The "memories used" chip under a Jarvis reply.
@MainActor
final class MemoryRecallChipTests: XCTestCase {

    /// 40+ characters, like the rules blocks the surfaces really send.
    private static let rules = "[Voice mode — keep it short, no lists, no markdown, speak naturally]"

    func testALeadingRulesBlockIsStripped() {
        XCTAssertEqual(MemoryRecallMatch.normalize(Self.rules + "\n\nWhat did Sam say?"), "What did Sam say?")
        XCTAssertEqual(MemoryRecallMatch.normalize("  [Context: a long block of things\nline two, still going on]\n \n  Hi there \n"),
                       "Hi there")
        XCTAssertEqual(MemoryRecallMatch.normalize(Self.rules + "\n\n" + Self.rules + "\n\nTwo blocks"), "Two blocks",
                       "however many blocks lead")
        XCTAssertEqual(MemoryRecallMatch.normalize("[Rules: a [nested] note that is long enough to count]\n\nHi"), "Hi")
        XCTAssertEqual(MemoryRecallMatch.normalize("  plain question  "), "plain question")
        XCTAssertEqual(MemoryRecallMatch.normalize("[1] is a list marker"), "[1] is a list marker",
                       "a bracket without a blank line after it is text")
        XCTAssertEqual(MemoryRecallMatch.normalize("[short]\n\nHi"), "[short]\n\nHi",
                       "under 40 characters it is his own text, as on the server")
    }

    private func turns(_ items: [(Bool, String)]) -> [MemoryRecallTurn] {
        items.map { MemoryRecallTurn(isUser: $0.0, text: $0.1) }
    }

    func testTheChipGoesUnderTheReplyToTheMatchingQuestion() {
        let rows = turns([
            (true, Self.rules + "\n\nWhat did Sam say?"),
            (false, ""),
            (false, ""),
            (true, "Thanks"),
            (false, ""),
        ])
        let recalls = [MemoryRecall(id: "1", query: "What did Sam say?")]
        let chips = MemoryRecallMatch.chips(turns: rows, recalls: recalls)
        XCTAssertEqual(chips.mapValues(\.id), [2: "1"], "once, under the last reply of that turn")
    }

    func testNoRecallNoChip() {
        let rows = turns([(true, "Hello"), (false, "")])
        XCTAssertTrue(MemoryRecallMatch.chips(turns: rows, recalls: []).isEmpty)
        XCTAssertTrue(MemoryRecallMatch.chips(turns: rows,
                                              recalls: [MemoryRecall(id: "1", query: "Other")]).isEmpty)
    }

    func testWithoutTimesAQuestionAskedTwicePairsInOrder() {
        let rows = turns([(true, "Where am I?"), (false, ""), (true, "Where am I?"), (false, "")])
        // Newest first, as the server sends them.
        let recalls = [MemoryRecall(id: "new", query: "Where am I?"), MemoryRecall(id: "old", query: "Where am I?")]
        let chips = MemoryRecallMatch.chips(turns: rows, recalls: recalls)
        XCTAssertEqual(chips.mapValues(\.id), [1: "old", 3: "new"])
    }

    /// Asked twice, only the second time used memory: the chip goes on the reply
    /// whose question came just before the recall, not the first one.
    func testARepeatedQuestionPairsByTime() {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let rows = [
            MemoryRecallTurn(isUser: true, text: "Where am I?", time: t0),
            MemoryRecallTurn(isUser: false, text: "", time: t0.addingTimeInterval(5)),
            MemoryRecallTurn(isUser: true, text: "Where am I?", time: t0.addingTimeInterval(600)),
            MemoryRecallTurn(isUser: false, text: "", time: t0.addingTimeInterval(605)),
        ]
        let recall = MemoryRecall(id: "r", ts: t0.addingTimeInterval(601), query: "Where am I?")
        XCTAssertEqual(MemoryRecallMatch.chips(turns: rows, recalls: [recall]).mapValues(\.id), [3: "r"])
    }

    func testAReplyWithNoQuestionBeforeItGetsNoChip() {
        let rows = turns([(false, "")])
        XCTAssertTrue(MemoryRecallMatch.chips(turns: rows, recalls: [MemoryRecall(id: "1", query: "")]).isEmpty)
    }

    private func reply(_ text: String = "Hello") -> ChatMessage {
        var reply = ChatMessage.assistant()
        reply.appendToken(text)
        return reply
    }

    func testTheChatLoadsRecallsOncePerChat() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/jarvis-memory/recalls",
                        json: ["recalls": [["id": 5, "query": "Hi", "session_id": "s1"]]])
        let store = ChatRecallStore(api: JarvisMemoryAPI(api: api))
        await store.load(sessionID: "s1")
        await store.load(sessionID: "s1")
        XCTAssertEqual(transport.requests.count, 1, "one request per open chat")
        XCTAssertEqual(transport.query(0), ["session_id": "s1", "limit": "100"])
        XCTAssertEqual(store.recalls.map(\.id), ["5"])
        let rows = ChatRow.rows(for: [ChatMessage.user(Self.rules + "\n\nHi"), reply()])
        let chips = store.chips(for: rows, sessionID: "s1")
        XCTAssertEqual(chips.count, 1)
        XCTAssertEqual(chips[rows[1].id]?.id, "5", "keyed by the reply's message id")
        await store.load(sessionID: nil)
        XCTAssertTrue(store.recalls.isEmpty)
        XCTAssertEqual(transport.requests.count, 1, "a new chat has nothing to ask about")
        await store.load(sessionID: "s2")
        XCTAssertEqual(transport.requests.count, 2)
    }

    /// A new chat makes its session right before sending, so the open-time
    /// fetch is empty; the finished turn fetches once more — once per turn.
    func testAFinishedTurnFetchesOnce() async throws {
        let (api, transport) = JarvisAPI.mocked()
        var answer: [JSONObject] = []
        transport.route("/api/jarvis-memory/recalls") { _ in
            MockTransport.Reply(body: try! JSONSerialization.data(withJSONObject: ["recalls": answer]))
        }
        let store = ChatRecallStore(api: JarvisMemoryAPI(api: api))
        await store.load(sessionID: "s1")
        XCTAssertTrue(store.recalls.isEmpty)

        answer = [["id": 8, "query": "Hi", "session_id": "s1"]]
        let rows = ChatRow.rows(for: [ChatMessage.user("Hi"), reply()])
        await store.turnFinished(rows: rows, sessionID: "s1")
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(store.chips(for: rows, sessionID: "s1")[rows[1].id]?.id, "8")

        await store.turnFinished(rows: rows, sessionID: "s1")
        XCTAssertEqual(transport.requests.count, 2, "a reply that has its chip needs no fetch")

        let more = ChatRow.rows(for: [ChatMessage.user("Hi"), reply(), ChatMessage.user("Ok"), reply("Sure")])
        await store.turnFinished(rows: more, sessionID: "s1")
        XCTAssertEqual(transport.requests.count, 3, "the next turn fetches once")
        await store.turnFinished(rows: more, sessionID: "s1")
        XCTAssertEqual(transport.requests.count, 3, "and only once")
    }

    func testAnOldServerJustShowsNoChips() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/jarvis-memory/recalls", json: ["error": "not found"], status: 404)
        let store = ChatRecallStore(api: JarvisMemoryAPI(api: api))
        await store.load(sessionID: "s1")
        XCTAssertTrue(store.recalls.isEmpty)
    }
}

/// Parks GETs whose URL contains `gate` until `open()`.
final class GatedTransport: APITransport, @unchecked Sendable {
    let inner: MockTransport
    let gate: String
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    init(inner: MockTransport, gate: String) {
        self.inner = inner
        self.gate = gate
    }

    var parked: Bool { lock.lock(); defer { lock.unlock() }; return !waiters.isEmpty }

    func open() {
        lock.lock()
        isOpen = true
        let parked = waiters
        waiters = []
        lock.unlock()
        parked.forEach { $0.resume() }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.url?.absoluteString.contains(gate) == true {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if isOpen {
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiters.append(continuation)
                    lock.unlock()
                }
            }
        }
        return try await inner.send(request)
    }

    func stream(_ request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse) {
        try await inner.stream(request)
    }
}

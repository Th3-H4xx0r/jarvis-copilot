import XCTest
@testable import JarvisCopilot

final class HarnessGraphTests: XCTestCase {
    func testNewHarnessHasMessage() {
        XCTAssertEqual(HarnessGraph.newHarness(id: "m", name: "M").nodes.filter { $0.type == .message }.count, 1)
    }

    func testConnectRules() {
        var h = HarnessGraph.newHarness(id: "m", name: "M")
        let a = HarnessGraph.addNode(&h, type: .answer, at: .zero)
        XCTAssertTrue(HarnessGraph.connect(&h, from: "in", to: a, when: "always"))
        XCTAssertFalse(HarnessGraph.connect(&h, from: "in", to: a, when: "always"), "no duplicate wire")
        XCTAssertFalse(HarnessGraph.connect(&h, from: a, to: a, when: "always"), "no self wire")
        HarnessGraph.disconnect(&h, index: 0)
        XCTAssertTrue(h.edges.isEmpty)
    }

    func testRemoveNodeRemovesWiresAndKeepsMessage() {
        var h = HarnessGraph.newHarness(id: "m", name: "M")
        let a = HarnessGraph.addNode(&h, type: .answer, at: .zero)
        _ = HarnessGraph.connect(&h, from: "in", to: a, when: "always")
        HarnessGraph.removeNode(&h, id: a)
        HarnessGraph.removeNode(&h, id: "in")
        XCTAssertTrue(h.edges.isEmpty)
        XCTAssertEqual(h.nodes.map(\.id), ["in"])
    }

    func testDuplicateDropsBuiltinAndVersion() {
        var h = HarnessGraph.newHarness(id: "single", name: "Single")
        h.builtin = true
        h.version = 3
        h.problems = []
        let c = HarnessGraph.duplicate(h, id: "single-copy", name: "Single copy")
        XCTAssertEqual(c.id, "single-copy")
        XCTAssertNil(c.builtin)
        XCTAssertNil(c.version)
        XCTAssertNil(c.problems)
    }

    func testDefaults() {
        XCTAssertEqual(HarnessGraph.defaults(for: .background).deliver, "speak_or_notify")
        XCTAssertEqual(HarnessGraph.defaults(for: .review).deliver, "post_if_changed")
        XCTAssertEqual(HarnessGraph.defaults(for: .answer).tools, .preset("lean"))
        XCTAssertEqual(HarnessGraph.defaults(for: .route).by, "rules")
    }

    func testDefaultWhenForNewWires() {
        var h = HarnessGraph.newHarness(id: "m", name: "M")
        let r = HarnessGraph.addNode(&h, type: .route, at: .zero)
        let a = HarnessGraph.addNode(&h, type: .answer, at: .zero)
        let b = HarnessGraph.addNode(&h, type: .background, at: .zero)
        XCTAssertEqual(HarnessGraph.defaultWhen(h, from: r), "default")
        _ = HarnessGraph.connect(&h, from: r, to: a, when: "default")
        XCTAssertTrue(HarnessGraph.defaultWhen(h, from: r).hasPrefix("label:"))
        XCTAssertEqual(HarnessGraph.defaultWhen(h, from: a, to: b), "handoff")
        XCTAssertEqual(HarnessGraph.defaultWhen(h, from: "in"), "always")
    }

    // MARK: Route labels (the editor's label rows)

    private func routeHarness() -> (AgentHarness, route: String, answer: String) {
        var h = HarnessGraph.newHarness(id: "m", name: "M")
        let r = HarnessGraph.addNode(&h, type: .route, at: .zero)
        let a = HarnessGraph.addNode(&h, type: .answer, at: .zero)
        return (h, r, a)
    }

    func testRenameLabelKeepsItsDescriptionAndWires() {
        var (h, r, a) = routeHarness()
        let i = h.nodes.firstIndex { $0.id == r }!
        h.nodes[i].labels = ["deep", "quick"]
        h.nodes[i].labelDescriptions = ["deep": "needs research", "quick": "small talk"]
        _ = HarnessGraph.connect(&h, from: r, to: a, when: "label:deep")
        _ = HarnessGraph.connect(&h, from: "in", to: a, when: "always")
        XCTAssertTrue(HarnessGraph.renameLabel(&h, node: r, from: "deep", to: " research "))
        XCTAssertEqual(h.nodes[i].labels, ["research", "quick"])
        XCTAssertEqual(h.nodes[i].labelDescriptions, ["research": "needs research", "quick": "small talk"])
        XCTAssertEqual(h.edges.map(\.when), ["label:research", "always"])
    }

    func testRenameLabelRefusesBlankAndTakenNames() {
        var (h, r, a) = routeHarness()
        let i = h.nodes.firstIndex { $0.id == r }!
        h.nodes[i].labels = ["deep", "quick"]
        _ = HarnessGraph.connect(&h, from: r, to: a, when: "label:deep")
        XCTAssertFalse(HarnessGraph.renameLabel(&h, node: r, from: "deep", to: "  "))
        XCTAssertFalse(HarnessGraph.renameLabel(&h, node: r, from: "deep", to: "quick"), "they would share wires")
        XCTAssertEqual(h.nodes[i].labels, ["deep", "quick"])
        XCTAssertEqual(h.edges.first?.when, "label:deep")
    }

    /// A model router only picks among the Route's labels, so a label made up
    /// for a new wire has to join them.
    func testWiringARouteRemembersTheLabelItMadeUp() {
        var (h, r, a) = routeHarness()
        let b = HarnessGraph.addNode(&h, type: .answer, at: .zero)
        XCTAssertTrue(HarnessGraph.wire(&h, from: r, to: a))
        XCTAssertTrue(HarnessGraph.wire(&h, from: r, to: b))
        XCTAssertFalse(HarnessGraph.wire(&h, from: r, to: b), "already wired")
        XCTAssertEqual(h.edges.map(\.when), ["default", "label:path-1"])
        XCTAssertEqual(h.node(r)?.labels, ["path-1"])
    }

    func testAddLabelTakesTheNextFreePath() {
        var (h, r, a) = routeHarness()
        let i = h.nodes.firstIndex { $0.id == r }!
        h.nodes[i].labels = ["deep"]
        _ = HarnessGraph.connect(&h, from: r, to: a, when: "label:path-2")
        XCTAssertEqual(HarnessGraph.addLabel(&h, node: r), "path-3", "path-2 is a wire already")
        XCTAssertEqual(h.nodes[i].labels, ["deep", "path-3"])
    }

    func testRemoveLabelDropsItsDescription() {
        var (h, r, _) = routeHarness()
        let i = h.nodes.firstIndex { $0.id == r }!
        h.nodes[i].labels = ["deep", "quick"]
        h.nodes[i].labelDescriptions = ["deep": "needs research"]
        HarnessGraph.removeLabels(&h, node: r, at: IndexSet(integer: 0))
        XCTAssertEqual(h.nodes[i].labels, ["quick"])
        XCTAssertNil(h.nodes[i].labelDescriptions, "an empty map is dropped, not saved as {}")
    }

    func testDescribeLabelSetsAndClears() {
        var (h, r, _) = routeHarness()
        let i = h.nodes.firstIndex { $0.id == r }!
        h.nodes[i].labels = ["deep"]
        HarnessGraph.describeLabel(&h, node: r, label: "deep", as: "needs research")
        XCTAssertEqual(h.nodes[i].labelDescriptions, ["deep": "needs research"])
        HarnessGraph.describeLabel(&h, node: r, label: "deep", as: "  ")
        XCTAssertNil(h.nodes[i].labelDescriptions)
    }
}

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

    /// A rules Route picks the wire matching the rule's label, so a rename that
    /// moved the wire but not the rule would send that message down the default wire.
    func testRenameLabelCarriesTheRulesUsingIt() {
        var (h, r, a) = routeHarness()
        let i = h.nodes.firstIndex { $0.id == r }!
        h.nodes[i].labels = ["deep"]
        h.nodes[i].rules = [HarnessRule(match: "keywords", value: .string("code"), label: "deep"),
                            HarnessRule(match: "regex", value: .string("x"), label: "other")]
        _ = HarnessGraph.connect(&h, from: r, to: a, when: "label:deep")
        XCTAssertFalse(HarnessGraph.renameLabel(&h, node: r, from: "deep", to: "other"), "a rule already uses it")
        XCTAssertTrue(HarnessGraph.renameLabel(&h, node: r, from: "deep", to: "research"))
        XCTAssertEqual(h.nodes[i].rules?.map(\.label), ["research", "other"])
        XCTAssertEqual(h.edges.first?.when, "label:research")
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

    // MARK: A Route's labels and its wires stay in step
    // Seen live (web): a wire's label was retyped to `long-running` while the Route
    // kept `path-2`, and renaming `path-2` was then refused — so a model router
    // could never pick `long-running`. The phone shares the same rules.

    /// A model Route with labels ["deep"], wires default → a and label:deep → b.
    private func modelRoute() -> (AgentHarness, route: String, c: String, routeIndex: Int) {
        var (h, r, a) = routeHarness()
        let b = HarnessGraph.addNode(&h, type: .answer, at: .zero)
        let c = HarnessGraph.addNode(&h, type: .answer, at: .zero)
        let i = h.nodes.firstIndex { $0.id == r }!
        h.nodes[i].by = "model"
        h.nodes[i].labels = ["deep"]
        _ = HarnessGraph.connect(&h, from: r, to: a, when: "default")
        _ = HarnessGraph.connect(&h, from: r, to: b, when: "label:deep")
        return (h, r, c, i)
    }

    func testRelabelWireRenamesTheLabelItHad() {
        var (h, r, c, i) = modelRoute()
        XCTAssertTrue(HarnessGraph.wire(&h, from: r, to: c))
        XCTAssertEqual(h.edges.last?.when, "label:path-2")
        HarnessGraph.describeLabel(&h, node: r, label: "path-2", as: "long jobs")
        XCTAssertTrue(HarnessGraph.relabelWire(&h, edge: 2, to: " long-running "))
        XCTAssertEqual(h.nodes[i].labels, ["deep", "long-running"])
        XCTAssertEqual(h.nodes[i].labelDescriptions, ["long-running": "long jobs"])
        XCTAssertEqual(h.edges[2].when, "label:long-running")
    }

    func testRelabelWirePointsAtALabelNoOtherWireHas() {
        var (h, r, c, i) = modelRoute()
        h.nodes[i].labels = ["deep", "quick"]
        _ = HarnessGraph.connect(&h, from: r, to: c, when: "label:quick")
        XCTAssertFalse(HarnessGraph.relabelWire(&h, edge: 2, to: "deep"), "another wire has it")
        XCTAssertFalse(HarnessGraph.relabelWire(&h, edge: 2, to: "  "))
        XCTAssertEqual(h.edges[2].when, "label:quick")
        h.edges[1].when = "default"
        XCTAssertTrue(HarnessGraph.relabelWire(&h, edge: 2, to: "deep"))
        XCTAssertEqual(h.edges[2].when, "label:deep")
        XCTAssertEqual(h.nodes[i].labels, ["deep", "quick"])
    }

    func testRelabelWireOnAStrayWireAddsTheLabel() {
        var (h, r, c, i) = modelRoute()
        _ = HarnessGraph.connect(&h, from: r, to: c, when: "label:ghost")
        XCTAssertTrue(HarnessGraph.relabelWire(&h, edge: 2, to: "long-running"))
        XCTAssertEqual(h.nodes[i].labels, ["deep", "long-running"])
        XCTAssertEqual(h.edges[2].when, "label:long-running")
    }

    func testRenameLabelAdoptsTheStrayWireCarryingTheName() {
        var (h, r, c, i) = modelRoute()
        h.nodes[i].labels = ["deep", "path-2"]
        h.nodes[i].labelDescriptions = ["path-2": "long jobs"]
        _ = HarnessGraph.connect(&h, from: r, to: c, when: "label:long-running")
        XCTAssertTrue(HarnessGraph.renameLabel(&h, node: r, from: "path-2", to: "long-running"))
        XCTAssertEqual(h.nodes[i].labels, ["deep", "long-running"])
        XCTAssertEqual(h.nodes[i].labelDescriptions, ["long-running": "long jobs"])
        XCTAssertEqual(h.edges[2].when, "label:long-running")
    }

    func testRenameLabelWontAdoptAStrayWireWhenItHasAWire() {
        var (h, r, c, i) = modelRoute()
        _ = HarnessGraph.connect(&h, from: r, to: c, when: "label:ghost")
        XCTAssertFalse(HarnessGraph.renameLabel(&h, node: r, from: "deep", to: "ghost"), "two wires would share it")
        XCTAssertEqual(h.nodes[i].labels, ["deep"])
        XCTAssertEqual(h.edges[1].when, "label:deep")
    }

    /// The wire sheet offers only labels a router can pick and no other wire has.
    func testWireLabelChoicesSkipLabelsOtherWiresHave() {
        var (h, r, c, i) = modelRoute()
        h.nodes[i].labels = ["deep", "quick"]
        h.nodes[i].rules = [HarnessRule(match: "keywords", value: .string("x"), label: "ruled")]
        _ = HarnessGraph.connect(&h, from: r, to: c, when: "label:quick")
        XCTAssertEqual(HarnessGraph.wireLabelChoices(h, edge: 2), ["quick"], "deep is wired; a model router ignores rules")
        h.nodes[i].by = "rules"
        XCTAssertEqual(HarnessGraph.wireLabelChoices(h, edge: 2), ["quick", "ruled"])
    }
}

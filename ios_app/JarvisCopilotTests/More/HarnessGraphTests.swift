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
}

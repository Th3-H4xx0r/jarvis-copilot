import XCTest
@testable import JarvisCopilot

final class HarnessModelsTests: XCTestCase {
    let json = """
    {"harnesses":[{"id":"fast-claude","name":"Fast + Claude","icon":"⚡","builtin":true,
      "nodes":[{"id":"in","type":"message","x":40,"y":40},
               {"id":"fast","type":"answer","model":"@ollama-cloud:gemma4:31b","tools":"lean","x":40,"y":180},
               {"id":"c","type":"background","model":"@claude-code:claude-sonnet-5-5","tools":["web","terminal"],"deliver":"speak_or_notify","x":0,"y":0},
               {"id":"r","type":"route","by":"rules","rules":[{"match":"has_attachment","value":true,"label":"deep"},{"match":"keywords","value":"code, bug","label":"deep"}],"labels":["deep"],"x":0,"y":0}],
      "edges":[{"from":"in","to":"fast","when":"always"},{"from":"fast","to":"c","when":"handoff"}],
      "problems":[{"node":"r","edge":null,"message":"A Route needs one default wire."}]}],
     "assignments":{"voice":"fast-claude","chat":"single"}}
    """.data(using: .utf8)!

    func testDecodesSnapshotIncludingToolsShapes() throws {
        let snap = try JSONDecoder().decode(HarnessSnapshot.self, from: json)
        let nodes = snap.harnesses[0].nodes
        XCTAssertEqual(nodes[1].tools, .preset("lean"))
        XCTAssertEqual(nodes[2].tools, .toolsets(["web", "terminal"]))
        XCTAssertEqual(nodes[3].rules?.first?.value, .bool(true))
        XCTAssertEqual(nodes[3].rules?.last?.value, .string("code, bug"))
        XCTAssertEqual(snap.harnesses[0].problems?.first?.node, "r")
        XCTAssertEqual(snap.assignments["voice"], "fast-claude")
    }

    func testRoundTripKeepsSnakeCaseKeysAndDropsNils() throws {
        var node = HarnessNode(id: "a", type: .answer, x: 1, y: 2)
        node.fallbackModel = "@x:y"
        node.maxSteps = 4
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(node)) as! [String: Any]
        XCTAssertEqual(obj["fallback_model"] as? String, "@x:y")
        XCTAssertEqual(obj["max_steps"] as? Int, 4)
        XCTAssertNil(obj["deliver"])
    }

    func testProblemsForNode() throws {
        let snap = try JSONDecoder().decode(HarnessSnapshot.self, from: json)
        XCTAssertEqual(snap.harnesses[0].problems(forNode: "r").count, 1)
        XCTAssertTrue(snap.harnesses[0].problems(forNode: "fast").isEmpty)
    }

    @MainActor func testCurrentPrefersSessionThenAssignment() {
        let store = HarnessStore()
        store.assignments = ["voice": "fast-claude", "chat": "single"]
        XCTAssertEqual(store.current(for: .chat, sessionHarnessID: "router"), "router")
        XCTAssertEqual(store.current(for: .chat, sessionHarnessID: nil), "single")
        XCTAssertEqual(store.current(for: .voice, sessionHarnessID: nil), "fast-claude")
    }
}

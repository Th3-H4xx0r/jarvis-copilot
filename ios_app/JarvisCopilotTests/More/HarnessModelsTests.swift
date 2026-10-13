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

    func testLabelDescriptionsRoundTrip() throws {
        var n = HarnessNode(id: "r", type: .route, x: 0, y: 0)
        n.labels = ["deep"]; n.labelDescriptions = ["deep": "needs research"]
        let data = try JSONEncoder().encode(n)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"label_descriptions\""))
        XCTAssertEqual(try JSONDecoder().decode(HarnessNode.self, from: data).labelDescriptions?["deep"], "needs research")
    }

    func testProblemsForNode() throws {
        let snap = try JSONDecoder().decode(HarnessSnapshot.self, from: json)
        XCTAssertEqual(snap.harnesses[0].problems(forNode: "r").count, 1)
        XCTAssertTrue(snap.harnesses[0].problems(forNode: "fast").isEmpty)
    }

    // MARK: Computer node

    private let computerJSON = #"""
    {"id":"mac","name":"Mac","icon":"","nodes":[
      {"id":"in","type":"message","x":40,"y":40},
      {"id":"sonnet","type":"answer","model":"@anthropic-api:claude-sonnet-5-5","tools":"lean","x":40,"y":180},
      {"id":"computer-1","type":"computer","x":0,"y":320,"label":"Mac",
       "model":"@celeris:celeris-1-decision","fallback_model":"@anthropic-api:claude-haiku-5-5",
       "max_steps":30,"instructions":"Close the dialogs first."}],
     "edges":[{"from":"in","to":"sonnet","when":"always"},
              {"from":"sonnet","to":"computer-1","when":"hands"},
              {"from":"computer-1","to":"sonnet","when":"stuck"}]}
    """#.data(using: .utf8)!

    private func object(_ data: Data) throws -> NSDictionary {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    func testComputerNodeAndHandsStuckWiresDecode() throws {
        let h = try JSONDecoder().decode(AgentHarness.self, from: computerJSON)
        let c = try XCTUnwrap(h.node("computer-1"))
        XCTAssertEqual(c.type, .computer)
        XCTAssertEqual(c.label, "Mac")
        XCTAssertEqual(c.model, "@celeris:celeris-1-decision")
        XCTAssertEqual(c.fallbackModel, "@anthropic-api:claude-haiku-5-5")
        XCTAssertEqual(c.maxSteps, 30)
        XCTAssertEqual(c.instructions, "Close the dialogs first.")
        XCTAssertNil(c.extra)
        XCTAssertEqual(h.edges.map(\.when), ["always", "hands", "stuck"])
        XCTAssertEqual(h.edges.map(\.isDashed), [false, true, true])
    }

    func testComputerHarnessRoundTripsWithoutLosingAnything() throws {
        let h = try JSONDecoder().decode(AgentHarness.self, from: computerJSON)
        XCTAssertEqual(try object(JSONEncoder().encode(h)), try object(computerJSON))
    }

    /// A newer server's keys ride along untouched, so a save from the phone never strips them.
    func testUnknownNodeKeysSurviveARoundTrip() throws {
        let json = #"""
        {"id":"computer-1","type":"computer","x":0,"y":0,"max_steps":12,
         "screen":{"display":2,"scale":0.5,"apps":["Safari",null],"ok":true},"retries":3,"note":"x"}
        """#.data(using: .utf8)!
        let node = try JSONDecoder().decode(HarnessNode.self, from: json)
        XCTAssertEqual(node.maxSteps, 12)
        XCTAssertEqual(node.extra?["retries"], .number(3))
        XCTAssertEqual(node.extra?["screen"]?.objectValue?["ok"], .bool(true))
        XCTAssertEqual(try object(JSONEncoder().encode(node)), try object(json))
    }

    /// Exactly what the app encoded before nodes kept unknown keys (sorted keys, so
    /// the bytes are comparable): an old design saves back byte for byte.
    func testExistingNodeTypesEncodeExactlyAsBefore() throws {
        let snap = try JSONDecoder().decode(HarnessSnapshot.self, from: #"""
        {"harnesses":[{"id":"fast-claude","name":"Fast + Claude","icon":"⚡","builtin":true,"version":3,
          "nodes":[{"id":"in","type":"message","x":40,"y":40},
                   {"id":"fast","type":"answer","model":"@ollama-cloud:gemma4:31b","tools":"lean","x":40,"y":180,"fallback_model":"@a:b","max_steps":4,"label":"Fast","instructions":"be quick"},
                   {"id":"c","type":"background","model":"@claude-code:claude-sonnet-5-5","tools":["web","terminal"],"deliver":"speak_or_notify","x":0.5,"y":0},
                   {"id":"rv","type":"review","model":"@x/y:z","deliver":"post","x":10,"y":20},
                   {"id":"r","type":"route","by":"model","model":"@celeris:celeris-1-decision","rules":[{"match":"has_attachment","value":true,"label":"deep"},{"match":"keywords","value":"code, bug","label":"deep"}],"labels":["deep","quick"],"label_descriptions":{"deep":"needs research","quick":"small"},"x":0,"y":0}],
          "edges":[{"from":"in","to":"r","when":"always"},{"from":"r","to":"fast","when":"default"},{"from":"r","to":"fast","when":"label:deep"},{"from":"fast","to":"c","when":"handoff"},{"from":"fast","to":"rv","when":"slow:20"},{"from":"x","to":"y"}],
          "problems":[{"node":"r","edge":null,"message":"A Route needs one default wire."}]}],
         "assignments":{"voice":"fast-claude","chat":"single"}}
        """#.data(using: .utf8)!)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let before = #"{"builtin":true,"edges":[{"from":"in","to":"r","when":"always"},{"from":"r","to":"fast","when":"default"},{"from":"r","to":"fast","when":"label:deep"},{"from":"fast","to":"c","when":"handoff"},{"from":"fast","to":"rv","when":"slow:20"},{"from":"x","to":"y","when":"always"}],"icon":"⚡","id":"fast-claude","name":"Fast + Claude","nodes":[{"id":"in","type":"message","x":40,"y":40},{"fallback_model":"@a:b","id":"fast","instructions":"be quick","label":"Fast","max_steps":4,"model":"@ollama-cloud:gemma4:31b","tools":"lean","type":"answer","x":40,"y":180},{"deliver":"speak_or_notify","id":"c","model":"@claude-code:claude-sonnet-5-5","tools":["web","terminal"],"type":"background","x":0.5,"y":0},{"deliver":"post","id":"rv","model":"@x\/y:z","type":"review","x":10,"y":20},{"by":"model","id":"r","label_descriptions":{"deep":"needs research","quick":"small"},"labels":["deep","quick"],"model":"@celeris:celeris-1-decision","rules":[{"label":"deep","match":"has_attachment","value":true},{"label":"deep","match":"keywords","value":"code, bug"}],"type":"route","x":0,"y":0}],"problems":[{"message":"A Route needs one default wire.","node":"r"}],"version":3}"#
        XCTAssertEqual(String(decoding: try encoder.encode(snap.harnesses[0]), as: UTF8.self), before)
    }

    @MainActor func testCurrentPrefersSessionThenAssignment() {
        let store = HarnessStore(defaults: UserDefaults(suiteName: "HarnessModelsTests")!)
        store.applyAssignments(["voice": "fast-claude", "chat": "single"], overrides: nil)
        XCTAssertEqual(store.current(for: .chat, sessionHarnessID: "router"), "router")
        XCTAssertEqual(store.current(for: .chat, sessionHarnessID: nil), "single")
        XCTAssertEqual(store.current(for: .voice, sessionHarnessID: nil), "fast-claude")
    }

    /// The chip (phone) and the Jarvis tab (CarPlay) name a surface the same way.
    @MainActor func testLabelNamesTheModelForSingleElseTheHarness() throws {
        let store = HarnessStore(defaults: UserDefaults(suiteName: "HarnessModelsTests")!)
        store.harnesses = try JSONDecoder().decode(HarnessSnapshot.self, from: json).harnesses
        let named = store.harnesses[0]
        store.applyAssignments(["voice": named.id, "chat": "single"], overrides: nil)
        XCTAssertEqual(store.label(for: .voice, sessionHarnessID: nil, singleModelLabel: "Opus"), named.title)
        XCTAssertEqual(store.label(for: .chat, sessionHarnessID: nil, singleModelLabel: "Opus"), "Opus")
        XCTAssertEqual(store.label(for: .chat, sessionHarnessID: "gone", singleModelLabel: "Opus"), "gone",
                       "an unknown harness shows its id rather than nothing")
    }
}

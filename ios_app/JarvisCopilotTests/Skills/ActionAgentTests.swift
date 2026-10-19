import XCTest
@testable import JarvisCopilot

/// Which model or harness a button's Ask Jarvis runs on, and which chat it lands in.
@MainActor
final class ActionAgentTests: XCTestCase {

    func testOldPromptJSONDecodesAsSameAsDefault() throws {
        // Exactly what builds before the choice existed wrote.
        let old = Data(#"{"prompt":{"_0":"lights off"}}"#.utf8)
        let action = try JSONDecoder().decode(RingAction.self, from: old)
        XCTAssertEqual(action, .prompt("lights off"))
        XCTAssertEqual(action, .prompt("lights off", agent: nil))
    }

    func testAChoiceSurvivesARoundTrip() throws {
        for agent in [AgentChoice.harness("deep"), .model(id: "claude-haiku-5-5", provider: "anthropic"),
                      .model(id: "gemma4", provider: nil)] {
            let action = RingAction.prompt("plan my day", agent: agent)
            let back = try JSONDecoder().decode(RingAction.self, from: JSONEncoder().encode(action))
            XCTAssertEqual(back, action)
        }
    }

    func testSameAsDefaultSendsTheDefaultHarnessExplicitly() {
        // "" would follow whatever harness the button's chat last ran, not his Default.
        XCTAssertEqual(ActionAgent.turn(choice: nil, override: nil, defaultHarness: "fast-claude"),
                       TurnChoice(harnessID: "fast-claude"))
        XCTAssertEqual(ActionAgent.turn(choice: nil, override: nil, defaultHarness: ""),
                       TurnChoice(harnessID: "single"))
    }

    func testHarnessChoiceSendsItsID() {
        XCTAssertEqual(ActionAgent.turn(choice: .harness("deep"), override: nil, defaultHarness: "single"),
                       TurnChoice(harnessID: "deep"))
    }

    func testModelChoiceSendsModelAndNoHarness() {
        let turn = ActionAgent.turn(choice: .model(id: "claude-haiku-5-5", provider: "anthropic"),
                                    override: nil, defaultHarness: "deep")
        XCTAssertNil(turn.harnessID, "a harness_id key would make the server ignore the model")
        XCTAssertEqual(turn.model, "claude-haiku-5-5")
        XCTAssertEqual(turn.provider, "anthropic")
    }

    func testWidgetOverrideWinsOverButtonChoice() {
        XCTAssertEqual(ActionAgent.turn(choice: .harness("deep"), override: .harness("fast"), defaultHarness: "single"),
                       TurnChoice(harnessID: "fast"))
        XCTAssertEqual(ActionAgent.turn(choice: .harness("deep"), override: .model(id: "m", provider: "p"),
                                        defaultHarness: "single"),
                       TurnChoice(model: "m", provider: "p"))
    }

    func testWidgetOverrideDefaultBeatsAButtonHarness() {
        XCTAssertEqual(ActionAgent.turn(choice: .harness("deep"), override: .default, defaultHarness: "fast-claude"),
                       TurnChoice(harnessID: "fast-claude"))
    }

    func testButtonsGetTheirOwnChatKeyAndGesturesShareRing() {
        var b = ControlButton(id: "b1", name: "Plan my day", symbol: "bolt.fill", action: .prompt("plan"))
        let context = RingActionContext.button(b, widgetAgent: nil, physical: true)
        XCTAssertEqual(context.chatKey, "button.b1")
        XCTAssertEqual(context.chatTitle, "Plan my day")
        b.name = ""
        XCTAssertEqual(RingActionContext.button(b, widgetAgent: nil, physical: true).chatTitle, "Jarvis button")
        XCTAssertEqual(RingActionContext.ring.chatKey, "ring.inputs")
        XCTAssertEqual(RingActionContext.ring.chatTitle, "Ring")
        XCTAssertFalse(RingActionContext.ring.physical, "ring gestures never skip Face ID")
    }

    func testWidgetAgentJSONShapes() throws {
        let cases: [(WidgetAgent, String)] = [
            (.default, #"{"kind":"default"}"#),
            (.harness("deep"), #"{"id":"deep","kind":"harness"}"#),
            (.model(id: "m", provider: "p"), #"{"id":"m","kind":"model","provider":"p"}"#),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        for (agent, json) in cases {
            XCTAssertEqual(String(decoding: try encoder.encode(agent), as: UTF8.self), json)
            XCTAssertEqual(try JSONDecoder().decode(WidgetAgent.self, from: Data(json.utf8)), agent)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(WidgetAgent.self, from: Data(#"{"kind":"nope"}"#.utf8)))
    }

    func testAWidgetsOverrideIsSavedInItsDesign() throws {
        var draft = WidgetDesignDraft.blank(name: "Home")
        draft.agent = .harness("fast")
        let design = try JSONDecoder().decode(JCDesign.self, from: draft.compile())
        XCTAssertEqual(design.agent, .harness("fast"))
        let back = try JSONDecoder().decode(WidgetDesignDraft.self, from: JSONEncoder().encode(draft))
        XCTAssertEqual(back.agent, .harness("fast"))
        draft.agent = nil
        let plain = try JSONSerialization.jsonObject(with: draft.compile()) as? [String: Any]
        XCTAssertNil(plain?["agent"], "no override = each button's own choice")
        XCTAssertNil(try JSONDecoder().decode(JCDesign.self, from: draft.compile()).agent)
    }
}

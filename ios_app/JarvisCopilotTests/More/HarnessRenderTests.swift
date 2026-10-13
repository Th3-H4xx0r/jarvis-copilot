import SwiftUI
import XCTest
@testable import JarvisCopilot

/// The harness screens, drawn before they reach a phone (PNGs in /tmp/ringshots).
@MainActor
final class HarnessRenderTests: XCTestCase {
    private let size = CGSize(width: 402, height: 874)

    private func seed() -> [AgentHarness] {
        let json = """
        {"harnesses":[
         {"id":"fast-claude","name":"Fast + Claude","icon":"⚡","builtin":true,
          "nodes":[{"id":"in","type":"message","x":40,"y":40},
                   {"id":"fast","type":"answer","model":"@ollama-cloud:gemma4:31b","tools":"lean","x":40,"y":180},
                   {"id":"claude","type":"background","model":"@claude-code:claude-sonnet-5-5","tools":"all","deliver":"speak_or_notify","x":210,"y":320}],
          "edges":[{"from":"in","to":"fast","when":"always"},{"from":"fast","to":"claude","when":"handoff"}],"problems":[]},
         {"id":"router","name":"Router","icon":"🧭","builtin":true,
          "nodes":[{"id":"in","type":"message","x":40,"y":40},
                   {"id":"route","type":"route","by":"rules","labels":["deep"],"rules":[{"match":"keywords","value":"code, bug","label":"deep"}],"x":40,"y":160},
                   {"id":"fast","type":"answer","model":"@ollama-cloud:gemma4:31b","tools":"lean","x":0,"y":300},
                   {"id":"claude","type":"answer","model":"@claude-code:claude-sonnet-5-5","tools":"all","x":200,"y":300}],
          "edges":[{"from":"in","to":"route","when":"always"},{"from":"route","to":"claude","when":"label:deep"},{"from":"route","to":"fast","when":"default"}],"problems":[]},
         {"id":"mine","name":"My research","icon":"🔬",
          "nodes":[{"id":"in","type":"message","x":40,"y":40},
                   {"id":"answer-1","type":"answer","model":"","tools":"lean","x":40,"y":180}],
          "edges":[{"from":"in","to":"answer-1","when":"always"}],
          "problems":[{"node":"answer-1","edge":null,"message":"Pick a model for this node."}]}],
         "assignments":{"voice":"fast-claude","chat":"router"}}
        """.data(using: .utf8)!
        let snap = try! JSONDecoder().decode(HarnessSnapshot.self, from: json)
        HarnessStore.shared.apply(snap)
        return snap.harnesses
    }

    func testRenderHarnessScreens() throws {
        let all = seed()
        try RenderHarness.write(NavigationStack { HarnessesPage() }, size: size, name: "harness-list")
        try RenderHarness.write(NavigationStack { HarnessEditorView(harness: all[0]) }, size: size, name: "harness-editor-fast-claude")
        try RenderHarness.write(NavigationStack { HarnessEditorView(harness: all[1]) }, size: size, name: "harness-editor-router")
        try RenderHarness.write(NavigationStack { HarnessEditorView(harness: all[2]) }, size: size, name: "harness-editor-problem")
        try RenderHarness.write(HarnessSheet(surface: .chat, current: "router", onSelect: { _ in }, onSingleModel: {}),
                                size: size, name: "harness-sheet")
        try RenderHarness.write(HarnessSheet(surface: .voice, current: "", onSelect: { _ in }, onSingleModel: {},
                                             onSameAsDefault: {}),
                                size: size, name: "harness-sheet-voice-default")
        try RenderHarness.write(NavigationStack { DefaultChoiceScreen() }, size: size, name: "settings-default")
    }

    /// Sonnet --hands--> Computer --stuck--> Sonnet, and the Computer step's sheet.
    func testRenderComputerNode() throws {
        _ = seed()
        let json = """
        {"id":"mac","name":"Mac","icon":"🖥","nodes":[
          {"id":"in","type":"message","x":40,"y":40},
          {"id":"sonnet","type":"answer","model":"@anthropic-api:claude-sonnet-5-5","tools":"lean","x":40,"y":180},
          {"id":"computer-1","type":"computer","label":"Mac","model":"@celeris:celeris-1-decision","max_steps":30,"x":120,"y":360}],
         "edges":[{"from":"in","to":"sonnet","when":"always"},{"from":"sonnet","to":"computer-1","when":"hands"},
                  {"from":"computer-1","to":"sonnet","when":"stuck"}]}
        """.data(using: .utf8)!
        let h = try JSONDecoder().decode(AgentHarness.self, from: json)
        try RenderHarness.write(NavigationStack { HarnessEditorView(harness: h) }, size: size, name: "harness-editor-computer")
        try RenderHarness.write(HarnessNodeSheet(harness: .constant(h), nodeID: "computer-1", readOnly: false, problems: []),
                                size: size, name: "harness-node-computer")
    }
}

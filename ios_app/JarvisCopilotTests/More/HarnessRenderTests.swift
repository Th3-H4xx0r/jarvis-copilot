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
        HarnessStore.shared.harnesses = snap.harnesses
        HarnessStore.shared.assignments = snap.assignments
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
    }
}

import SwiftUI
import UIKit
import XCTest
@testable import JarvisCopilot

/// The Agents tab on screen, with sample data, for looking at it: each scene
/// hosts the real `AgentsPage` (its stores fed through a mocked server) in a
/// window on the simulator and holds it while a screenshot is taken.
///
/// Skipped unless `AGENTS_SHOTS_DIR` is set (pass it to xcodebuild as
/// `TEST_RUNNER_AGENTS_SHOTS_DIR`). For each scene the test writes
/// `<dir>/<scene>.ready`, then waits for `<dir>/<scene>.done` — the script that
/// runs `xcrun simctl io <udid> screenshot <dir>/<scene>.png` creates it.
@MainActor
final class AgentsScreensTests: XCTestCase {

    private var dir: URL?

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["AGENTS_SHOTS_DIR"], !path.isEmpty else {
            throw XCTSkip("Set AGENTS_SHOTS_DIR to take the Agents screenshots")
        }
        dir = URL(fileURLWithPath: path)
    }

    // MARK: scenes

    func testScreens() async throws {
        try await scene("01-list") { _ in }
        try await scene("02-session-transcript", open: Fx.working) { store in
            await store.send("Then open a PR with the fix", to: Fx.working, prompts: [])
        }
        try await scene("03-session-approval", open: Fx.approval)
        try await scene("04-session-question", open: Fx.thinking, requests: [Fx.question])
        try await scene("05-session-mac-asleep", open: Fx.asleep)
        try await components("06-components")
        try await scene("07-empty", list: Fx.emptyList, requests: [], usage: false)
    }

    // MARK: harness

    private func scene(_ name: String, open: String? = nil,
                       list: [String: Any] = Fx.list, requests: [[String: Any]] = [Fx.approvalRequest],
                       usage: Bool = true,
                       prepare: (AgentsStore) async -> Void = { _ in }) async throws {
        let (client, transport) = JarvisAPI.mocked()
        var payload = list
        if usage {
            payload["usage"] = Fx.claudeUsage
            payload["usage_codex"] = Fx.codexUsage
        }
        transport.route("/api/coding/agents/list", json: payload)
        transport.route("/api/coding/permission/pending", json: ["pending": requests])
        transport.route("/api/coding/agents/send", json: ["delivery": ["state": "queued"]])
        transport.route("/api/coding/agents/messages", json: Fx.transcript(open ?? ""))
        let topics = BridgeTopics()
        topics.send = { _ in }
        let store = AgentsStore(api: AgentsAPI(api: client), topics: topics)
        await store.refresh()
        await prepare(store)
        if let open { store.requestOpen(open) }
        let router = AppRouter()
        router.selectedTab = .agents
        try await hold(name, AgentsPage(store: store).environment(router))
    }

    /// The pieces that only show their best side once tapped open.
    private func components(_ name: String) async throws {
        let edit = AgentFileEdit(tool: CodingChatTool(name: "Edit", summary: Fx.cwd + "/src/payments/client.ts",
                                                      diff: Fx.diff))
        let failing = AgentToolItem(tool: "Bash", line: AgentToolPhrase.line(tool: "Bash", summary: "npm test -- checkout"),
                                    output: Fx.failOutput, failed: true, running: false)
        let fold = (0..<6).map { i in
            AgentToolItem(tool: i < 4 ? "Read" : "Grep",
                          line: AgentToolPhrase.line(tool: i < 4 ? "Read" : "Grep", summary: "/w/file\(i).ts"),
                          output: "", failed: false, running: false)
        }
        let view = NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    AgentToolRow(item: failing, startOpen: true)
                    AgentEditCard(edit: edit, cwd: Fx.cwd, startOpen: true)
                    AgentToolGroupRow(summary: AgentToolPhrase.groupSummary(fold.map(\.tool)), items: fold)
                    AgentWorkingRow(text: "Running npm test…")
                }
                .padding(.vertical, 12)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                AgentComposer(placeholder: "Reply to Claude Code…", working: true) { _ in }
            }
            .background(JcTheme.bg.ignoresSafeArea())
            .navigationTitle("Pieces")
            .navigationBarTitleDisplayMode(.inline)
        }
        try await hold(name, view)
    }

    private func hold(_ name: String, _ view: some View) async throws {
        let dir = try XCTUnwrap(dir)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try XCTUnwrap(scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .normal + 1
        let host = UIHostingController(rootView: AnyView(
            view.preferredColorScheme(.dark).tint(JcTheme.accent)))
        host.view.backgroundColor = .black
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        try await Task.sleep(nanoseconds: 3_000_000_000)
        let ready = dir.appendingPathComponent("\(name).ready")
        let done = dir.appendingPathComponent("\(name).done")
        try? FileManager.default.removeItem(at: done)
        FileManager.default.createFile(atPath: ready.path, contents: Data())
        let deadline = Date().addingTimeInterval(90)
        while !FileManager.default.fileExists(atPath: done.path) && Date() < deadline {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        try? FileManager.default.removeItem(at: ready)
    }
}

// MARK: - Sample data

/// Conversations, a Mac-asleep card, a waiting approval, a question, plan
/// usage and transcripts that read like a real afternoon with the agents.
private enum Fx {
    static let now = Date().timeIntervalSince1970
    static let cwd = "/Users/pranav/code/storefront"

    static let working = "claude|s1"
    static let approval = "claude|s2"
    static let thinking = "codex|s3"
    static let asleep = "claude|s4"

    static func conv(_ ckey: String, state: String, project: String, title: String, step: String = "",
                     ago: Double, owner: String = "server", status: String = "live",
                     pending: String? = nil, canSend: Bool = true) -> [String: Any] {
        let agent = ckey.components(separatedBy: "|").first ?? "claude"
        var c: [String: Any] = [
            "ckey": ckey, "key": "d1|\(ckey)", "agent": agent, "session_id": "4f1c2b7e-\(ckey.suffix(2))-9a3d",
            "title": title, "project_id": "p-\(project)", "project": project,
            "cwd": project == "storefront" ? cwd : "/Users/pranav/code/\(project)",
            "owner": owner, "owner_name": owner == "server" ? "Server" : "MacBook",
            "status": status, "state": status == "live" ? state : status, "step": step,
            "model": agent == "codex" ? "gpt-5-codex" : "claude-opus-5-5",
            "last_event_at": now - ago, "terminal_app": "vscode",
            "can_send": canSend, "can_continue_server": status == "asleep",
            "can_terminal": owner == "server" && status == "live",
        ]
        if let pending { c["pending"] = ["kind": "approval", "fingerprint": pending] }
        return c
    }

    static let list: [String: Any] = [
        "card": ["device_id": "d1", "device_name": "MacBook", "kind": "sleep", "since": now - 17 * 60,
                 "sessions": [
                    ["ckey": asleep, "title": "Fix CarPlay mic hand-off", "project": "jarvis-copilot",
                     "was": "working", "agent": "claude"],
                    ["ckey": "claude|s7", "title": "Refactor order router", "project": "IntelliStock",
                     "was": "approval", "agent": "claude"],
                 ] as [[String: Any]]] as [String: Any],
        "needs_you": [
            conv(approval, state: "approval", project: "jarvis-copilot", title: "Migrate push tokens",
                 ago: 60, pending: "fp-r1"),
        ],
        "projects": [
            ["id": "p-storefront", "name": "storefront", "sessions": [
                conv(working, state: "working", project: "storefront",
                     title: "Fix the flaky checkout test", step: "Bash: npm test", ago: 12),
                conv(thinking, state: "thinking", project: "storefront",
                     title: "Add rate limiting to /v1/search", ago: 240, owner: "d1"),
            ]] as [String: Any],
            ["id": "p-jarvis-copilot", "name": "jarvis-copilot", "sessions": [
                conv(asleep, state: "working", project: "jarvis-copilot", title: "Fix CarPlay mic hand-off",
                     ago: 17 * 60, owner: "d1", status: "asleep", canSend: false),
            ]] as [String: Any],
            ["id": "p-IntelliStock", "name": "IntelliStock", "sessions": [
                conv("claude|s7", state: "approval", project: "IntelliStock", title: "Refactor order router",
                     ago: 17 * 60, owner: "d1", status: "asleep", canSend: false),
                conv("claude|s8", state: "idle", project: "IntelliStock", title: "Tidy the README",
                     ago: 3 * 3600, status: "ended", canSend: false),
            ]] as [String: Any],
        ],
        "ts": now,
    ]

    static let emptyList: [String: Any] = ["card": NSNull(), "needs_you": [] as [Any], "projects": [] as [Any]]

    static let approvalRequest: [String: Any] = [
        "request_id": "r1", "fingerprint": "fp-r1", "kind": "permission", "tool": "Bash",
        "summary": "Bash: rm -rf build DerivedData && xcodebuild -scheme JarvisWidget build",
        "command": "rm -rf build DerivedData && xcodebuild -scheme JarvisWidget build",
        "project": "jarvis-copilot", "key": "d1|" + approval, "agent": "claude", "can_always": true, "created": now - 95,
    ]

    static let question: [String: Any] = [
        "request_id": "r2", "fingerprint": "fp-r2", "kind": "ask", "tool": "AskUserQuestion",
        "project": "storefront", "key": "d1|" + thinking, "agent": "codex", "created": now - 30,
        "questions": [[
            "question": "Where should the rate limit live?", "header": "Rate limiting", "multiSelect": false,
            "options": [
                ["label": "API gateway", "description": "One limit for every service behind it"],
                ["label": "In the search service", "description": "Per-endpoint limits, kept in Redis"],
            ],
        ] as [String: Any]],
    ]

    static let claudeUsage: [String: Any] = [
        "five_hour": ["used_percentage": 34, "resets_at": now + 2 * 3600 + 900],
        "seven_day": ["used_percentage": 61, "resets_at": now + 3 * 86_400],
    ]
    static let codexUsage: [String: Any] = [
        "five_hour": ["used_percentage": 7, "resets_at": now + 4 * 3600],
        "seven_day": ["used_percentage": 18, "resets_at": now + 5 * 86_400],
    ]

    static let diff = [
        "@@ -41,9 +41,11 @@",
        "  async pay(order: Order) {",
        "-    const res = await this.http.post('/pay', order)",
        "-    await this.events.subscribe(order.id)",
        "+    // Subscribe first so a fast mock can't beat us to the event.",
        "+    const done = this.events.subscribe(order.id)",
        "+    const res = await this.http.post('/pay', order)",
        "+    await done",
        "     return res.json()",
        "   }",
    ]

    static let failOutput = """
    FAIL tests/checkout.spec.ts
      ✕ completes an order (5012 ms)
        Timeout - Async callback was not invoked within the 5000 ms timeout
    Tests: 1 failed, 23 passed, 24 total
    """

    static func transcript(_ key: String) -> [String: Any] {
        if key == approval {
            return ["total": 2, "activity_state": "waiting", "status": "running", "messages": [
                ["i": 0, "role": "user", "text": "Clean the build folders and rebuild the widget"],
                ["i": 1, "role": "assistant",
                 "text": "The widget is still linking an old copy of `JarvisShared`. I'll clear the build products and rebuild the widget target from scratch.",
                 "tools": [
                    ["name": "Bash", "summary": "du -sh build DerivedData", "output": "6.2G\tbuild\n1.1G\tDerivedData", "ok": true],
                    ["name": "Read", "summary": "/Users/pranav/code/jarvis-copilot/ios_app/scripts/build-widget.sh", "output": "#!/bin/bash", "ok": true],
                 ] as [[String: Any]]] as [String: Any],
            ]]
        }
        return ["total": 4, "activity_state": "working", "status": "running",
                "status_line": "✳ Zesting… (50s · ↑ 2.0k tokens)", "messages": [
            ["i": 0, "role": "user", "text": "Fix the flaky checkout test and make CI green"],
            ["i": 1, "role": "assistant",
             "text": "The test was racing the payment mock: `waitForPayment()` resolved before the client subscribed, so now and then the order never completed.\n\nThe client now subscribes **before** it sends the request, and the mock answers after a fixed delay.",
             "tools": [
                ["name": "Read", "summary": cwd + "/tests/checkout.spec.ts", "output": "describe('checkout', …)", "ok": true],
                ["name": "Grep", "summary": "waitForPayment", "output": "src/payments/client.ts:44", "ok": true],
                ["name": "Bash", "summary": "npm test -- checkout", "output": failOutput, "ok": false],
                ["name": "Edit", "summary": cwd + "/src/payments/client.ts", "output": "", "ok": true, "diff": diff],
                ["name": "Bash", "summary": "npm test -- checkout", "output": "PASS tests/checkout.spec.ts", "ok": true],
             ] as [[String: Any]]] as [String: Any],
            ["i": 2, "role": "user", "text": "Nice. Run the whole suite too"],
            ["i": 3, "role": "assistant", "text": "", "tools": [
                ["name": "Bash", "summary": "npm test", "output": "", "ok": NSNull()],
            ] as [[String: Any]]] as [String: Any],
        ]]
    }
}

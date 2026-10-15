import XCTest
@testable import JarvisCopilot

/// A session's conversation as the session screen draws it, from the full
/// transcript or from the agent's own last turn.
final class AgentConversationTests: XCTestCase {

    // MARK: tool lines

    func testToolLinesReadLikeSentences() {
        XCTAssertEqual(AgentToolPhrase.line(tool: "Read", summary: "/Users/p/app/src/app.ts").text, "Read app.ts")
        XCTAssertEqual(AgentToolPhrase.line(tool: "Bash", summary: "npm test\nmore").text, "Ran npm test")
        XCTAssertEqual(AgentToolPhrase.line(tool: "Edit", summary: "/w/a.py").text, "Edited a.py")
        XCTAssertEqual(AgentToolPhrase.line(tool: "Write", summary: "/w/new.md").text, "Wrote new.md")
        XCTAssertEqual(AgentToolPhrase.line(tool: "Grep", summary: "loginHandler").text, "Searched for loginHandler")
        XCTAssertEqual(AgentToolPhrase.line(tool: "WebFetch", summary: "https://docs.swift.org/x").text,
                       "Fetched docs.swift.org")
        XCTAssertEqual(AgentToolPhrase.line(tool: "TodoWrite", summary: "").text, "Updated the plan")
        XCTAssertEqual(AgentToolPhrase.line(tool: "mcp__github__search_issues", summary: "").text,
                       "Used github search issues")
        XCTAssertEqual(AgentToolPhrase.line(tool: "Frobnicate", summary: "x").text, "Used Frobnicate x")
    }

    func testTheHooksPrefixIsDropped() {
        // The hooks write "Bash: npm test"; the transcript writes "npm test".
        XCTAssertEqual(AgentToolPhrase.detail(tool: "Bash", summary: "Bash: npm test"), "npm test")
        XCTAssertEqual(AgentToolPhrase.detail(tool: "Read", summary: "Read app.ts"), "app.ts")
        XCTAssertEqual(AgentToolPhrase.detail(tool: "Bash", summary: "npm test"), "npm test")
        XCTAssertEqual(AgentToolPhrase.line(tool: "Bash", summary: "Bash: npm test").text, "Ran npm test")
    }

    func testTenses() {
        XCTAssertEqual(AgentToolPhrase.line(tool: "Bash", summary: "make", tense: .progressive).text, "Running make")
        XCTAssertEqual(AgentToolPhrase.line(tool: "Bash", summary: "make", tense: .imperative).text, "run make")
        XCTAssertEqual(AgentToolPhrase.line(tool: "Edit", summary: "/a.py", tense: .imperative).text, "edit a.py")
        XCTAssertTrue(AgentToolPhrase.line(tool: "Bash", summary: "make").monospaced)
        XCTAssertFalse(AgentToolPhrase.line(tool: "Read", summary: "/a.py").monospaced)
    }

    func testGroupSummaryCountsByKind() {
        XCTAssertEqual(AgentToolPhrase.groupSummary(["Read", "Read", "Bash", "Grep", "Read"]),
                       "Read 3 files, ran 1 command, ran 1 search")
        XCTAssertEqual(AgentToolPhrase.groupSummary(["Bash", "Bash"]), "Ran 2 commands")
        XCTAssertEqual(AgentToolPhrase.groupSummary(["Read", "Bash", "Grep", "WebFetch", "Task"]),
                       "Read 1 file, ran 1 command, ran 1 search and 2 more")
    }

    // MARK: file edits

    func testATranscriptDiffBecomesAnEditCard() {
        let tool = CodingChatTool(name: "Edit", summary: "/w/src/a.py",
                                  diff: ["@@ -1,3 +1,3 @@", " x = 1", "-y = 2", "+y = 3", "+z = 4"])
        let edit = AgentFileEdit(tool: tool)
        XCTAssertEqual(edit.name, "a.py")
        XCTAssertEqual(edit.added, 2)
        XCTAssertEqual(edit.removed, 1)
        XCTAssertEqual(edit.lines.map(\.kind), [.gap, .context, .removed, .added, .added])
        XCTAssertEqual(edit.lines[1].text, "x = 1")
        XCTAssertEqual(edit.lines[3].text, "y = 3")
        XCTAssertFalse(edit.truncated)
    }

    func testAWrittenFileCountsTheLinesItLeftOut() {
        let tool = CodingChatTool(name: "Write", summary: "/w/new.md",
                                  diff: ["+# Title", "+body", "… +40 more lines"])
        let edit = AgentFileEdit(tool: tool)
        XCTAssertTrue(edit.isNew)
        XCTAssertTrue(edit.truncated)
        XCTAssertEqual(edit.added, 42)
        XCTAssertEqual(edit.lines.count, 2)
    }

    // MARK: transcript

    private let messages: [CodingChatMessage] = [
        CodingChatMessage(i: 0, role: "user", text: "fix the login test"),
        CodingChatMessage(i: 1, role: "assistant", text: "Fixed: the token was stale.", tools: [
            CodingChatTool(id: 0, name: "Read", summary: "/w/login.ts", output: "…"),
            CodingChatTool(id: 1, name: "Edit", summary: "/w/login.ts", diff: ["-a", "+b"]),
            CodingChatTool(id: 2, name: "Bash", summary: "npm test", output: "ok", ok: true, running: true),
        ]),
    ]

    func testTranscriptItemsInOrder() {
        let items = AgentConversation.items(messages, working: false)
        XCTAssertEqual(items.map(\.id), ["m0", "m1-t0", "m1-t1", "m1-t2", "m1-x"])
        guard case .prompt(_, let text) = items[0] else { return XCTFail("\(items[0])") }
        XCTAssertEqual(text, "fix the login test")
        guard case .edit(_, let edit) = items[2] else { return XCTFail("\(items[2])") }
        XCTAssertEqual(edit.name, "login.ts")
        guard case .text(_, let answer) = items[4] else { return XCTFail("\(items[4])") }
        XCTAssertEqual(answer, "Fixed: the token was stale.")
        XCTAssertEqual(AgentConversation.prompts(items), ["fix the login test"])
    }

    func testOnlyTheLastMessagesOpenToolSpinsAndOnlyWhileWorking() {
        guard case .tool(_, let done) = AgentConversation.items(messages, working: false)[3] else { return XCTFail() }
        XCTAssertFalse(done.running)
        XCTAssertEqual(done.line.text, "Ran npm test")
        guard case .tool(_, let live) = AgentConversation.items(messages, working: true)[3] else { return XCTFail() }
        XCTAssertTrue(live.running)
        XCTAssertEqual(live.line.text, "Running npm test")
    }

    // MARK: last turn

    func testLastTurnItemsPutEachFileCardWhereItWasEdited() {
        let turn = AgentTurn(json: [
            "prompt": "fix it", "final": "Done.",
            "actions": [
                ["tool": "Read", "summary": "Read: /w/a.py", "output": "x"] as [String: Any],
                ["tool": "Edit", "summary": "Edit: /w/a.py", "file": 0] as [String: Any],
                ["tool": "Edit", "summary": "Edit: /w/a.py", "file": 0] as [String: Any],
                ["tool": "Bash", "summary": "Bash: make", "output": "boom", "failed": true] as [String: Any],
            ],
            "files": [
                ["path": "/w/a.py", "added": 2, "removed": 1, "lines": [["k": "+", "t": "y"]]] as [String: Any],
                ["path": "/w/b.py", "added": 5, "removed": 0, "new": true, "lines": []] as [String: Any],
            ],
        ])
        let items = AgentConversation.items(turn, working: false)
        XCTAssertEqual(items.map(\.id), ["prompt", "a0", "file0", "a3", "file1", "final"])
        guard case .edit(_, let a) = items[2] else { return XCTFail() }
        XCTAssertEqual(a.added, 2)
        guard case .tool(_, let failed) = items[3] else { return XCTFail() }
        XCTAssertTrue(failed.failed)
        XCTAssertEqual(failed.output, "boom")
        guard case .edit(_, let b) = items[4] else { return XCTFail() }
        XCTAssertTrue(b.isNew)
        XCTAssertFalse(turn.isEmpty)
        XCTAssertTrue(AgentTurn(json: [:]).isEmpty)
    }

    func testTheLastActionSpinsWhileTheTurnRuns() {
        let turn = AgentTurn(json: ["prompt": "go", "actions": [
            ["tool": "Read", "summary": "Read: /a", "output": "x"] as [String: Any],
            ["tool": "Bash", "summary": "Bash: make", "output": ""] as [String: Any],
        ]])
        guard case .tool(_, let last) = AgentConversation.items(turn, working: true).last else { return XCTFail() }
        XCTAssertTrue(last.running)
        guard case .tool(_, let idle) = AgentConversation.items(turn, working: false).last else { return XCTFail() }
        XCTAssertFalse(idle.running)
    }

    // MARK: collapsing

    private func tool(_ id: String, _ name: String, running: Bool = false) -> AgentConversationItem {
        .tool(id: id, AgentToolItem(tool: name, line: AgentToolPhrase.line(tool: name, summary: "x"),
                                    output: "", failed: false, running: running))
    }

    func testLongRunsOfToolsFoldIntoOneRow() {
        let items: [AgentConversationItem] = [
            .prompt(id: "p", text: "go"),
            tool("t1", "Read"), tool("t2", "Read"), tool("t3", "Bash"), tool("t4", "Grep"),
            .text(id: "x", text: "done"),
            tool("t5", "Read"), tool("t6", "Bash"),
        ]
        let folded = AgentConversation.collapse(items, threshold: 4)
        XCTAssertEqual(folded.map(\.id), ["p", "t1…t4", "x", "t5", "t6"])
        guard case .tools(_, let summary, let inner) = folded[1] else { return XCTFail() }
        XCTAssertEqual(summary, "Read 2 files, ran 1 command, ran 1 search")
        XCTAssertEqual(inner.count, 4)
    }

    func testOneSpinnerAtATime() {
        // The working row stands down while the last row is a running tool.
        XCTAssertTrue(AgentConversation.endsInRunningTool([tool("t1", "Read"), tool("t2", "Bash", running: true)]))
        XCTAssertFalse(AgentConversation.endsInRunningTool([tool("t1", "Bash", running: true), .text(id: "x", text: "ok")]))
        XCTAssertFalse(AgentConversation.endsInRunningTool([]))
    }

    func testTheRunningToolStaysOutOfTheFold() {
        let items = [tool("t1", "Read"), tool("t2", "Read"), tool("t3", "Read"), tool("t4", "Read"),
                     tool("t5", "Bash", running: true)]
        XCTAssertEqual(AgentConversation.collapse(items, threshold: 4).map(\.id), ["t1…t4", "t5"])
        // Below the threshold once the running one stays out: nothing folds.
        let short = [tool("t1", "Read"), tool("t2", "Read"), tool("t3", "Read"), tool("t4", "Bash", running: true)]
        XCTAssertEqual(AgentConversation.collapse(short, threshold: 4).map(\.id), ["t1", "t2", "t3", "t4"])
    }
}

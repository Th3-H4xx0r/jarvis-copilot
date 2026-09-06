import XCTest
@testable import JarvisCopilot

private func obj(_ json: String) -> [String: Any] {
    (try! JSONSerialization.jsonObject(with: Data(json.utf8))) as! [String: Any]
}

final class CodingChatModelsTests: XCTestCase {

    // MARK: - Transcript page

    private let page = #"""
    {
      "messages": [
        {"i": 0, "role": "user", "text": "port the coding tab", "ts": 1781006400},
        {"i": 1, "role": "assistant", "text": "On it.", "ts": 1781006405.5,
         "tools": [
           {"name": "Read", "summary": "coding_models.dart", "output": "773 lines", "ok": true},
           {"name": "Edit", "summary": "CodingModels.swift", "ok": false,
            "diff": ["@@ -1 +1 @@", "-old", "+new"]},
           {"name": "Task", "summary": "explore the repo", "subagent_type": "Explore"},
           {"name": "Bash", "summary": "swift build"}
         ]},
        "junk"
      ],
      "total": 2,
      "activity_state": "working",
      "status": "running",
      "source": "live",
      "status_line": "✳ Zesting… (50s · ↑ 2.0k tokens)",
      "context": {"used": 124500, "window": 200000, "pct": 62, "model": "opus"}
    }
    """#

    func testParsesATranscriptPage() {
        let p = CodingChatPage(json: obj(page))
        XCTAssertEqual(p.messages.count, 2, "non-object rows are dropped")
        XCTAssertEqual(p.total, 2)
        XCTAssertEqual(p.activityState, "working")
        XCTAssertEqual(p.status, "running")
        XCTAssertEqual(p.source, "live")
        XCTAssertEqual(p.statusLine, "✳ Zesting… (50s · ↑ 2.0k tokens)")
        XCTAssertEqual(p.context?.used, 124500)

        let user = p.messages[0]
        XCTAssertTrue(user.isUser)
        XCTAssertEqual(user.id, 0)
        XCTAssertEqual(user.ts, 1781006400)

        let assistant = p.messages[1]
        XCTAssertFalse(assistant.isUser)
        XCTAssertEqual(assistant.text, "On it.")
        XCTAssertEqual(assistant.tools.map(\.id), [0, 1, 2, 3], "tool ids are their position")
        XCTAssertEqual(assistant.tools[0].output, "773 lines")
        XCTAssertTrue(assistant.tools[0].ok)
        XCTAssertFalse(assistant.tools[0].running)
        XCTAssertFalse(assistant.tools[1].ok)
        XCTAssertEqual(assistant.tools[1].diff, ["@@ -1 +1 @@", "-old", "+new"])
        XCTAssertTrue(assistant.tools[2].isSubagent)
        XCTAssertEqual(assistant.tools[2].subagentType, "Explore")
    }

    func testAMissingOkMeansStillRunning() {
        // The server sends `ok: null` while a tool/subagent is in flight.
        let running = CodingChatTool(json: obj(#"{"name":"Bash","summary":"npm i"}"#))
        XCTAssertTrue(running.running)
        XCTAssertTrue(running.ok, "optimistically ok so it doesn't render red mid-flight")
        let explicitNull = CodingChatTool(json: obj(#"{"name":"Bash","ok":null}"#))
        XCTAssertTrue(explicitNull.running)
        let done = CodingChatTool(json: obj(#"{"name":"Bash","ok":0}"#))
        XCTAssertFalse(done.running)
        XCTAssertFalse(done.ok)
    }

    func testSubagentDetection() {
        XCTAssertTrue(CodingChatTool(name: "Task").isSubagent)
        XCTAssertTrue(CodingChatTool(name: "Agent").isSubagent)
        XCTAssertTrue(CodingChatTool(name: "Whatever", subagentType: "Explore").isSubagent)
        XCTAssertFalse(CodingChatTool(name: "Bash").isSubagent)
    }

    func testMessageDefaults() {
        let m = CodingChatMessage(json: [:])
        XCTAssertEqual(m.i, 0)
        XCTAssertEqual(m.role, "assistant")
        XCTAssertEqual(m.text, "")
        XCTAssertTrue(m.tools.isEmpty)
        XCTAssertNil(m.ts)
        XCTAssertEqual(CodingChatTool(json: [:]).name, "tool")
    }

    func testEmptyPage() {
        let p = CodingChatPage(json: [:])
        XCTAssertTrue(p.messages.isEmpty)
        XCTAssertEqual(p.total, 0)
        XCTAssertNil(p.activityState)
        XCTAssertEqual(p.status, "")
        XCTAssertNil(p.context)
    }

    // MARK: - Context gauge

    func testContextNeedsAWindow() {
        XCTAssertNil(ChatContext.from(nil))
        XCTAssertNil(ChatContext.from(obj(#"{"c":{"used":10}}"#)["c"]), "no window ⇒ no gauge")
        XCTAssertNil(ChatContext.from(obj(#"{"c":{"used":10,"window":0}}"#)["c"]))
        let c = ChatContext.from(obj(#"{"c":{"used":124500,"window":200000,"pct":62}}"#)["c"])
        XCTAssertEqual(c?.pct, 62)
        XCTAssertNil(c?.model)
    }

    func testTokenFormatting() {
        XCTAssertEqual(ChatContext.fmtTokens(0), "0")
        XCTAssertEqual(ChatContext.fmtTokens(999), "999")
        XCTAssertEqual(ChatContext.fmtTokens(1000), "1k")
        XCTAssertEqual(ChatContext.fmtTokens(124500), "125k")
        XCTAssertEqual(ChatContext.fmtTokens(1_500_000), "1.5M")
        let c = ChatContext(used: 124500, window: 200000, pct: 62)
        XCTAssertEqual(c.usedLabel, "125k")
        XCTAssertEqual(c.windowLabel, "200k")
    }

    // MARK: - LiveStatus

    func testLiveStatusNeedsAtLeastAVerb() {
        XCTAssertNil(LiveStatus.parse(nil))
        XCTAssertNil(LiveStatus.parse(""))
        XCTAssertNil(LiveStatus.parse("   "))
    }

    func testLiveStatusSplitsTheFullLine() {
        let s = LiveStatus.parse("✳ Moonwalking… (3m 22s · ↓ 19.5k tokens · …xhigh effort)")
        XCTAssertEqual(s?.verb, "Moonwalking…")
        XCTAssertEqual(s?.elapsed, "3m 22s")
        XCTAssertEqual(s?.tokens, "↓ 19.5k tokens")
        XCTAssertEqual(s?.effort, "…xhigh effort")
        XCTAssertEqual(s?.extra, [])
    }

    func testLiveStatusWithoutParenthesesIsJustAVerb() {
        let s = LiveStatus.parse("⏺ Working")
        XCTAssertEqual(s?.verb, "Working")
        XCTAssertNil(s?.elapsed)
        XCTAssertNil(s?.tokens)
    }

    func testLiveStatusUnclassifiedSegmentsBecomeExtra() {
        let s = LiveStatus.parse("✻ Thinking… (12s · esc to interrupt)")
        XCTAssertEqual(s?.verb, "Thinking…")
        XCTAssertEqual(s?.elapsed, "12s")
        XCTAssertEqual(s?.extra, ["esc to interrupt"])
    }

    func testLiveStatusFallsBackToWorkingWhenTheVerbIsMissing() {
        let s = LiveStatus.parse("✳ (5s · thinking hard)")
        XCTAssertEqual(s?.verb, "Working")
        XCTAssertEqual(s?.elapsed, "5s")
        XCTAssertEqual(s?.effort, "thinking hard")
    }

    func testLiveStatusIgnoresATrailingParenthesisThatIsNotAtTheEnd() {
        // Without a closing paren the whole line is the verb.
        XCTAssertEqual(LiveStatus.parse("Compacting (almost")?.verb, "Compacting (almost")
    }

    // MARK: - Interactive prompt

    func testPromptParsingAndSignature() {
        let p = CodingPromptState(json: obj(#"""
        {"waiting":1,"question":"Do you want to make this edit?",
         "options":[{"key":"1","label":"Yes"},{"key":"2","label":"Yes, and don't ask again"},{"key":"3","label":"No"}],
         "raw":"╭─ Edit file ─╮"}
        """#))
        XCTAssertTrue(p.waiting)
        XCTAssertEqual(p.options.map(\.key), ["1", "2", "3"])
        XCTAssertEqual(p.options[1].label, "Yes, and don't ask again")
        XCTAssertEqual(p.signature, "Do you want to make this edit?|1,2,3|╭─ Edit file ─╮")

        // Same prompt ⇒ same signature (so a dismissed sheet stays dismissed);
        // a different one differs.
        let again = CodingPromptState(json: obj(#"{"waiting":true,"question":"Do you want to make this edit?","options":[{"key":"1","label":"Yes"},{"key":"2"},{"key":"3"}],"raw":"╭─ Edit file ─╮"}"#))
        XCTAssertEqual(again.signature, p.signature)
        XCTAssertNotEqual(CodingPromptState(json: obj(#"{"waiting":true,"question":"Run this?"}"#)).signature,
                          p.signature)
    }

    func testPromptDefaults() {
        let p = CodingPromptState(json: [:])
        XCTAssertFalse(p.waiting)
        XCTAssertNil(p.question)
        XCTAssertTrue(p.options.isEmpty)
        XCTAssertEqual(p.signature, "||")
    }
}

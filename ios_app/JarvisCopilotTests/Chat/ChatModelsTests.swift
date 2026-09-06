import XCTest
@testable import JarvisCopilot

/// Ported from the Flutter `chat_models.dart` contract: every parse path the
/// server can hand us, and the block mutations a streaming turn performs.
final class ChatModelsTests: XCTestCase {

    // MARK: JSONValue (tool args stay structured AND Equatable)

    func testJSONValueRoundTripsEveryJSONShape() {
        let raw: [String: Any] = [
            "path": "/tmp/x",
            "limit": 20,
            "ratio": 0.5,
            "deep": true,
            "tags": ["a", "b"],
            "nested": ["k": "v"],
            "nothing": NSNull(),
        ]
        let args = JSONValue(raw).objectValue ?? [:]
        XCTAssertEqual(args["path"], .string("/tmp/x"))
        XCTAssertEqual(args["limit"], .number(20))
        XCTAssertEqual(args["ratio"], .number(0.5))
        XCTAssertEqual(args["deep"], .bool(true), "a JSON bool must not decode as the number 1")
        XCTAssertEqual(args["tags"], .array([.string("a"), .string("b")]))
        XCTAssertEqual(args["nested"], .object(["k": .string("v")]))
        XCTAssertEqual(args["nothing"], .null)
    }

    func testJSONValueIntegersDisplayWithoutDecimalPoint() {
        XCTAssertEqual(JSONValue.number(20).displayText, "20")
        XCTAssertEqual(JSONValue.number(0.5).displayText, "0.5")
        XCTAssertEqual(JSONValue.bool(true).displayText, "true")
        XCTAssertEqual(JSONValue.null.displayText, "null")
    }

    func testArgsPreviewLineTakesThreeSortedKeysAndClipsLongValues() {
        let args: [String: JSONValue] = ["zeta": "z", "alpha": "a", "beta": "b", "delta": "d"]
        XCTAssertEqual(args.previewLine, "alpha: a · beta: b · delta: d")

        let long: [String: JSONValue] = ["body": .string(String(repeating: "x", count: 80))]
        XCTAssertTrue(long.previewLine.hasSuffix("…"))
        XCTAssertLessThan(long.previewLine.count, 60)
    }

    func testEmptyArgsHaveNoPreviewLine() {
        XCTAssertEqual([String: JSONValue]().previewLine, "")
    }

    func testArgsPrettyJSONIsIndentedAndSorted() {
        let args: [String: JSONValue] = ["b": 2, "a": 1]
        XCTAssertEqual(args.prettyJSON, "{\n  \"a\" : 1,\n  \"b\" : 2\n}")
    }

    // MARK: ChatSessionSummary

    func testSessionSummaryPrefersSessionIDAndTrimsTitle() {
        let s = ChatSessionSummary(json: ["session_id": "s1", "title": "  Groceries  ", "message_count": 4, "updated_at": 1_700_000_000])
        XCTAssertEqual(s.id, "s1")
        XCTAssertEqual(s.title, "Groceries")
        XCTAssertEqual(s.messageCount, 4)
        XCTAssertEqual(s.updatedAt, 1_700_000_000)
    }

    func testSessionSummaryFallsBackToIDKeyAndLastMessageAt() {
        let s = ChatSessionSummary(json: ["id": "s2", "last_message_at": 99])
        XCTAssertEqual(s.id, "s2")
        XCTAssertEqual(s.updatedAt, 99)
        XCTAssertEqual(s.displayTitle, "New chat", "an untitled session shows the placeholder")
    }

    func testSessionSummaryIsStreamingFromEitherSignal() {
        XCTAssertTrue(ChatSessionSummary(json: ["id": "a", "is_streaming": true]).isStreaming)
        XCTAssertTrue(ChatSessionSummary(json: ["id": "a", "active_stream_id": "x9"]).isStreaming)
        XCTAssertFalse(ChatSessionSummary(json: ["id": "a", "active_stream_id": ""]).isStreaming)
        XCTAssertFalse(ChatSessionSummary(json: ["id": "a"]).isStreaming)
    }

    func testSessionSummaryFlags() {
        let s = ChatSessionSummary(json: ["id": "a", "pinned": true, "archived": true, "model": "m", "model_provider": "p"])
        XCTAssertTrue(s.pinned)
        XCTAssertTrue(s.archived)
        XCTAssertEqual(s.model, "m")
        XCTAssertEqual(s.modelProvider, "p")
    }

    // MARK: Blocks

    func testAppendTokenOpensAFreshTextBlockAfterATool() {
        var m = ChatMessage.assistant()
        m.appendToken("one")
        m.appendToken(" two")
        XCTAssertEqual(m.blocks.count, 1)
        m.startTool(ToolInvocation(name: "search"))
        m.appendToken("after")
        XCTAssertEqual(m.blocks.count, 3)
        XCTAssertEqual(m.plainText, "one two\n\nafter", "text blocks join with a blank line")
    }

    func testCompleteToolMarksTheMostRecentUnfinishedMatch() {
        var m = ChatMessage.assistant()
        m.startTool(ToolInvocation(name: "search"))
        m.startTool(ToolInvocation(name: "search"))
        m.completeTool(name: "search", durationSec: 1.5, isError: false, preview: "3 hits")
        XCTAssertEqual(m.tools.count, 2)
        XCTAssertFalse(m.tools[0].done, "the older call stays open")
        XCTAssertTrue(m.tools[1].done)
        XCTAssertEqual(m.tools[1].durationSec, 1.5)
        XCTAssertEqual(m.tools[1].preview, "3 hits")
    }

    func testCompleteToolIgnoresANameThatNeverStarted() {
        var m = ChatMessage.assistant()
        m.startTool(ToolInvocation(name: "search"))
        m.completeTool(name: "other")
        XCTAssertFalse(m.tools[0].done)
    }

    func testCompleteToolMatchesByServerIDWhenGiven() {
        var m = ChatMessage.assistant()
        m.startTool(ToolInvocation(id: "t1", name: "a"))
        m.startTool(ToolInvocation(id: "t2", name: "b"))
        m.completeTool(id: "t1", name: "a")
        XCTAssertTrue(m.tools[0].done)
        XCTAssertFalse(m.tools[1].done)
    }

    func testCompleteToolWithoutANameClosesTheLatestOpenCall() {
        var m = ChatMessage.assistant()
        m.startTool(ToolInvocation(name: "search"))
        m.completeTool()
        XCTAssertTrue(m.tools[0].done)
    }

    func testDropEmptyTextBlocksKeepsToolsAndRealText() {
        var m = ChatMessage.assistant()
        m.appendToken("   ")
        m.startTool(ToolInvocation(name: "run"))
        m.appendToken("done")
        m.appendToken("")
        m.dropEmptyTextBlocks()
        XCTAssertEqual(m.blocks.count, 2)
        XCTAssertEqual(m.plainText, "done")
    }

    func testIsThinkingOnlyWhileReasoningWithNoVisibleOutput() {
        var m = ChatMessage.assistant(streaming: true)
        XCTAssertFalse(m.isThinking, "no reasoning yet")
        m.reasoning = "hmm"
        XCTAssertTrue(m.isThinking)
        m.appendToken("hi")
        XCTAssertFalse(m.isThinking, "text has arrived")
    }

    func testToolLabelStripsUnderscoresAndDevicePrefix() {
        XCTAssertEqual(ToolInvocation(name: "web_search").label, "web search")
        XCTAssertEqual(ToolInvocation(name: "device_esp32_upload").shortName, "esp32_upload")
    }

    func testToolDetailLinePrefersResultThenPreviewThenArgs() {
        var t = ToolInvocation(name: "read", args: ["path": .string("/tmp/a")])
        XCTAssertEqual(t.detailLine, "path: /tmp/a")
        t.preview = "reading /tmp/a"
        XCTAssertEqual(t.detailLine, "reading /tmp/a")
        t.result = "42 lines"
        t.done = true
        XCTAssertEqual(t.detailLine, "42 lines", "a finished call shows its result")
    }

    // MARK: Stats

    func testStatsLineShowsOnlyTokensInTokensOutAndSeconds() {
        let s = ChatTurnStats(inputTokens: 16_400, outputTokens: 12, durationMs: 3_200)
        XCTAssertEqual(s.line, "16.4k in · 12 out · 3.2 s")
    }

    func testStatsLineOmitsMissingPartsAndMarksEstimates() {
        XCTAssertEqual(ChatTurnStats(durationMs: 800).line, "800 ms")
        XCTAssertEqual(ChatTurnStats(inputTokens: 5, outputTokens: 6).line, "5 in · 6 out")
        XCTAssertEqual(ChatTurnStats(inputTokens: 5, outputTokens: 6, estimated: true).line, "~5 in · 6 out")
        XCTAssertTrue(ChatTurnStats().isEmpty)
        XCTAssertEqual(ChatTurnStats().line, "")
    }

    // MARK: fromStored / history hydration

    func testFromStoredStringContent() {
        let m = ChatMessage(stored: ["role": "assistant", "content": "hello", "timestamp": 12])
        XCTAssertEqual(m?.role, .assistant)
        XCTAssertEqual(m?.plainText, "hello")
        XCTAssertEqual(m?.timestamp, 12)
    }

    func testFromStoredArrayContentWithTextAndToolUse() {
        let m = ChatMessage(stored: [
            "role": "assistant",
            "content": [
                ["type": "text", "text": "checking"],
                ["type": "tool_use", "name": "search", "id": "call_1", "input": ["q": "swift"]],
            ],
        ])
        XCTAssertEqual(m?.blocks.count, 2)
        XCTAssertEqual(m?.tools.first?.name, "search")
        XCTAssertEqual(m?.tools.first?.callID, "call_1")
        XCTAssertEqual(m?.tools.first?.args["q"], .string("swift"))
        XCTAssertEqual(m?.tools.first?.done, true, "history calls are finished by definition")
    }

    func testFromStoredOpenAIToolCallsWithJSONStringArguments() {
        let m = ChatMessage(stored: [
            "role": "assistant",
            "content": "",
            "tool_calls": [[
                "id": "c9",
                "function": ["name": "read_file", "arguments": "{\"path\":\"/tmp/a\"}"],
            ]],
        ])
        XCTAssertEqual(m?.tools.count, 1)
        XCTAssertEqual(m?.tools.first?.name, "read_file")
        XCTAssertEqual(m?.tools.first?.args["path"], .string("/tmp/a"))
        XCTAssertEqual(m?.tools.first?.callID, "c9")
    }

    func testFromStoredUnparseableArgumentsDegradeToEmpty() {
        let m = ChatMessage(stored: [
            "role": "assistant",
            "tool_calls": [["function": ["name": "x", "arguments": "not json"]]],
        ])
        XCTAssertEqual(m?.tools.first?.args, [:])
        XCTAssertEqual(m?.tools.first?.name, "x")
    }

    func testFromStoredReasoningFromEitherKeyAndAttachments() {
        let a = ChatMessage(stored: ["role": "assistant", "thinking": "step 1"])
        XCTAssertEqual(a?.reasoning, "step 1")
        let b = ChatMessage(stored: ["role": "assistant", "reasoning": "step 2"])
        XCTAssertEqual(b?.reasoning, "step 2")

        let c = ChatMessage(stored: [
            "role": "user", "content": "look",
            "attachments": [["name": "a.png"], "b.pdf"],
        ])
        XCTAssertEqual(c?.attachments.map(\.name), ["a.png", "b.pdf"])
        XCTAssertNil(c?.attachments.first?.thumbnail, "history carries names only")
    }

    func testFromStoredSkipsToolRoleAndEmptyRecords() {
        XCTAssertNil(ChatMessage(stored: ["role": "tool", "content": "res"]), "folded into its tool block instead")
        XCTAssertNil(ChatMessage(stored: ["role": "assistant", "content": ""]))
        XCTAssertNil(ChatMessage(stored: ["role": "assistant", "content": "   "]))
    }

    func testFromStoredDefaultsMissingRoleToAssistantAndReadsOnDevice() {
        let m = ChatMessage(stored: ["content": "hi", "on_device": true])
        XCTAssertEqual(m?.role, .assistant)
        XCTAssertTrue(m?.onDevice == true)
    }

    func testHydrateFoldsToolRoleResultsIntoTheMatchingToolBlock() {
        let raw: [[String: Any]] = [
            ["role": "user", "content": "hi"],
            ["role": "assistant", "content": "", "tool_calls": [["id": "c1", "function": ["name": "search", "arguments": "{}"]]]],
            ["role": "tool", "tool_call_id": "c1", "content": "3 results"],
            ["role": "assistant", "content": "found 3"],
        ]
        let messages = ChatHistory.hydrate(raw)
        XCTAssertEqual(messages.count, 3, "the tool record folds away")
        XCTAssertEqual(messages[1].tools.first?.result, "3 results")
        XCTAssertEqual(messages[2].plainText, "found 3")
    }

    /// Identity has to survive a refetch, or every refresh re-identifies the rows
    /// and `ForEach` throws the transcript away — losing the scroll position and
    /// any expanded reasoning card (swift-correctness H10).
    func testHydratedMessagesKeepTheSameIdentityAcrossRefetches() {
        let raw: [[String: Any]] = [
            ["role": "user", "content": "a", "timestamp": 10],
            ["role": "assistant", "content": "b", "timestamp": 11],
        ]
        XCTAssertEqual(ChatHistory.hydrate(raw).map(\.id), ChatHistory.hydrate(raw).map(\.id))
    }

    func testHydratedIdentitiesAreDistinctWithinOneThread() {
        // Same role, same (missing) timestamp, different position.
        let raw: [[String: Any]] = [
            ["role": "assistant", "content": "a"],
            ["role": "assistant", "content": "b"],
            ["role": "assistant", "content": "c"],
        ]
        let ids = ChatHistory.hydrate(raw).map(\.id)
        XCTAssertEqual(Set(ids).count, 3)
    }

    func testStoredIDVariesWithRoleTimestampAndIndex() {
        let base = ChatMessage.storedID(role: "user", timestamp: 5, index: 0)
        XCTAssertEqual(base, ChatMessage.storedID(role: "user", timestamp: 5, index: 0))
        XCTAssertNotEqual(base, ChatMessage.storedID(role: "assistant", timestamp: 5, index: 0))
        XCTAssertNotEqual(base, ChatMessage.storedID(role: "user", timestamp: 6, index: 0))
        XCTAssertNotEqual(base, ChatMessage.storedID(role: "user", timestamp: 5, index: 1))
        XCTAssertNotEqual(base, ChatMessage.storedID(role: "user", timestamp: nil, index: 0))
    }

    /// A message the user just typed is NOT from the record, so it keeps a fresh
    /// random id — two identical drafts must still be two rows.
    func testFreshMessagesKeepDistinctIdentities() {
        XCTAssertNotEqual(ChatMessage.user("hi").id, ChatMessage.user("hi").id)
    }

    func testHydrateIgnoresToolResultsWithNoMatchingCall() {
        let messages = ChatHistory.hydrate([
            ["role": "tool", "tool_call_id": "nope", "content": "orphan"],
            ["role": "assistant", "content": "hi"],
        ])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].plainText, "hi")
    }

    // MARK: Rows (what the transcript needs)

    func testRowsMarkConsecutiveMessagesFromTheSameSpeaker() {
        let rows = ChatRow.rows(for: [
            .user("a"), .user("b"), .assistant(), .user("c"),
        ])
        XCTAssertEqual(rows.map(\.continuesSpeaker), [false, true, false, false])
        XCTAssertEqual(rows.map(\.id), rows.map(\.message.id))
    }
}

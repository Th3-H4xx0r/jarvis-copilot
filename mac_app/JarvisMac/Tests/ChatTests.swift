import XCTest
@testable import Jarvis

/// The island's chat: Jarvis over the server's SSE stream, or a local model
/// (Ollama / LM Studio) over the OpenAI-style stream; files dropped on it and
/// the window you were in become context.
final class ChatTests: XCTestCase {

    func testJarvisStreamParsesTokensAndTheEnd() {
        var p = ChatSSE()
        var events: [ChatSSE.Event] = []
        for line in ["event: token", #"data: {"text": "Hel"}"#, "", #"data: {"event": "token", "text": "lo"}"#, "",
                     ": keep-alive", #"data: {"event": "tool", "name": "web_search"}"#, "",
                     #"data: {"event": "done"}"#, ""] {
            if let e = p.feed(line) { events.append(e) }
        }
        XCTAssertEqual(events.compactMap(\.token), ["Hel", "lo"])
        XCTAssertEqual(events.map(\.name), ["token", "token", "tool", "done"])
        XCTAssertTrue(events.last!.isEnd)
        XCTAssertEqual(events[2].toolName, "web_search")
    }

    func testLocalModelDeltasAndDone() {
        XCTAssertEqual(LocalModel.delta(#"data: {"choices":[{"delta":{"content":"Hi"}}]}"#), "Hi")
        XCTAssertNil(LocalModel.delta("data: [DONE]"))
        XCTAssertNil(LocalModel.delta(#"data: {"choices":[{"delta":{}}]}"#))
        XCTAssertNil(LocalModel.delta("event: x"))
        XCTAssertTrue(LocalModel.isDone("data: [DONE]"))
    }

    func testThinkBlocksAreHiddenEvenWhileOpen() {
        XCTAssertEqual(LocalModel.visible("<think>plan</think>Answer"), "Answer")
        XCTAssertEqual(LocalModel.visible("Sure. <think>still thinking"), "Sure.")
        XCTAssertEqual(LocalModel.visible("plain"), "plain")
    }

    func testLocalServerURLsAreNormalised() {
        XCTAssertEqual(LocalModel.normalise("http://localhost:11434/v1/"), "http://localhost:11434")
        XCTAssertEqual(LocalModel.normalise(" http://127.0.0.1:1234/api "), "http://127.0.0.1:1234")
        XCTAssertEqual(LocalModel.chatURL(base: "http://localhost:11434")?.absoluteString,
                       "http://localhost:11434/v1/chat/completions")
    }

    func testDroppedTextFilesAreInlinedAndBinariesNamed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let txt = dir.appendingPathComponent("notes.md")
        try "# Plan\nship it".write(to: txt, atomically: true, encoding: .utf8)
        let bin = dir.appendingPathComponent("photo.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01]).write(to: bin)
        let big = dir.appendingPathComponent("big.log")
        try String(repeating: "x", count: ChatContext.maxInlineBytes + 10).write(to: big, atomically: true, encoding: .utf8)

        let a = ChatContext.attachment(for: txt)
        XCTAssertEqual(a?.name, "notes.md")
        XCTAssertEqual(a?.inlineText, "# Plan\nship it")
        XCTAssertNil(ChatContext.attachment(for: bin)?.inlineText)
        XCTAssertEqual(ChatContext.attachment(for: bin)?.isImage, true)
        XCTAssertNil(ChatContext.attachment(for: big)?.inlineText)  // too big to inline

        let prompt = ChatContext.prompt("Summarise", attachments: [a!], window: nil)
        XCTAssertTrue(prompt.hasPrefix("Summarise"))
        XCTAssertTrue(prompt.contains("notes.md") && prompt.contains("ship it"))
    }

    // MARK: the reply, frame by frame

    /// Feeds SSE lines the way the store does and folds them into one turn.
    private func fold(_ frames: [(String, String)], into state: inout ChatStreamState) {
        var p = ChatSSE()
        for (name, json) in frames {
            _ = p.feed("event: \(name)")
            _ = p.feed("data: \(json)")
            if let e = p.feed("") { state.apply(e) }
        }
    }

    func testToolCallsGroupIntoTheReplyWithTheirResults() {
        var s = ChatStreamState()
        fold([("chat_start", #"{"stream_id": "st-1", "session_id": "s"}"#),
              ("tool", #"{"name": "device_open_app", "args": {"app": "Safari", "focus": true}, "event_type": "tool.started"}"#),
              ("metering", #"{"tps": 3}"#),
              ("tool_snippet", #"{"name": "device_open_app", "tool_call_id": "c1", "snippet": "opened Safari\nwindow 1"}"#),
              ("tool_complete", #"{"name": "device_open_app", "duration": 1.234, "is_error": false}"#),
              ("tool", #"{"name": "terminal", "args": {"command": "ls"}}"#),
              ("tool_complete", #"{"name": "terminal", "duration": 12.7, "is_error": true}"#),
              ("tool", #"{"name": "clarify", "args": {"question": "?"}}"#),
              ("token", #"{"text": "Done."}"#)], into: &s)
        XCTAssertEqual(s.streamID, "st-1")
        XCTAssertEqual(s.turn.tools.map(\.shortName), ["open_app", "terminal"], "device_ stripped, clarify isn't a row")
        let open = s.turn.tools[0]
        XCTAssertTrue(open.done)
        XCTAssertEqual(open.durationText, "1.2s")
        XCTAssertEqual(open.detailLine, "opened Safari", "the result's first line once it's done")
        XCTAssertTrue(open.args.contains("\"app\" : \"Safari\""))
        XCTAssertEqual(open.argsLine, "app: Safari · focus: true")
        XCTAssertTrue(s.turn.tools[1].isError)
        XCTAssertEqual(s.turn.tools[1].durationText, "12s")
        XCTAssertEqual(s.turn.text, "Done.")
        XCTAssertFalse(s.turn.showsDots)
        XCTAssertNil(s.end)
    }

    func testARunningToolShowsItsArgumentsAndNoDots() {
        var s = ChatStreamState()
        XCTAssertTrue(s.turn.showsDots, "a fresh reply thinks")
        fold([("tool", #"{"name": "web_search", "args": {"query": "lion"}}"#)], into: &s)
        XCTAssertFalse(s.turn.tools[0].done)
        XCTAssertEqual(s.turn.tools[0].detailLine, "query: lion")
        XCTAssertFalse(s.turn.showsDots, "the spinner says it")
        // The lazy-tools bridge reads as the tool it ran.
        fold([("tool", #"{"name": "tool_call", "args": {"name": "device_vibrate", "arguments": "{\"ms\": 200}"}}"#)], into: &s)
        XCTAssertEqual(s.turn.tools.last?.shortName, "vibrate")
        XCTAssertEqual(s.turn.tools.last?.argsLine, "ms: 200")
    }

    func testApprovalAndQuestionFramesAndTheirAnswers() {
        var s = ChatStreamState()
        fold([("approval", #"{"command": "rm -rf build", "pattern_key": "rm", "description": "recursive delete"}"#)], into: &s)
        XCTAssertEqual(s.approval, ChatApproval(command: "rm -rf build", description: "recursive delete"))
        XCTAssertNil(s.end, "the turn waits on you, it isn't over")
        let body = ChatApproval.respondBody(session: "s1", choice: .once, approvalID: nil)
        XCTAssertEqual(body["session_id"] as? String, "s1")
        XCTAssertEqual(body["choice"] as? String, "once")
        XCTAssertNil(body["approval_id"])
        XCTAssertEqual(ChatApproval.respondBody(session: "s1", choice: .always, approvalID: "a9")["approval_id"] as? String, "a9")
        XCTAssertEqual(ChatApproval(json: ["pending": ["command": "sudo x", "approval_id": "a1"]])?.id, "a1")
        XCTAssertNil(ChatApproval(json: ["pending": NSNull()]))

        fold([("clarify", #"{"question": "Which one?", "choices_offered": ["Red", "Blue", 3], "kind": "clarify"}"#)], into: &s)
        XCTAssertEqual(s.clarify, ChatClarify(question: "Which one?", choices: ["Red", "Blue", "3"]))
        let answer = ChatClarify.respondBody(session: "s1", answer: "Blue")
        XCTAssertEqual(answer["response"] as? String, "Blue")
        XCTAssertNil(ChatClarify(json: ["question": "  "]))

        // The end of the turn takes any open card with it.
        fold([("done", #"{"usage": {}}"#)], into: &s)
        XCTAssertNil(s.approval)
        XCTAssertNil(s.clarify)
    }

    /// The server's cancel frame is `cancel`: a clean end, "Stopped", not an error.
    func testCancelEndsTheTurnQuietly() {
        var p = ChatSSE()
        _ = p.feed("event: cancel")
        _ = p.feed(#"data: {"message": "Cancelled by user"}"#)
        let e = try! XCTUnwrap(p.feed(""))
        XCTAssertTrue(e.isEnd)
        XCTAssertTrue(e.isCancel)
        XCTAssertNil(e.error)

        var s = ChatStreamState()
        fold([("tool", #"{"name": "terminal"}"#), ("cancel", #"{"message": "Cancelled by user"}"#)], into: &s)
        XCTAssertEqual(s.end, .cancelled)
        XCTAssertTrue(s.turn.stopped)
        XCTAssertNil(s.turn.error)
        XCTAssertNil(s.turn.note)
        XCTAssertFalse(s.turn.streaming)
        XCTAssertTrue(s.turn.tools.allSatisfy(\.done), "nothing keeps spinning")
        XCTAssertFalse(s.turn.showsDots)

        var q = ChatStreamState()
        fold([("cancel", #"{"message": "Your plan's limit is reached.", "type": "quota_exhausted"}"#)], into: &q)
        XCTAssertEqual(q.turn.note, "Your plan's limit is reached.")

        var f = ChatStreamState()
        fold([("apperror", #"{"message": "No API key"}"#)], into: &f)
        XCTAssertEqual(f.end, .failed)
        XCTAssertEqual(f.turn.error, "No API key")
    }

    /// A reply that streamed no words takes them from the done frame's session.
    func testDoneWithoutTokensTakesTheStoredReply() {
        var s = ChatStreamState()
        fold([("done", #"{"session": {"messages": [{"role": "user", "content": "lion?"}, {"role": "assistant", "content": [{"type": "text", "text": "Here.\nMEDIA:https://x.org/lion.jpg"}]}]}}"#)],
             into: &s)
        XCTAssertEqual(s.end, .done)
        XCTAssertEqual(s.turn.text, "Here.\nMEDIA:https://x.org/lion.jpg")
        XCTAssertFalse(s.turn.streaming)
        XCTAssertFalse(s.turn.showsDots, "never Thinking… after the end")
    }

    func testTheSnapshotOnlyGivesThisTurnsReply() {
        let snap = ChatSnapshot(json: ["session": ["active_stream_id": "", "messages": [
            ["role": "user", "content": "one"], ["role": "assistant", "content": "first answer"],
            ["role": "user", "content": "two"], ["role": "assistant", "content": "", "tool_calls": [["id": "c"]]],
            ["role": "tool", "content": "{}"]]]])
        XCTAssertNil(snap.activeStreamID)
        XCTAssertNil(snap.lastAssistantText, "an older turn's reply is never adopted")
        let running = ChatSnapshot(json: ["active_stream_id": "st-9", "messages": [
            ["role": "user", "content": "two"], ["role": "assistant", "content": "second answer"], ["role": "tool"]]])
        XCTAssertEqual(running.activeStreamID, "st-9")
        XCTAssertEqual(running.lastAssistantText, "second answer")
    }

    func testAQuietStreamStallsUnlessJarvisIsWaitingOnYou() {
        let t0 = Date()
        XCTAssertFalse(ChatStall.isStalled(lastEvent: t0, now: t0.addingTimeInterval(30), waitingOnYou: false))
        XCTAssertTrue(ChatStall.isStalled(lastEvent: t0, now: t0.addingTimeInterval(46), waitingOnYou: false))
        XCTAssertFalse(ChatStall.isStalled(lastEvent: t0, now: t0.addingTimeInterval(600), waitingOnYou: true))
    }

    // MARK: who answers

    func testTheStartBodyForEachChoice() {
        let files: [[String: Any]] = [["filename": "a.png", "path": "/tmp/a.png"]]
        let def = ChatRequest.startBody(session: "s", message: "hi", attachments: [], choice: .chatDefault)
        XCTAssertEqual(def["session_id"] as? String, "s")
        XCTAssertEqual(def["message"] as? String, "hi")
        XCTAssertEqual(def["harness_id"] as? String, "", "present but empty: follow the Chat default")
        XCTAssertNil(def["model"])
        XCTAssertNil(def["attachments"])

        let h = ChatRequest.startBody(session: "s", message: "hi", attachments: files,
                                      choice: .harness(id: "fast-first", name: "Fast first"))
        XCTAssertEqual(h["harness_id"] as? String, "fast-first")
        XCTAssertNil(h["model"])
        XCTAssertEqual((h["attachments"] as? [[String: Any]])?.count, 1)

        let m = ChatRequest.startBody(session: "s", message: "hi", attachments: [],
                                      choice: .model(id: "claude-sonnet-4-6", label: "Sonnet", provider: "anthropic"))
        XCTAssertEqual(m["harness_id"] as? String, "single")
        XCTAssertEqual(m["model"] as? String, "claude-sonnet-4-6")
        XCTAssertEqual(m["model_provider"] as? String, "anthropic")
        let bare = ChatRequest.startBody(session: "s", message: "hi", attachments: [],
                                         choice: .model(id: "llama", label: "", provider: ""))
        XCTAssertNil(bare["model_provider"])
        XCTAssertEqual(ChatRunChoice.model(id: "llama", label: "", provider: "").label, "llama")
    }

    func testTheChoiceIsRemembered() throws {
        let suite = "jc.chat.tests.\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        XCTAssertEqual(ChatRunChoice.load(d), .chatDefault)
        for c: ChatRunChoice in [.harness(id: "h1", name: "Deep work"), .model(id: "m", label: "M", provider: "p"), .chatDefault] {
            c.save(d)
            XCTAssertEqual(ChatRunChoice.load(d), c)
        }
    }

    func testTheServersHarnessesAndModels() {
        let h = ChatCatalog.harnesses(["harnesses": [["id": "single", "name": "Single model"],
                                                     ["id": "fast", "name": "Fast first", "icon": "⚡"],
                                                     ["id": "", "name": "broken"]]])
        XCTAssertEqual(h, [ChatHarnessOption(id: "fast", name: "⚡ Fast first")], "Single is the model choice")
        let grouped = ChatCatalog.models(["groups": [["provider": "Anthropic", "provider_id": "anthropic",
                                                      "models": [["id": "claude-a", "label": "Claude A"], ["id": ""]]]]])
        XCTAssertEqual(grouped, [ChatModelOption(id: "claude-a", label: "Claude A", provider: "Anthropic", providerID: "anthropic")])
        XCTAssertEqual(grouped.first?.choice, .model(id: "claude-a", label: "Claude A", provider: "anthropic"))
        let flat = ChatCatalog.models(["models": ["gpt-x", ["id": "m2", "provider": "Box"]]])
        XCTAssertEqual(flat.map(\.id), ["gpt-x", "m2"])
        XCTAssertEqual(flat.last?.providerID, "Box", "older servers: the name is the only id")
    }

    // MARK: pictures and markdown

    /// `MEDIA:` lines become pictures, not text (the phone's ChatMedia).
    func testMediaLinesBecomeImages() {
        let reply = "Here's a lion.\nMEDIA:https://commons.wikimedia.org/wiki/Special:FilePath/Lion_male.jpg?width=1280\nMEDIA:/tmp/shot 1.png\nMEDIA:/tmp/report.pdf"
        let blocks = ChatMarkdown.blocks(reply)
        XCTAssertEqual(blocks.first, .paragraph("Here's a lion."))
        XCTAssertTrue(blocks.contains(.image(alt: "image",
                                             source: "https://commons.wikimedia.org/wiki/Special:FilePath/Lion_male.jpg?width=1280")))
        XCTAssertFalse(blocks.contains { if case .paragraph(let p) = $0 { return p.contains("MEDIA:") }; return false },
                       "no MEDIA: text left")
        XCTAssertEqual(ChatMedia.rewrite("MEDIA:/tmp/shot.png"), "![image](/api/media?path=%2Ftmp%2Fshot.png)")
        XCTAssertEqual(ChatMedia.rewrite("see MEDIA:/tmp/report.pdf"), "see /tmp/report.pdf", "not an image: left as a path")
        XCTAssertEqual(ChatMedia.rewrite("plain"), "plain")
        // Server paths go through the island's origin; the web as is.
        XCTAssertEqual(ChatMedia.url(for: "/api/media?path=%2Ftmp%2Fshot.png", origin: "http://127.0.0.1:8899/")?.absoluteString,
                       "http://127.0.0.1:8899/api/media?path=%2Ftmp%2Fshot.png")
        XCTAssertNil(ChatMedia.url(for: "/api/media?path=x", origin: nil))
        XCTAssertEqual(ChatMedia.url(for: "https://x.org/a.jpg", origin: nil)?.host, "x.org")
        XCTAssertNotNil(ChatMedia.inlineData("data:image/png;base64,iVBORw0KGgo="))
    }

    func testMarkdownBlocks() {
        let blocks = ChatMarkdown.split("# Plan\n\n- one\n  - two\n1. first\n\n```swift\nlet x = 1\n```\n> note\n\n---\n| a | b |\n|---|:-:|\n| 1 | 2 |\n![alt](https://x/y.png)\n```\nopen fence")
        XCTAssertEqual(blocks, [
            .heading(level: 1, text: "Plan"),
            .list([.init(marker: "•", depth: 0, text: "one"), .init(marker: "•", depth: 1, text: "two"),
                   .init(marker: "1.", depth: 0, text: "first")]),
            .code(language: "swift", text: "let x = 1"),
            .quote("note"),
            .rule,
            .table(.init(header: ["a", "b"], rows: [["1", "2"]])),
            .image(alt: "alt", source: "https://x/y.png"),
            .code(language: "", text: "open fence"),
        ])
    }

    func testWindowContextReadsLikeASentence() {
        let w = ChatContext.Window(app: "Safari", title: "Pricing — Stripe", url: "https://stripe.com/pricing")
        XCTAssertEqual(w.line, "I'm looking at Safari — \"Pricing — Stripe\" (https://stripe.com/pricing).")
        XCTAssertEqual(ChatContext.Window(app: "Notes", title: "", url: nil).line, "I'm looking at Notes.")
        let prompt = ChatContext.prompt("What is this?", attachments: [], window: w)
        XCTAssertTrue(prompt.contains("stripe.com/pricing") && prompt.contains("What is this?"))
    }
}

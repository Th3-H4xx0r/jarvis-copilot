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

    func testWindowContextReadsLikeASentence() {
        let w = ChatContext.Window(app: "Safari", title: "Pricing — Stripe", url: "https://stripe.com/pricing")
        XCTAssertEqual(w.line, "I'm looking at Safari — \"Pricing — Stripe\" (https://stripe.com/pricing).")
        XCTAssertEqual(ChatContext.Window(app: "Notes", title: "", url: nil).line, "I'm looking at Notes.")
        let prompt = ChatContext.prompt("What is this?", attachments: [], window: w)
        XCTAssertTrue(prompt.contains("stripe.com/pricing") && prompt.contains("What is this?"))
    }
}

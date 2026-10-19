import XCTest
import AppKit
import SwiftUI
import WebKit
@testable import Jarvis

/// What the island chat shows beyond the words, after the phone: who answered
/// a reply and its numbers, its thought process, a page the agent saved and a
/// link's preview card, and the text or call Jarvis asks you to confirm.
final class ChatReplyDetailsTests: XCTestCase {

    /// Feeds SSE lines the way the store does, at a fixed clock.
    private func fold(_ frames: [(String, String)], into state: inout ChatStreamState, now: Date = Date()) {
        var p = ChatSSE()
        for (name, json) in frames {
            _ = p.feed("event: \(name)")
            _ = p.feed("data: \(json)")
            if let e = p.feed("") { state.apply(e, now: now) }
        }
    }

    // MARK: who answered, and the numbers

    func testTheFooterSaysWhoAnsweredAndTheTurnsOwnNumbers() {
        var s = ChatStreamState()
        s.startedAt = Date(timeIntervalSince1970: 1_000)
        fold([("chat_start", #"{"stream_id": "st-1"}"#),
              ("turn_meta", #"{"phase": "start", "model": "claude-haiku-4-5", "kind": "answer"}"#),
              ("reasoning", #"{"text": "They want the "}"#),
              ("thinking", #"{"text": "short answer."}"#),
              ("token", #"{"text": "Hi."}"#),
              // The live totals are the session's, not this reply's: never on its line.
              ("metering", #"{"tps": 41.2, "usage": {"input_tokens": 912000, "output_tokens": 30000}}"#)],
             into: &s, now: Date(timeIntervalSince1970: 1_002))
        XCTAssertEqual(s.turn.reasoning, "They want the short answer.")
        XCTAssertNil(s.turn.meta, "only the closing turn_meta counts")
        XCTAssertNil(s.turn.stats?.inputTokens)
        XCTAssertEqual(s.turn.footer, "", "nothing under a reply still streaming")
        var thinking = ChatStreamState()
        fold([("reasoning", #"{"text": "Hmm"}"#)], into: &thinking)
        XCTAssertFalse(thinking.turn.showsDots, "the thought process says it's working")

        fold([("turn_meta", #"{"phase": "end", "model": "@anthropic:claude-opus-5-5", "kind": "answer", "ms": 3200, "handed_off": true, "route": {"label": "deep", "by": "decision", "confidence": 0.82}}"#),
              ("done", #"{"usage": {"input_tokens": 912800, "output_tokens": 30012, "turn": {"input_tokens": 800, "output_tokens": 12, "cache_read_tokens": 39000, "cache_write_tokens": 400}}}"#)],
             into: &s, now: Date(timeIntervalSince1970: 1_003.4))
        XCTAssertEqual(s.end, .done)
        XCTAssertEqual(s.turn.meta?.model, "@anthropic:claude-opus-5-5")
        XCTAssertEqual(s.turn.meta?.route, HarnessRoute(label: "deep", by: "decision", confidence: 0.82))
        XCTAssertEqual(s.turn.stats, ChatTurnStats(inputTokens: 800, cachedTokens: 39_400, outputTokens: 12, durationMs: 3_400))
        // The harness's time is the turn's: said once.
        XCTAssertEqual(s.turn.footer, "Claude Opus 5.5 · 3.2 s · routed deep 82% · handed off · 40.2k in (98% cached) · 12 out")
    }

    func testWithoutAHarnessTheLineIsTheNumbersAndTheTime() {
        var s = ChatStreamState()
        s.startedAt = Date(timeIntervalSince1970: 0)
        fold([("token", #"{"text": "Sure."}"#),
              ("done", #"{"usage": {"turn": {"prompt_tokens": 2, "completion_tokens": 5}, "estimated": true}}"#)],
             into: &s, now: Date(timeIntervalSince1970: 0.8))
        XCTAssertEqual(s.turn.footer, "2 in · 5 out · 800 ms")

        // Stopped mid-way: the session totals from metering never show as this reply's.
        var c = ChatStreamState()
        c.startedAt = Date(timeIntervalSince1970: 0)
        fold([("metering", #"{"usage": {"input_tokens": 500000, "output_tokens": 9000}}"#),
              ("cancel", #"{"message": "Cancelled by user"}"#)], into: &c, now: Date(timeIntervalSince1970: 12.3))
        XCTAssertEqual(c.turn.footer, "12.3 s")
    }

    func testTheNumbersAndModelNamesReadLikeThePhones() {
        XCTAssertEqual(ChatTurnStats(inputTokens: 1_260, outputTokens: 340, durationMs: 12_400).line(),
                       "1.3k in · 340 out · 12.4 s")
        XCTAssertEqual(ChatTurnStats(inputTokens: 90, outputTokens: 4, estimated: true).line(), "~90 in · 4 out")
        XCTAssertEqual(ChatTurnStats(durationMs: 2_000).line(time: false), "")
        XCTAssertEqual(HarnessFormat.shortModel("claude-sonnet-4-6"), "Claude Sonnet 4.6")
        XCTAssertEqual(HarnessFormat.shortModel("@openrouter:gpt-5.1"), "gpt-5.1")
        XCTAssertEqual(HarnessFormat.answeredBy(HarnessMeta(kind: "background", model: "claude-haiku-4-5", ms: 12_600)),
                       "Claude Haiku 4.5 · background · 13 s")
        XCTAssertEqual(HarnessFormat.routedText(HarnessRoute(label: "deep", error: "timeout")), "routed default (router failed)")
        XCTAssertEqual(HarnessFormat.routedText(HarnessRoute(label: "fast")), "routed fast")
        XCTAssertNil(HarnessMeta(json: ["model": ""]), "no model, no line")
        // A local model says which one.
        var local = ChatTurn(text: "Hi")
        local.meta = HarnessMeta(model: "llama3.2:3b")
        local.stats = ChatTurnStats(durationMs: 2_100)
        XCTAssertEqual(local.footer, "llama3.2:3b · 2.1 s")
    }

    /// A reply taken from the record (the done frame's session, a re-attach)
    /// brings its stored `_meta`, `_turnUsage` and `_turnDuration` with it.
    func testAStoredReplyBringsItsDetails() {
        var s = ChatStreamState()
        fold([("done", #"{"session": {"messages": [{"role": "user", "content": "old"}, {"role": "assistant", "content": "old answer", "_meta": {"model": "gpt-4o", "ms": 10}}, {"role": "user", "content": "lion?"}, {"role": "assistant", "content": "", "tool_calls": [{"id": "c"}], "thinking": "find a photo"}, {"role": "tool", "content": "{}"}, {"role": "assistant", "content": "Here.", "_turnUsage": {"input_tokens": 50, "output_tokens": 7, "cache_read_tokens": 950}, "_turnDuration": 4.3, "_meta": {"model": "claude-sonnet-4-6", "kind": "answer", "phase": "end"}}]}}"#)],
             into: &s)
        XCTAssertEqual(s.turn.text, "Here.")
        XCTAssertEqual(s.turn.reasoning, "find a photo")
        XCTAssertEqual(s.turn.footer, "Claude Sonnet 4.6 · 1.0k in (95% cached) · 7 out · 4.3 s")

        let snap = ChatSnapshot(json: ["session": ["messages": [
            ["role": "user", "content": "two"],
            ["role": "assistant", "content": "second", "_meta": ["model": "claude-opus-5-5", "ms": 900]]]]])
        XCTAssertEqual(snap.lastRecord?.meta?.ms, 900)
        XCTAssertNil(ChatReplyRecord(messages: [["role": "assistant", "content": "x", "_meta": ["model": "m"]],
                                                ["role": "user", "content": "new"]]),
                     "an older turn's details are never this reply's")
        // What streamed wins; the record only fills the gaps.
        var t = ChatTurn(text: "streamed")
        t.stats = ChatTurnStats(inputTokens: 3, outputTokens: 4, durationMs: 1_000)
        t.fill(from: ChatReplyRecord(messages: [["role": "assistant", "content": "x",
                                                 "_turnUsage": ["input_tokens": 99, "output_tokens": 99],
                                                 "_turnDuration": 9.0, "_meta": ["model": "m"]]])!)
        XCTAssertEqual(t.stats, ChatTurnStats(inputTokens: 3, outputTokens: 4, durationMs: 1_000))
        XCTAssertEqual(t.meta?.model, "m")
    }

    // MARK: pages and links

    func testPagesAndLinksBecomeCards() {
        let reply = """
        Saved it to /tmp/report.html — open it.

        https://example.com/page
        See [the docs](https://docs.x.org/a) for more.
        [Docs](https://docs.x.org/b)
        <https://x.org/c>

        ```
        https://in.code/fence
        /tmp/in-fence.html
        ```
        `/tmp/report.html`
        MEDIA:/tmp/chart.html

        - see /tmp/list.html
        https://x.org/a.html
        ~/notes/draft.html and https://x.org/page.html stay text
        """
        XCTAssertEqual(ChatMarkdown.blocks(reply), [
            .paragraph("Saved it to /tmp/report.html — open it."),
            .htmlPage(path: "/tmp/report.html"),
            .linkPreview(url: "https://example.com/page"),
            .paragraph("See [the docs](https://docs.x.org/a) for more."),
            .linkPreview(url: "https://docs.x.org/b"),
            .linkPreview(url: "https://x.org/c"),
            .code(language: "", text: "https://in.code/fence\n/tmp/in-fence.html"),
            .htmlPage(path: "/tmp/chart.html"),  // the repeated report.html line is its card already
            .list([.init(marker: "•", depth: 0, text: "see /tmp/list.html")]),
            .htmlPage(path: "/tmp/list.html"),
            .linkPreview(url: "https://x.org/a.html"),
            .paragraph("~/notes/draft.html and https://x.org/page.html stay text"),
        ])
        XCTAssertEqual(ChatMarkdown.htmlPaths(in: "open `/srv/a b.html` or /srv/x.html."), ["/srv/x.html"])
        XCTAssertEqual(ChatMarkdown.htmlPaths(in: "in `/srv/x.html`"), ["/srv/x.html"])
        XCTAssertEqual(ChatMarkdown.htmlPaths(in: "a `ls /srv/x.html` span"), [], "inside a longer code span")
        XCTAssertNil(ChatMarkdown.standaloneLink("see https://x.org"))
        XCTAssertEqual(ChatMedia.mediaSource("/tmp/a b.html"), "/api/media?path=%2Ftmp%2Fa%20b.html")
    }

    /// A page's own links leave for the browser; the page and what it embeds load in place.
    func testAPagesLinksGoToTheBrowser() throws {
        func out(_ s: String, main: Bool = true) -> Bool? { ChatWebPolicy.opensOutside(URL(string: s)!, mainFrame: main) }
        XCTAssertEqual(out("about:blank"), false)
        XCTAssertEqual(out("data:text/html,hi"), false)
        XCTAssertEqual(out("https://youtube.com/embed/x", main: false), false)
        XCTAssertEqual(out("https://x.org/next"), true)
        XCTAssertEqual(out("mailto:a@b.c"), true)
        XCTAssertNil(out("file:///etc/passwd"), "dropped, never opened")
        XCTAssertNil(out("shortcuts://run-shortcut?name=x"))
    }

    /// The expand button's window: its own, over the island, and the page's script runs.
    @MainActor
    func testThePageOpensInItsOwnWindowAndRuns() throws {
        let before = ChatPageWindow.openCount
        let window = ChatPageWindow.show(name: "report.html",
                                         html: "<html><body><script>document.title = 'ran ' + (1 + 1)</script></body></html>")
        XCTAssertEqual(ChatPageWindow.openCount, before + 1)
        XCTAssertEqual(window.title, "report.html")
        XCTAssertGreaterThan(window.level.rawValue, Int(CGWindowLevelForKey(.mainMenuWindow)) + 3, "over the island")
        XCTAssertEqual(window.frame.size.width, ChatPageWindow.size.width, accuracy: 1)
        XCTAssertTrue(window.styleMask.contains(.resizable))
        let web = try XCTUnwrap(window.contentView as? WKWebView)
        let deadline = Date().addingTimeInterval(10)
        while web.title != "ran 2", Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertEqual(web.title, "ran 2")
        window.close()
        XCTAssertEqual(ChatPageWindow.openCount, before)
    }

    // MARK: a text or call to confirm

    /// A page Jarvis wrote on this Mac with a Mac tool (run_shell → /tmp/example.html) isn't on the
    /// server: the card reads it off this disk — a regular file under the cap, nothing else.
    func testAPageWrittenOnThisMacLoadsFromItsDisk() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("jc-page-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let page = dir.appendingPathComponent("example.html")
        try Data("<h1>Hi</h1>".utf8).write(to: page)
        let read = await ChatHTMLCard.pageFromThisMac(page.path)
        XCTAssertEqual(read.map { String(decoding: $0, as: UTF8.self) }, "<h1>Hi</h1>")
        let missing = await ChatHTMLCard.pageFromThisMac(dir.appendingPathComponent("nope.html").path)
        XCTAssertNil(missing)
        let folder = await ChatHTMLCard.pageFromThisMac(dir.path)
        XCTAssertNil(folder, "a folder isn't a page")
        let big = dir.appendingPathComponent("big.html")
        try Data(count: ChatHTMLCard.maxBytes + 1).write(to: big)
        let tooBig = await ChatHTMLCard.pageFromThisMac(big.path)
        XCTAssertNil(tooBig, "over the cap")
    }

    func testASendApprovalIsTheCardsContract() {
        var s = ChatStreamState()
        fold([("approval", #"{"pending": {"kind": "send", "approval_id": "3f9c", "command": "Text Mom: “On my way”", "description": "Send this text?", "pattern_key": "send_confirm", "pattern_keys": ["send_confirm"], "send": {"kind": "text", "to": "+15551234567", "name": "Mom Appleseed", "photo": "", "text": "On my way, be there at 7", "subject": "", "via": "iPhone"}}}"#)],
             into: &s)
        let a = try! XCTUnwrap(s.approval)
        XCTAssertEqual(a.id, "3f9c")
        let send = try! XCTUnwrap(a.send)
        XCTAssertEqual(send, ChatSend(kind: .text, to: "+15551234567", name: "Mom Appleseed",
                                      text: "On my way, be there at 7", via: "iPhone"))
        XCTAssertEqual(send.title, "Mom Appleseed")
        XCTAssertEqual(send.subtitle, "Text · +15551234567")
        XCTAssertEqual(send.initials, "MA")
        XCTAssertEqual(send.actionTitle, "Send")
        XCTAssertNil(s.end, "the turn waits on you")
        // Send answers "once", Cancel "deny", with the approval's id.
        let yes = ChatApproval.respondBody(session: "s1", choice: .once, approvalID: a.id)
        XCTAssertEqual(yes["choice"] as? String, "once")
        XCTAssertEqual(yes["approval_id"] as? String, "3f9c")
        XCTAssertEqual(ChatApproval.respondBody(session: "s1", choice: .deny, approvalID: a.id)["choice"] as? String, "deny")

        // No name: the handle is the title, and the line says how it goes.
        let call = ChatSend(json: ["kind": "call", "to": "+15550001111", "name": "", "via": "iPhone"])!
        XCTAssertEqual(call.title, "+15550001111")
        XCTAssertEqual(call.subtitle, "Call · iPhone")
        XCTAssertEqual(call.initials, "")
        XCTAssertEqual(call.actionTitle, "Call")
        XCTAssertEqual(call.actionSymbol, "phone.fill")
        XCTAssertEqual(ChatSend(json: ["kind": "email", "to": "a@b.co", "via": "email"])?.subtitle, "Email")
        XCTAssertEqual(ChatSend(json: ["kind": "message", "to": "@sam", "via": "whatsapp"])?.subtitle, "Whatsapp")
        XCTAssertEqual(ChatSend(json: ["kind": "message", "to": "@sam", "via": "WhatsApp", "name": "Sam"])?.subtitle,
                       "WhatsApp · @sam")
        XCTAssertEqual(ChatSend(json: ["kind": "call", "to": "x", "via": "FaceTime"])?.subtitle, "FaceTime")
        XCTAssertEqual(ChatSend(json: ["kind": "fax", "to": "x"])?.kind, .message)
        XCTAssertNil(ChatSend(json: ["kind": "text"]), "nobody to send to")

        // Only a send carries one; any other approval keeps its command card.
        XCTAssertNil(ChatApproval(json: ["command": "rm -rf build", "send": ["to": "x"]])?.send)
        XCTAssertNil(ChatApproval(json: ["kind": "send", "command": "Text x"])?.send)
        XCTAssertNotNil(ChatApproval(json: ["kind": "send", "send": ["kind": "text", "to": "x"]])?.send,
                        "the person alone is enough")
    }

    /// The island stays open while the card is up.
    @MainActor
    func testACardWaitingOnYouHoldsTheIsland() {
        let chat = MacChatStore.shared
        chat.draft = ""
        XCTAssertFalse(chat.holdsIsland)
        chat.showDemo(lines: [], approval: ChatApproval(command: "Text Mom", description: "Send this text?",
                                                        send: ChatSend(kind: .text, to: "+1555", name: "Mom")))
        XCTAssertTrue(chat.holdsIsland)
        XCTAssertTrue(IslandPin.holds(pinned: chat.holdsIsland, tab: .chat, pending: false))
        chat.answerApproval(.deny)
        XCTAssertFalse(chat.holdsIsland)
        chat.endDemo()
        chat.draft = "half a thought"
        XCTAssertTrue(chat.holdsIsland)
        chat.draft = ""
    }

    // MARK: rendered

    /// The new rows at island width, written as PNGs when JC_ISLAND_SNAPSHOT is
    /// set: a reply with its thought process, cards, copy button and footer; the
    /// send card; and a call with no name or photo.
    @MainActor
    func testTheNewRowsRender() throws {
        guard let out = ProcessInfo.processInfo.environment["JC_ISLAND_SNAPSHOT"] else {
            throw XCTSkip("set JC_ISLAND_SNAPSHOT to render the chat rows")
        }
        let photo = NSImage(size: NSSize(width: 80, height: 80), flipped: false) { r in
            NSColor(calibratedRed: 0.85, green: 0.55, blue: 0.45, alpha: 1).setFill(); r.fill()
            NSColor(calibratedRed: 0.35, green: 0.2, blue: 0.15, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 22, y: 30, width: 36, height: 36)).fill()
            return true
        }
        let png = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(photo.tiffRepresentation))?
            .representation(using: .png, properties: [:]))
        var reply = ChatTurn(text: """
            Here's the CI summary — I saved it as a page:
            `/tmp/ci-summary.html`

            The failing job's log:
            https://github.com/nousresearch/jarvis/actions/runs/1

            Want me to rerun it?
            """)
        reply.reasoning = "Check the last run, then summarise the failures."
        reply.meta = HarnessMeta(kind: "answer", model: "claude-opus-5-5", ms: 6_400,
                                 route: HarnessRoute(label: "deep", confidence: 0.82))
        reply.stats = ChatTurnStats(inputTokens: 1_100, cachedTokens: 39_100, outputTokens: 212, durationMs: 6_500)
        let chat = MacChatStore.shared
        let ui = IslandUI()
        ui.state = .expanded
        ui.tab = .chat
        func render(_ name: String, height: CGFloat) throws {
            let view = NSHostingView(rootView: ChatPane(ui: ui).padding(16)
                .frame(width: IslandRootView.expandedWidth, height: height)
                .background(Color.black).preferredColorScheme(.dark).transaction { $0.disablesAnimations = true })
            view.frame = CGRect(x: 0, y: 0, width: IslandRootView.expandedWidth, height: height)
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            view.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: out + name))
        }
        chat.showDemo(lines: [
            MacChatStore.Line(role: .user, text: "Why did CI fail?"),
            MacChatStore.Line(role: .assistant, text: "", turn: reply),
            MacChatStore.Line(role: .user, text: "Tell Mom I'm on my way"),
            MacChatStore.Line(role: .assistant, text: "", turn: ChatTurn(streaming: true)),
        ], approval: ChatApproval(command: "Text Mom", description: "Send this text?", id: "a1",
                                  send: ChatSend(kind: .text, to: "+15551234567", name: "Mom Appleseed",
                                                 photo: "data:image/png;base64,\(png.base64EncodedString())",
                                                 text: "On my way, be there at 7", via: "iPhone")))
        try render("-chat-details.png", height: 1_120)
        chat.showDemo(lines: [MacChatStore.Line(role: .user, text: "Call the dentist")],
                      approval: ChatApproval(command: "Call", description: "Call?", id: "a2",
                                             send: ChatSend(kind: .call, to: "+15550001111", via: "iPhone")))
        try render("-chat-call.png", height: 300)
        chat.endDemo()
    }
}

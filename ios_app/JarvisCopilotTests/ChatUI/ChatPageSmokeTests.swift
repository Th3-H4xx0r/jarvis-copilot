import SwiftUI
import UIKit
import XCTest
@testable import JarvisCopilot

/// Render the real ``ChatPage`` (and the pieces it composes) against a store
/// backed by `JarvisAPI.mocked()`, and lay it out. Views are not unit-testable in
/// the usual sense, but "does the whole tree build and lay out in each of its
/// interesting states" catches the things that actually break a SwiftUI screen:
/// a missing environment value, a `ForEach` with unstable ids, a crash in a
/// formatter driven by empty state.
@MainActor
final class ChatPageSmokeTests: XCTestCase {

    /// A store with no network traffic queued: nothing in this file starts a
    /// request, because `.task` does not run under `layoutIfNeeded()`.
    private func makeStore() -> ChatStore {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/sessions", json: ["sessions": []])
        transport.route("/api/models", json: ["default_model": "", "groups": []])
        return ChatStore(api: api, selection: ModelSelection(store: MemoryKeyValueStore()))
    }

    /// Host the view, force a layout pass, and hand back the root view so a test
    /// can assert it produced something.
    @discardableResult
    private func render(_ view: some View) -> UIView {
        let host = UIHostingController(rootView: view)
        host.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        return host.view
    }

    private func page(_ store: ChatStore) -> some View {
        ChatPage(store: store).environment(AppRouter())
    }

    // MARK: The three interesting states

    func testEmptyStateRenders() {
        let store = makeStore()
        XCTAssertTrue(store.messages.isEmpty)
        let view = render(page(store))
        XCTAssertGreaterThan(view.frame.height, 0)
    }

    func testStreamingTurnRenders() {
        let store = makeStore()
        var live = ChatMessage.assistant(streaming: true)
        live.reasoning = "Working out which device the user means."
        store.setMessages([.user("what's the temperature?"), live])
        store.streaming = true
        render(page(store))
        XCTAssertTrue(store.messages.last?.isThinking == true)
    }

    func testToolRowsAndFinishedReplyRender() {
        let store = makeStore()
        var reply = ChatMessage.assistant()
        reply.startTool(ToolInvocation(id: "t1", name: "device_take_photo",
                                       args: ["camera": "front"], preview: "camera: front"))
        reply.completeTool(id: "t1", durationSec: 1.4, result: "saved photo.jpg")
        reply.startTool(ToolInvocation(id: "t2", name: "web_search", args: ["q": "weather"]))
        reply.appendToken("Here is what I found:\n\n```swift\nlet x = 1\n```\n\n- one\n- two")
        reply.stats = ChatTurnStats(inputTokens: 1_240, outputTokens: 340, durationMs: 12_400)
        store.setMessages([.user("take a photo"), reply])
        render(page(store))

        XCTAssertEqual(reply.tools.count, 2)
        XCTAssertTrue(reply.tools[0].done)
        XCTAssertFalse(reply.tools[1].done)      // the second row still spins
        XCTAssertEqual(reply.stats?.line, "1.2k in · 340 out · 12.4 s")
    }

    // MARK: The pieces, on their own

    func testSessionsSheetRendersWithGroupedRows() {
        let store = makeStore()
        let now = Int(Date().timeIntervalSince1970)
        store.sessions = [
            ChatSessionSummary(id: "a", title: "Pinned chat", updatedAt: now - 400_000, pinned: true),
            ChatSessionSummary(id: "b", title: "Today's chat", updatedAt: now, isStreaming: true),
            ChatSessionSummary(id: "c", title: "", updatedAt: nil),
        ]
        store.sessionID = "b"
        render(NavigationStack { ChatSessionsSheet(store: store) })
        XCTAssertEqual(ChatSessionGroup.group(store.sessions).map(\.title), ["Pinned", "Today", "Earlier"])
    }

    func testModelPickerRendersTheCatalogue() {
        let store = makeStore()
        store.models = ModelCatalog(json: [
            "default_model": "anthropic/claude-sonnet-4",
            "groups": [
                ["provider": "Anthropic", "models": [["id": "anthropic/claude-sonnet-4", "label": "Claude Sonnet 4"]]],
                ["provider": "OpenAI", "models": [["id": "openai/gpt-4o", "label": "GPT-4o"]]],
            ],
        ])
        render(NavigationStack { ChatModelPickerSheet(store: store) })
        XCTAssertEqual(store.models?.providers, ["Anthropic", "OpenAI"])
    }

    func testComposerWithAttachmentsAndClarifyRenders() {
        let store = makeStore()
        store.addAttachment(ChatPendingAttachment(name: "notes.pdf", data: Data(count: 2_048)))
        store.addAttachment(ChatPendingAttachment(name: "shot.jpg", data: Data(count: 900), isImage: true))
        store.pendingClarify = ClarifyPrompt(question: "Which room?", choices: ["Kitchen", "Study"])
        store.setMessages([.user("turn on the light", attachments: store.pendingAttachments.map(\.messageAttachment))])
        render(page(store))
        XCTAssertEqual(store.pendingAttachments.count, 2)
    }

    func testErrorBannerAndErrorTurnRender() {
        let store = makeStore()
        store.error = "Could not load chats: offline"
        var failed = ChatMessage.assistant()
        failed.isError = true
        failed.appendToken("the agent stopped: connection reset")
        store.setMessages([.user("hello"), failed])
        render(page(store))
        XCTAssertEqual(store.error, "Could not load chats: offline")
    }

    func testOnDeviceReplyOffersTheServerRetry() {
        let store = makeStore()
        var reply = ChatMessage.assistant()
        reply.onDevice = true
        reply.appendToken("At your service.")
        reply.stats = ChatTurnStats(inputTokens: 12, outputTokens: 4, durationMs: 90)
        store.setMessages([.user("hi"), reply])
        render(page(store))
        XCTAssertTrue(store.messages.last?.onDevice == true)
    }

    // MARK: Individual views

    func testMarkdownTextRendersEveryBlockKind() {
        let markdown = """
        # Heading

        A paragraph with **bold**, `code` and a [link](https://example.com).

        - one
          - nested
        1. first

        > quoted

        ---

        ```swift
        let x = 1
        ```

        ```python
        unterminated
        """
        render(ChatMarkdownText(text: markdown).frame(width: 320))
        // The unterminated fence is still a code block, not prose.
        guard case .code(_, _, let closed)? = MarkdownBlocks.split(markdown).last else {
            return XCTFail("expected a trailing code block")
        }
        XCTAssertFalse(closed)
    }

    func testToolRowRendersRunningAndFinished() {
        render(VStack {
            ChatToolRow(tool: ToolInvocation(name: "device_take_photo", args: ["camera": "front"]))
            ChatToolRow(tool: ToolInvocation(name: "shell", args: ["cmd": "ls"],
                                             result: "a\nb", done: true, durationSec: 0.4))
            ChatToolRow(tool: ToolInvocation(name: "broken", done: true, isError: true))
        }.frame(width: 320))
    }

    func testEmptyMessageAndNoTitleDoNotCrash() {
        let store = makeStore()
        store.sessionTitle = ""
        store.setMessages([ChatMessage(role: .assistant)])   // no blocks at all
        render(page(store))
        XCTAssertEqual(store.rows.count, 1)
    }
}

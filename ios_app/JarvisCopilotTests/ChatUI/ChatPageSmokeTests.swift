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
        store.addAttachment(PendingAttachment(name: "notes.pdf", data: Data(count: 2_048)))
        store.addAttachment(PendingAttachment(name: "shot.jpg", data: Data(count: 900), isImage: true))
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

/// Real-window previews plus composer bounds checks against the shell's actual
/// navigation bar. PNGs are review artifacts, not brittle golden-image tests.
@MainActor
final class ChatStyleSnapshotTests: XCTestCase {
    func testEmptyAndConversationLayouts() throws {
        try snapshot("01-empty") { _ in }
        try snapshot("02-conversation") { store in
            var reply = ChatMessage.assistant()
            reply.startTool(ToolInvocation(id: "devices", name: "device_status",
                                           args: ["scope": "all"], preview: "Checking your devices"))
            reply.completeTool(id: "devices", durationSec: 0.8, result: "3 devices online")
            reply.appendToken("Everything is connected.\n\n- **MacBook Pro** is online.\n- **Living room** is ready.\n- **Office speaker** is playing.\n\nWhat would you like to do next?")
            reply.stats = ChatTurnStats(inputTokens: 420, outputTokens: 86, durationMs: 1_200)
            store.sessionTitle = "A quick check-in"
            store.setMessages([.user("Check my devices and tell me what’s online."), reply])
        }
        try snapshot("03-streaming-attachments") { store in
            var reply = ChatMessage.assistant(streaming: true)
            reply.reasoning = "Reviewing the notes and finding the next steps."
            store.setMessages([.user("Help me make a plan for today."), reply])
            store.streaming = true
            store.addAttachment(PendingAttachment(name: "project-notes.pdf", data: Data(count: 2_048)))
            store.pendingClarify = ClarifyPrompt(question: "Which project should we start with?",
                                                choices: ["The app", "My workspace"])
        }
    }

    func testCompactAndLargeTextKeepComposerAboveNavigation() throws {
        try snapshot("04-compact", size: CGSize(width: 375, height: 667)) { _ in }
        try snapshot("05-large-text", dynamicType: .accessibility1) { _ in }
    }

    private func snapshot(_ name: String,
                          size: CGSize = CGSize(width: 440, height: 956),
                          dynamicType: DynamicTypeSize = .large,
                          configure: (ChatStore) -> Void) throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/sessions", json: ["sessions": []])
        transport.route("/api/models", json: ["default_model": "", "groups": []])
        let store = ChatStore(api: api, selection: ModelSelection(store: MemoryKeyValueStore()),
                              bus: ChatSyncBus())
        let router = AppRouter()
        router.selectedTab = .chat
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(origin: .zero, size: size)
        let page = VStack(spacing: 0) {
            ChatPage(store: store, launch: ChatLaunchBus(), targets: DeepLinkTargets())
                .environment(router)
                .environment(\.dynamicTypeSize, dynamicType)
            GlassNavBar(selection: .constant(.chat), bottomInset: 34)
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .preferredColorScheme(.dark)
        let host = UIHostingController(rootView: page)
        window.rootViewController = host
        window.overrideUserInterfaceStyle = .dark
        window.makeKeyAndVisible()
        defer {
            store.setListPolling(false)
            window.isHidden = true
            window.rootViewController = nil
        }
        if window.safeAreaInsets.top < 1 {
            host.additionalSafeAreaInsets = UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0)
        }
        // Let initial session loading finish before installing the preview turn.
        settle(window)
        configure(store)
        settle(window)

        let editors = descendants(window).compactMap { $0 as? UITextView }.filter(\.isEditable)
        XCTAssertFalse(editors.isEmpty, "\(name): composer missing")
        let navTop = size.height - GlassNavBar.stripHeight(bottomInset: 34)
        for editor in editors {
            let frame = editor.convert(editor.bounds, to: window)
            XCTAssertGreaterThan(frame.width, 100, "\(name): field too narrow to type")
            XCTAssertGreaterThanOrEqual(frame.minX, 0)
            XCTAssertLessThanOrEqual(frame.maxX, size.width)
            XCTAssertGreaterThan(navTop - frame.maxY, 0, "\(name): composer overlaps navigation")
            XCTAssertLessThan(navTop - frame.maxY, 46, "\(name): navigation clearance reserved twice")
        }

        let image = UIGraphicsImageRenderer(size: size).image { context in
            if !window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) {
                window.layer.render(in: context.cgContext)
            }
        }
        let directory = URL(fileURLWithPath:
            ProcessInfo.processInfo.environment["CHAT_SNAPSHOT_DIR"] ?? "/tmp/jc-chat-snapshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("\(name).png"))
    }

    private func settle(_ window: UIWindow) {
        window.setNeedsLayout()
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        window.setNeedsLayout()
        window.layoutIfNeeded()
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }
}

import XCTest
@testable import JarvisCopilot

/// The ESP32 board chats run on the shared chat stack; these pin the turn rules the
/// board screen and the script relay depend on.
@MainActor
final class BoardChatTests: XCTestCase {

    private var transport: ScriptedTransport!
    private var clock: ManualChatClock!
    private var defaults: MemoryKeyValueStore!

    override func setUp() {
        super.setUp()
        ChatAPI.streamingStartSupported = nil
        transport = ScriptedTransport()
        clock = ManualChatClock()
        defaults = MemoryKeyValueStore()
    }

    override func tearDown() {
        transport.closeHeldStreams()
        clock.releaseAll()
        ChatAPI.streamingStartSupported = nil
        super.tearDown()
    }

    private var chat: BoardChat {
        BoardChat(api: JarvisAPI(credentials: TestCredentials(), transport: transport), clock: clock,
                  resilience: ChatResilience(idleLimit: 45, checkStep: 5, maxReattach: 3), defaults: defaults)
    }

    func testABoardConversationIsCreatedOnceAndCanBeForgotten() async throws {
        transport.on("POST /api/session/new", .json(["session_id": "s1"]))
        let first = try await chat.sessionID(for: "board-1", title: "ESP32 Desk")
        let again = try await chat.sessionID(for: "board-1", title: "ESP32 Desk")
        XCTAssertEqual([first, again], ["s1", "s1"])
        XCTAssertEqual(transport.count("POST /api/session/new"), 1)
        XCTAssertEqual(transport.lastBody(for: "POST /api/session/new")["title"] as? String, "ESP32 Desk")

        chat.forgetSession(for: "board-1")
        transport.on("POST /api/session/new", .json(["session_id": "s2"]))
        let fresh = try await chat.sessionID(for: "board-1", title: "ESP32 Desk")
        XCTAssertEqual(fresh, "s2")
    }

    func testATurnStreamsToolsTextAndUsageAndRoutesOnTheProviderID() async throws {
        transport.on("POST /api/chat/start", .sse(sseFrames([
            ("tool", ["tid": "t1", "name": "esp32_upload_script", "preview": "blink.lua"]),
            ("tool_result", ["tid": "t1", "name": "esp32_upload_script", "result": "installed"]),
            ("delta", ["text": "Installed "]),
            ("delta", ["text": "blink."]),
            ("metering", ["usage": ["input_tokens": 900, "output_tokens": 12]]),
            ("done", [:]),
        ])))
        var updates = 0
        let model = ChatModel(id: "opus", label: "Opus", provider: "Anthropic", providerID: "anthropic")
        let turn = try await chat.run(sessionID: "s1", message: "blink the LED", model: model,
                                      joinRunningTurn: true) { _ in updates += 1 }

        XCTAssertEqual(turn.message.plainText, "Installed blink.")
        XCTAssertEqual(turn.message.tools.map(\.name), ["esp32_upload_script"])
        XCTAssertTrue(turn.message.tools.allSatisfy(\.done))
        XCTAssertEqual(turn.message.stats?.outputTokens, 12)
        XCTAssertGreaterThan(updates, 1, "the screen sees the turn as it streams")
        let body = transport.lastBody(for: "POST /api/chat/start")
        XCTAssertEqual(body["model"] as? String, "opus")
        XCTAssertEqual(body["model_provider"] as? String, "anthropic", "the routing id, not the display name")
    }

    func testTheChatScreenRidesAlongWithATurnAlreadyRunning() async throws {
        transport.on("POST /api/chat/start", .json(["error": "busy"], status: 409))
        transport.on("GET /api/session", .json(["session": ["active_stream_id": "live-1"]]))
        transport.on("GET /api/chat/stream", .sse(sseFrames([("delta", ["text": "already on it"]), ("done", [:])])))

        let turn = try await chat.run(sessionID: "s1", message: "hi", joinRunningTurn: true)

        XCTAssertEqual(turn.message.plainText, "already on it")
        XCTAssertEqual(transport.count("POST /api/chat/start"), 1, "a busy session is joined, never re-posted")
    }

    func testABoardEventIsToldTheSessionIsBusyInsteadOfJoining() async {
        transport.on("POST /api/chat/start", .json(["error": "busy"], status: 409))
        do {
            _ = try await chat.run(sessionID: "s1", message: "hi", joinRunningTurn: false)
            XCTFail("expected busy")
        } catch {
            XCTAssertEqual(error as? BoardChat.Failure, .busy)
            XCTAssertEqual(transport.count("GET /api/session"), 0, "it does not ride along")
        }
    }

    func testAStalledTurnThatFinishedMeanwhileTakesTheServersCopy() async throws {
        transport.on("POST /api/chat/start", .sseHolding())
        transport.on("GET /api/session", .json(["session": [
            "active_stream_id": "",
            "messages": [["role": "assistant", "content": "the finished answer"]],
        ]]))

        let running = Task { try await self.chat.run(sessionID: "s1", message: "hi", joinRunningTurn: true) }
        await waitUntil("the watchdog to park") { self.clock.parked > 0 }
        clock.advance(50)
        let turn = try await running.value

        XCTAssertEqual(turn.message.plainText, "the finished answer")
        XCTAssertEqual(transport.count("POST /api/chat/start"), 1)
    }

    func testAServerErrorFailsTheTurn() async {
        transport.on("POST /api/chat/start", .sse(sseFrames([("apperror", ["message": "model overloaded"])])))
        do {
            _ = try await chat.run(sessionID: "s1", message: "hi", joinRunningTurn: true)
            XCTFail("expected the failure")
        } catch {
            XCTAssertEqual(error as? BoardChat.Failure, .failed("model overloaded"))
        }
    }
}

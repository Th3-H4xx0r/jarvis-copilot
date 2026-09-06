import XCTest
@testable import JarvisCopilot

/// ``OnDeviceChatBridge`` — what `ChatStore` asks before every text-only turn.
/// Three outcomes matter: it answers, it declines (the server takes the turn), or
/// the engine fails (which must also be a decline, never a broken bubble).
@MainActor
final class OnDeviceChatBridgeTests: XCTestCase {

    private func bridge(settings: LocalAiSettings? = nil,
                        skills: Set<String> = [],
                        chunks: [String] = ["At your service."],
                        streamError: Error? = nil,
                        runner: FakeOnDeviceToolRunner? = nil) -> OnDeviceChatBridge {
        let settings = settings ?? onDeviceSettings()
        let runner = runner ?? FakeOnDeviceToolRunner()
        let router = LocalRouter(model: AppleFoundationModel(engine: FakeOnDeviceEngine()),
                                 settings: settings,
                                 availableSkills: { skills })
        return OnDeviceChatBridge(
            router: router,
            settings: settings,
            stream: { _ in onDeviceStream(chunks, error: streamError) },
            runTool: { name, args in await runner.run(name, args) })
    }

    /// Collect what the handler emitted along with its verdict.
    private func answer(_ handler: OnDeviceChatBridge,
                        _ text: String) async -> (reply: OnDeviceReply, emitted: String) {
        var emitted = ""
        let reply = await handler.answer(text) { emitted += $0 }
        return (reply, emitted)
    }

    // MARK: - Answers

    func testAnswersASmallTalkTurnLocally() async {
        let (reply, emitted) = await answer(bridge(), "who are you")
        guard case .answered(let input, let output) = reply else {
            return XCTFail("expected .answered, got \(reply)")
        }
        XCTAssertEqual(emitted, "At your service.")
        // Apple reports no usage, so the counts are estimates — but they must be
        // present, otherwise the chat bubble shows nothing at all.
        XCTAssertEqual(input, OnDeviceChatBridge.estimateTokens("who are you"))
        XCTAssertEqual(output, OnDeviceChatBridge.estimateTokens("At your service."))
    }

    func testStreamsEveryTokenThrough() async {
        var chunks: [String] = []
        let handler = bridge(chunks: ["At ", "your ", "service."])
        let reply = await handler.answer("hello") { chunks.append($0) }
        XCTAssertEqual(chunks, ["At ", "your ", "service."])
        if case .escalate = reply { XCTFail("expected a local answer") }
    }

    /// A device-local tool the phone can run: the bridge runs it and speaks the
    /// confirmation rather than handing the turn to the server.
    func testRunsADeviceLocalToolAndConfirms() async {
        let runner = FakeOnDeviceToolRunner()
        let handler = bridge(skills: ["flashlight_on"], runner: runner)
        let (reply, emitted) = await answer(handler, "turn on the flashlight")
        guard case .answered = reply else { return XCTFail("expected .answered, got \(reply)") }
        XCTAssertEqual(runner.calls.map(\.name), ["flashlight_on"])
        XCTAssertEqual(emitted, "Flashlight on, sir.")
    }

    // MARK: - Declines

    func testEscalatesARequestThatNeedsTheServer() async {
        let (reply, emitted) = await answer(bridge(), "what's the weather in Tokyo")
        XCTAssertEqual(reply, .escalate)
        XCTAssertEqual(emitted, "")
    }

    func testEscalatesWhenTheTierIsOff() async {
        let (reply, _) = await answer(bridge(settings: onDeviceSettings(tier: .off)), "hello")
        XCTAssertEqual(reply, .escalate)
    }

    func testEscalatesWhenChatIsDisabled() async {
        let (reply, _) = await answer(bridge(settings: onDeviceSettings(chat: false)), "hello")
        XCTAssertEqual(reply, .escalate)
    }

    /// A tool that ran but achieved nothing (open_app with no URL scheme) is not
    /// a success — claiming it happened would be a lie.
    func testEscalatesWhenATooRanButMissed() async {
        let runner = FakeOnDeviceToolRunner()
        runner.outcome = .ok(["launched": false])
        let handler = bridge(skills: ["open_app"], runner: runner)
        let (reply, emitted) = await answer(handler, "open Spotify")
        XCTAssertEqual(reply, .escalate)
        XCTAssertEqual(emitted, "")
    }

    func testEscalatesWhenTheToolErrors() async {
        let runner = FakeOnDeviceToolRunner()
        runner.outcome = .err("no such skill")
        let handler = bridge(skills: ["flashlight_on"], runner: runner)
        let (reply, _) = await answer(handler, "turn on the flashlight")
        XCTAssertEqual(reply, .escalate)
    }

    // MARK: - Errors

    func testEscalatesWhenTheEngineFailsWithNothingToShow() async {
        let handler = bridge(chunks: [], streamError: OnDeviceEngineError("modelNotReady"))
        let (reply, emitted) = await answer(handler, "hello")
        XCTAssertEqual(reply, .escalate)
        XCTAssertEqual(emitted, "")
    }

    func testEscalatesWhenTheModelProducesNothing() async {
        let (reply, _) = await answer(bridge(chunks: ["   "]), "hello")
        XCTAssertEqual(reply, .escalate)
    }
}

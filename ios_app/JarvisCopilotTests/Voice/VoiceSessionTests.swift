import XCTest
@testable import JarvisCopilot

/// The `/api/voice/s2s/ws` wire format, both directions, plus the session that
/// owns the socket.
final class VoiceSessionTests: XCTestCase {

    // MARK: - Server → client

    func testDecodesEveryFrameTheServerSends() {
        XCTAssertEqual(VoiceServerFrame.decode(text: #"{"type":"ready"}"#), .ready)
        XCTAssertEqual(VoiceServerFrame.decode(text: #"{"type":"transcript","text":"hello"}"#),
                       .transcript("hello"))
        XCTAssertEqual(VoiceServerFrame.decode(text: #"{"type":"assistant_text","text":"Hi."}"#),
                       .assistantText("Hi."))
        XCTAssertEqual(VoiceServerFrame.decode(text: #"{"type":"tool","name":"search_web","status":"started"}"#),
                       .tool(name: "search_web", status: "started"))
        XCTAssertEqual(VoiceServerFrame.decode(text: #"{"type":"audio_meta","format":"mp3","sample_rate":24000}"#),
                       .audioMeta(format: "mp3", sampleRate: 24000))
        XCTAssertEqual(VoiceServerFrame.decode(text: #"{"type":"audio_end"}"#), .audioEnd)
        XCTAssertEqual(VoiceServerFrame.decode(text: #"{"type":"end_turn","reason":"no_reply"}"#),
                       .endTurn(reason: "no_reply"))
        XCTAssertEqual(VoiceServerFrame.decode(text: #"{"type":"escalation_result","text":"Actually…"}"#),
                       .escalationResult("Actually…"))
        // The live server sends `spans` (voice.py `_finish_turn_timing`); this
        // flat pair is the older shape, still accepted.
        XCTAssertEqual(VoiceServerFrame.decode(text: #"{"type":"latency","turn_id":"m-1","span":"tts","ms":210}"#),
                       .latency(turnID: "m-1", spans: ["tts": 210]))
    }

    func testFrameDefaultsMatchTheFlutterClient() {
        XCTAssertEqual(VoiceServerFrame.decode(text: #"{"type":"audio_meta"}"#),
                       .audioMeta(format: "pcm_s16le", sampleRate: 24000))
        XCTAssertEqual(VoiceServerFrame.decode(text: #"{"type":"tool"}"#),
                       .tool(name: "tool", status: "started"))
        XCTAssertEqual(VoiceServerFrame.decode(text: #"{"type":"end_turn"}"#), .endTurn(reason: ""))
        XCTAssertEqual(VoiceServerFrame.decode(text: #"{"type":"transcript"}"#), .transcript(""))
    }

    func testAnUnknownTypeIsCarriedRatherThanDroppedSilently() {
        XCTAssertEqual(VoiceServerFrame.decode(text: #"{"type":"quota_warning"}"#),
                       .other("quota_warning"))
    }

    func testNonJsonTextIsRejected() {
        XCTAssertNil(VoiceServerFrame.decode(text: "not json"))
        XCTAssertNil(VoiceServerFrame.decode(text: "[1,2,3]"))
    }

    // MARK: - Client → server

    func testBeginTurnCarriesTheSampleRateAndSessionOnly() {
        let message = VoiceClientMessage.beginTurn(sampleRate: 16000, sessionID: "voice-1",
                                                    model: nil, provider: nil)
        XCTAssertEqual(message.encoded(),
                       #"{"sample_rate":16000,"session_id":"voice-1","type":"begin_turn"}"#)
    }

    func testBeginTurnIncludesTheVoiceModelWhenChosen() {
        let message = VoiceClientMessage.beginTurn(sampleRate: 16000, sessionID: "s",
                                                    model: "gpt-5", provider: "openai")
        let json = message.payload
        XCTAssertEqual(json["model"] as? String, "gpt-5")
        XCTAssertEqual(json["model_provider"] as? String, "openai")
    }

    func testBeginTurnOmitsEmptyFields() {
        let json = VoiceClientMessage.beginTurn(sampleRate: 16000, sessionID: "",
                                                 model: "", provider: nil).payload
        XCTAssertNil(json["session_id"])
        XCTAssertNil(json["model"])
        XCTAssertNil(json["model_provider"])
    }

    func testEndTurnCarriesTheLatencyTimestamps() {
        let json = VoiceClientMessage.endTurn(text: "turn on the lights", clientTs: 1000,
                                               speechEndTs: 900, turnID: "m-7").payload
        XCTAssertEqual(json["type"] as? String, "end_turn")
        XCTAssertEqual(json["text"] as? String, "turn on the lights")
        XCTAssertEqual(json["client_ts"] as? Int, 1000)
        XCTAssertEqual(json["speech_end_ts"] as? Int, 900)
        XCTAssertEqual(json["turn_id"] as? String, "m-7")
    }

    func testEndTurnWithoutAnOnDeviceTranscriptOmitsText() {
        let json = VoiceClientMessage.endTurn(text: nil, clientTs: 5, speechEndTs: nil,
                                               turnID: nil).payload
        XCTAssertNil(json["text"], "the server then runs its own STT")
        XCTAssertNil(json["speech_end_ts"])
        XCTAssertNil(json["turn_id"])
        XCTAssertEqual(json.count, 2)
    }

    func testInterruptIsJustATypeTag() {
        XCTAssertEqual(VoiceClientMessage.interrupt.encoded(), #"{"type":"interrupt"}"#)
    }

    // MARK: - Session

    @MainActor
    func testOpenConnectsToTheRealtimeUrlWithTheApiHeaders() async throws {
        let (api, _) = JarvisAPI.mocked()
        let connector = MockVoiceSocketConnector()
        let session = VoiceSession(voice: VoiceAPI(api: api), connector: connector)

        try await session.open()

        XCTAssertTrue(session.isOpen)
        XCTAssertEqual(connector.connectedURLs.map(\.absoluteString),
                       ["wss://jarvis.test/api/voice/s2s/ws"])
        XCTAssertEqual(connector.connectedHeaders.first?["Cookie"], "hermes_session=abc")
    }

    @MainActor
    func testTextFramesAreDecodedAndBinaryFramesBecomeAudio() async throws {
        let (api, _) = JarvisAPI.mocked()
        let connector = MockVoiceSocketConnector()
        let session = VoiceSession(voice: VoiceAPI(api: api), connector: connector)
        var frames: [VoiceServerFrame] = []
        session.onFrame = { frames.append($0) }
        try await session.open()
        let socket = try XCTUnwrap(connector.socket)

        socket.receive(text: #"{"type":"ready"}"#)
        socket.receive(text: "garbage")
        socket.receive(binary: Data([1, 2, 3]))

        XCTAssertEqual(frames, [.ready, .audio(Data([1, 2, 3]))],
                       "unparseable text is dropped, not surfaced as a frame")
    }

    @MainActor
    func testSendGoesOutAsTextAndPcmAsBinary() async throws {
        let (api, _) = JarvisAPI.mocked()
        let connector = MockVoiceSocketConnector()
        let session = VoiceSession(voice: VoiceAPI(api: api), connector: connector)
        try await session.open()
        let socket = try XCTUnwrap(connector.socket)

        session.send(.beginTurn(sampleRate: 16000, sessionID: "s", model: nil, provider: nil))
        session.send(pcm: Data([7, 8]))
        session.send(.interrupt)

        XCTAssertEqual(socket.sentTypes, ["begin_turn", "interrupt"])
        XCTAssertEqual(socket.sentData, [Data([7, 8])])
    }

    @MainActor
    func testAServerCloseIsReportedOnce() async throws {
        let (api, _) = JarvisAPI.mocked()
        let connector = MockVoiceSocketConnector()
        let session = VoiceSession(voice: VoiceAPI(api: api), connector: connector)
        var closes = 0
        session.onClose = { _ in closes += 1 }
        try await session.open()
        try XCTUnwrap(connector.socket).serverClosed()

        XCTAssertEqual(closes, 1)
        XCTAssertFalse(session.isOpen)
    }

    @MainActor
    func testClosingOurselvesDoesNotReportACloseOrDeliverLaterFrames() async throws {
        let (api, _) = JarvisAPI.mocked()
        let connector = MockVoiceSocketConnector()
        let session = VoiceSession(voice: VoiceAPI(api: api), connector: connector)
        var closes = 0
        var frames: [VoiceServerFrame] = []
        session.onClose = { _ in closes += 1 }
        session.onFrame = { frames.append($0) }
        try await session.open()
        let socket = try XCTUnwrap(connector.socket)

        session.close()
        socket.serverClosed()
        socket.receive(text: #"{"type":"ready"}"#)

        XCTAssertEqual(closes, 0, "we asked for it — don't report it as a drop")
        XCTAssertTrue(frames.isEmpty)
        XCTAssertEqual(socket.closeCount, 1)
        XCTAssertFalse(session.isOpen)
        // Sending after close is a no-op, not a crash.
        session.send(.interrupt)
        XCTAssertTrue(socket.sentText.isEmpty)
    }

    @MainActor
    func testReopeningClosesThePreviousSocket() async throws {
        let (api, _) = JarvisAPI.mocked()
        let connector = MockVoiceSocketConnector()
        let session = VoiceSession(voice: VoiceAPI(api: api), connector: connector)
        try await session.open()
        let first = try XCTUnwrap(connector.socket)
        try await session.open()
        XCTAssertEqual(first.closeCount, 1)
        XCTAssertEqual(connector.connectedURLs.count, 2)
    }
}

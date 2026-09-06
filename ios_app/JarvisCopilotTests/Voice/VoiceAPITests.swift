import XCTest
@testable import JarvisCopilot

/// Request shapes and reply parsing for every `/api/voice/*` endpoint.
final class VoiceAPITests: XCTestCase {

    private func make() -> (VoiceAPI, MockTransport) {
        let (api, transport) = JarvisAPI.mocked()
        return (VoiceAPI(api: api), transport)
    }

    // MARK: - Engines

    func testListEnginesParsesTheCatalogAndActiveId() async throws {
        let (voice, t) = make()
        t.enqueue(json: [
            "active": "edge",
            "engines": [
                ["id": "edge", "name": "Edge TTS", "requires_key": false,
                 "voice_kind": "preset", "configured": true, "active": true,
                 "has_api_key": false, "voices": ["en-GB-RyanNeural", "en-US-GuyNeural"]],
                ["id": "elevenlabs", "name": "ElevenLabs", "requires_key": true,
                 "voice_kind": "preset", "configured": false, "active": false,
                 "has_api_key": false, "voices": []],
                ["id": "fish-audio", "name": "Fish Audio", "requires_key": true,
                 "voice_kind": "custom", "configured": true, "active": false,
                 "has_api_key": true, "voices": [], "voice_id": "abc123",
                 "voice_id_hint": "Paste from fish.audio/m/<id>"],
            ],
        ])

        let list = try await voice.listEngines()
        XCTAssertEqual(t.lastRequest?.url?.path, "/api/voice/engines")
        XCTAssertEqual(t.lastRequest?.httpMethod, "GET")
        XCTAssertEqual(list.active, "edge")
        XCTAssertEqual(list.engines.map(\.id), ["edge", "elevenlabs", "fish-audio"])
        XCTAssertEqual(list.engines[0].voices, ["en-GB-RyanNeural", "en-US-GuyNeural"])
        XCTAssertTrue(list.engines[0].active)
        XCTAssertTrue(list.engines[1].requiresKey)
        XCTAssertEqual(list.engines[2].voiceKind, "custom")
        XCTAssertEqual(list.engines[2].voiceID, "abc123")
        // An engine that can't run must not reach the picker.
        XCTAssertEqual(list.usable.map(\.id), ["edge", "fish-audio"])
    }

    func testListEnginesOnAnEmptyReplyIsEmptyRatherThanThrowing() async throws {
        let (voice, t) = make()
        t.enqueue(json: [String: Any]())
        let list = try await voice.listEngines()
        XCTAssertTrue(list.engines.isEmpty)
        XCTAssertEqual(list.active, "")
    }

    // MARK: - Session

    func testVoiceSessionIdUsesTheDedicatedEndpoint() async throws {
        let (voice, t) = make()
        t.enqueue(json: ["session_id": "voice-42"])
        let id = try await voice.voiceSessionID()
        XCTAssertEqual(id, "voice-42")
        XCTAssertEqual(t.lastRequest?.url?.path, "/api/voice/session")
    }

    func testVoiceSessionIdIsEmptyWhenTheServerOmitsIt() async throws {
        let (voice, t) = make()
        t.enqueue(json: [String: Any]())
        let id = try await voice.voiceSessionID()
        XCTAssertEqual(id, "")
    }

    // MARK: - Synthesize (binary reply)

    func testSynthesizePostsTheTextAndReturnsRawAudioBytes() async throws {
        let (voice, t) = make()
        let mp3 = Data([0xFF, 0xFB, 0x90, 0x00, 0x11, 0x22])
        t.enqueue(MockTransport.Reply(status: 200, body: mp3,
                                      headers: ["Content-Type": "audio/mpeg"]))

        let audio = try await voice.synthesize(text: "At your service.")
        XCTAssertEqual(audio, mp3, "the body IS the audio, not JSON")
        XCTAssertEqual(t.lastRequest?.url?.path, "/api/voice/synthesize")
        XCTAssertEqual(t.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(t.lastRequest?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = t.lastBody()
        XCTAssertEqual(body["text"] as? String, "At your service.")
        XCTAssertEqual(body["format"] as? String, "mp3")
        XCTAssertNil(body["voice"], "an unset voice is omitted, not sent empty")
        XCTAssertNil(body["engine"])
    }

    func testSynthesizeIncludesTheVoiceAndEngineWhenSet() async throws {
        let (voice, t) = make()
        t.enqueue(MockTransport.Reply(status: 200, body: Data([1])))
        _ = try await voice.synthesize(text: "hi", format: "wav",
                                        voice: "en-GB-RyanNeural", engine: "edge")
        let body = t.lastBody()
        XCTAssertEqual(body["format"] as? String, "wav")
        XCTAssertEqual(body["voice"] as? String, "en-GB-RyanNeural")
        XCTAssertEqual(body["engine"] as? String, "edge")
    }

    func testSynthesizeOrEmptySwallowsFailuresSoTheCallerCanFallBack() async {
        let (voice, t) = make()
        t.enqueue(json: ["error": "TTS module unavailable"], status: 503)
        let audio = await voice.synthesizeOrEmpty(text: "offline?")
        XCTAssertTrue(audio.isEmpty)
    }

    func testSynthesizeThrowsTheServersMessage() async {
        let (voice, t) = make()
        t.enqueue(json: ["error": "text is required"], status: 400)
        do {
            _ = try await voice.synthesize(text: "x")
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(apiErrorMessage(error), "text is required")
        }
    }

    // MARK: - Quality turn (NDJSON)

    func testQualityTurnPostsBase64AudioAndStreamsEvents() async throws {
        let (voice, t) = make()
        let mp3 = Data([0x11, 0x22, 0x33])
        t.enqueue(text: """
        {"type":"transcript","text":"what's the weather"}
        {"type":"segment","kind":"tool","name":"search_web","status":"started"}
        {"type":"segment","kind":"text","text":"Clear skies.","audio_base64":"\(mp3.base64EncodedString())"}
        {"type":"done"}
        """, contentType: "application/x-ndjson")

        let events = try await collect(voice.qualityTurn(audio: Data([1, 2, 3, 4]),
                                                          sessionID: "voice-1"))

        XCTAssertEqual(t.lastRequest?.url?.path, "/api/voice/quality-turn")
        XCTAssertEqual(t.lastRequest?.httpMethod, "POST")
        let body = t.lastBody()
        XCTAssertEqual(body["audio_base64"] as? String, Data([1, 2, 3, 4]).base64EncodedString())
        XCTAssertEqual(body["sample_rate"] as? Int, 16000)
        XCTAssertEqual(body["session_id"] as? String, "voice-1")

        XCTAssertEqual(events.map(\.type), ["transcript", "segment", "segment", "done"])
        XCTAssertEqual(events[0].text, "what's the weather")
        XCTAssertEqual(events[1].kind, "tool")
        XCTAssertEqual(events[1].name, "search_web")
        XCTAssertEqual(events[1].status, "started")
        XCTAssertEqual(events[2].text, "Clear skies.")
        XCTAssertEqual(events[2].audio, mp3, "audio_base64 is decoded for the caller")
        XCTAssertNil(events[3].audio)
    }

    func testQualityTurnHonoursACustomSampleRate() async throws {
        let (voice, t) = make()
        t.enqueue(text: "{\"type\":\"done\"}\n", contentType: "application/x-ndjson")
        _ = try await collect(voice.qualityTurn(audio: Data([9]), sessionID: "s", sampleRate: 24000))
        XCTAssertEqual(t.lastBody()["sample_rate"] as? Int, 24000)
    }

    func testQualityTurnSurfacesAnErrorFrame() async throws {
        let (voice, t) = make()
        t.enqueue(text: "{\"type\":\"error\",\"error\":\"no speech\"}\n",
                  contentType: "application/x-ndjson")
        let events = try await collect(voice.qualityTurn(audio: Data([1]), sessionID: "s"))
        XCTAssertEqual(events.first?.type, "error")
        XCTAssertEqual(events.first?.error, "no speech")
    }

    // MARK: - Realtime URL

    func testRealtimeUrlUpgradesHttpsToWss() throws {
        let (voice, _) = make()
        XCTAssertEqual(try voice.realtimeURL().absoluteString,
                       "wss://jarvis.test/api/voice/s2s/ws")
    }

    func testRealtimeUrlCarriesSortedQueryParams() throws {
        let (voice, _) = make()
        let url = try voice.realtimeURL(params: ["mode": "realtime", "device": "ios"])
        XCTAssertEqual(url.absoluteString,
                       "wss://jarvis.test/api/voice/s2s/ws?device=ios&mode=realtime")
    }

    func testRealtimeUrlUpgradesPlainHttpToWs() throws {
        let api = JarvisAPI(credentials: TestCredentials(baseURL: URL(string: "http://10.0.0.4:8080")),
                            transport: MockTransport())
        XCTAssertEqual(try VoiceAPI(api: api).realtimeURL().absoluteString,
                       "ws://10.0.0.4:8080/api/voice/s2s/ws")
    }

    func testRealtimeUrlThrowsWhenNotPaired() {
        let api = JarvisAPI(credentials: TestCredentials(baseURL: nil), transport: MockTransport())
        XCTAssertThrowsError(try VoiceAPI(api: api).realtimeURL()) { error in
            XCTAssertEqual(error as? APIError, .notPaired)
        }
    }

    // MARK: - Cancel a stranded stream

    func testCancelActiveStreamCancelsTheIdTheSessionReports() async {
        let (voice, t) = make()
        t.enqueue(json: ["session": ["active_stream_id": "stream-9"]])
        t.enqueue(json: ["ok": true])

        await voice.cancelActiveStream(sessionID: "voice-1")

        XCTAssertEqual(t.requests.count, 2)
        let first = t.requests[0]
        XCTAssertEqual(first.url?.path, "/api/session")
        XCTAssertEqual(first.url?.query, "messages=0&session_id=voice-1")
        let second = t.requests[1]
        XCTAssertEqual(second.url?.path, "/api/chat/cancel")
        XCTAssertEqual(second.url?.query, "stream_id=stream-9")
    }

    func testCancelActiveStreamDoesNothingWhenNoStreamIsRunning() async {
        let (voice, t) = make()
        t.enqueue(json: ["session": ["active_stream_id": ""]])
        await voice.cancelActiveStream(sessionID: "voice-1")
        XCTAssertEqual(t.requests.count, 1, "no cancel call when there's nothing to cancel")
    }

    func testCancelActiveStreamSwallowsFailuresSoTheTurnStillRuns() async {
        let (voice, t) = make()
        t.enqueue(json: ["error": "nope"], status: 500)
        await voice.cancelActiveStream(sessionID: "voice-1")
        XCTAssertEqual(t.requests.count, 1)
    }
}

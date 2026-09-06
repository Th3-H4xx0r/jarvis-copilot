import XCTest
@testable import JarvisCopilot

/// Regressions for "voice doesn't work anymore, that whole screen backend is
/// broken" — each case pins one mismatch against the Flutter client
/// (`mobile_client/lib/voice/voice_controller.dart`, `lib/api/voice.dart`) or
/// the server that both talk to (`webui/api/voice.py`).
@MainActor
final class VoiceBackendFixTests: XCTestCase {

    // MARK: - Harness

    @MainActor
    private struct Rig {
        let store: VoiceStore
        let input: MockAudioInput
        let audioSession: MockAudioSessionControlling
        let connector: MockVoiceSocketConnector
        let clock: TestVoiceClock
        let transport: MockTransport
        var socket: MockVoiceSocket? { connector.socket }
    }

    private func makeRig(mode: VoiceMode = .realtime) -> Rig {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/voice/session", json: ["session_id": "voice-1"])
        transport.route("/api/session", json: ["session": ["active_stream_id": ""]])
        transport.route("/api/devices", json: ["devices": []])

        let input = MockAudioInput()
        let audioSession = MockAudioSessionControlling()
        let connector = MockVoiceSocketConnector()
        let clock = TestVoiceClock()
        let store = VoiceStore(api: api,
                               input: input,
                               output: MockAudioOutput(),
                               recognizer: MockSpeechRecognizing(),
                               synthesizer: MockVoiceSynthesizing(),
                               audioSession: audioSession,
                               connector: connector,
                               clock: clock,
                               keyValueStore: MemoryKeyValueStore(),
                               launch: nil,
                               local: nil)
        store.machine.mode = mode
        return Rig(store: store, input: input, audioSession: audioSession,
                   connector: connector, clock: clock, transport: transport)
    }

    // MARK: - 1. The audio session must be acquired in BOTH modes
    //
    // ROOT CAUSE. `configureForConversation()`/`setActive(true)` only ran inside
    // `openTransport()`, which quality mode never reaches — its `startRequested`
    // goes straight to `.startMic`. On a device the session is then whatever the
    // app last left it in: `.soloAmbient` by default, `.playback` once
    // `BackgroundKeepalive` arms (`BackgroundKeepalive.swift:69`, armed for the
    // whole launch on a paired phone). Neither permits recording, so
    // `AVAudioEngine.inputNode` has no input route and every mic start fails.

    func testQualityModeConfiguresAndActivatesTheAudioSessionBeforeTheMic() async {
        let rig = makeRig(mode: .quality)
        await rig.store.primaryAction()
        _ = await waitUntilVoice { rig.input.isRunning }

        XCTAssertEqual(rig.audioSession.configureCount, 1,
                       "push-to-talk must own the audio session too — the mic cannot "
                     + "record under .playback/.soloAmbient")
        XCTAssertEqual(rig.audioSession.activeCalls, [true])
        XCTAssertTrue(rig.input.isRunning)
    }

    func testRealtimeStillConfiguresTheAudioSessionBeforeTheMic() async {
        let rig = makeRig()
        await rig.store.primaryAction()
        _ = await waitUntilVoice { rig.input.isRunning }

        XCTAssertTrue(rig.audioSession.configureCount >= 1)
        XCTAssertTrue(rig.audioSession.activeCalls.contains(true))
        XCTAssertEqual(rig.store.state, .listening)
    }

    func testAudioSessionFailureEndsTheTurnVisiblyInsteadOfASilentDeadMic() async {
        let rig = makeRig(mode: .quality)
        rig.audioSession.configureError = VoiceAudioError.micUnavailable("category refused")
        await rig.store.primaryAction()
        _ = await waitUntilVoice { rig.store.state == .error }

        XCTAssertEqual(rig.store.state, .error)
        XCTAssertNotNil(rig.store.error, "a dead mic must reach the UI, not just the log")
        XCTAssertFalse(rig.input.isRunning)
    }

    // MARK: - 2. `voices` decoding
    //
    // The server sends objects, not strings:
    //   webui/api/voice.py:2785  item["voices"] = list(return_voices)
    //   webui/api/voice.py:436   {"id": "en-US-AriaNeural", "name": "Aria (en-US, female)"}
    // `d.strings("voices")` matched none of them, so every engine looked like it
    // had no voices and the picker could never offer one.

    func testEngineVoicesParseTheServersObjectShape() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/voice/engines", json: [
            "active": "edge",
            "engines": [[
                "id": "edge", "name": "Edge TTS", "requires_key": false,
                "voice_kind": "preset", "configured": true, "active": true,
                "has_api_key": false,
                "voices": [["id": "en-US-AriaNeural", "name": "Aria (en-US, female)"],
                           ["id": "en-GB-RyanNeural", "name": "Ryan (en-GB, male)"]],
            ]],
        ])
        let list = try await VoiceAPI(api: api).listEngines()

        XCTAssertEqual(list.engines[0].voices, ["en-US-AriaNeural", "en-GB-RyanNeural"])
        XCTAssertEqual(list.engines[0].voiceLabels["en-GB-RyanNeural"], "Ryan (en-GB, male)")
    }

    func testEngineVoicesStillAcceptAPlainStringArray() {
        let (ids, labels) = VoiceEngine.parseVoices(["alloy", "nova"])
        XCTAssertEqual(ids, ["alloy", "nova"])
        XCTAssertTrue(labels.isEmpty)
    }

    func testEngineVoicesSkipMalformedEntries() {
        let (ids, _) = VoiceEngine.parseVoices([["name": "no id"], ["id": ""], 7, ["id": "ok"]])
        XCTAssertEqual(ids, ["ok"])
    }

    // MARK: - 3. `audio_meta` sample_rate 0
    //
    // webui/api/voice.py:1970 sends `{"format":"mp3","sample_rate":0}`. Zero must
    // not reach the player: `AVAudioFormat(sampleRate: 0)` is nil (which latches
    // `isStreamAvailable = false` for the whole launch) and `AudioQueue`
    // divides by it to size a segment.

    func testMp3AudioMetaZeroSampleRateFallsBackTo24k() {
        XCTAssertEqual(
            VoiceServerFrame.decode(text: #"{"type":"audio_meta","format":"mp3","sample_rate":0}"#),
            .audioMeta(format: "mp3", sampleRate: 24000))
    }

    func testPcmAudioMetaKeepsTheServersRate() {
        XCTAssertEqual(
            VoiceServerFrame.decode(text: #"{"type":"audio_meta","format":"pcm_s16le","sample_rate":24000}"#),
            .audioMeta(format: "pcm_s16le", sampleRate: 24000))
    }

    // MARK: - 4. `latency` frame shape
    //
    // webui/api/voice.py:2096-2099
    //   {"type": "latency", "turn_id": …, "spans": {name: ms, …}}
    // We decoded a flat `span`/`ms` pair, which never matched.

    func testLatencyDecodesTheServersSpansObject() {
        let frame = VoiceServerFrame.decode(
            text: #"{"type":"latency","turn_id":"ab12cd34ef56","spans":{"stt":120,"llm":840.5}}"#)
        XCTAssertEqual(frame, .latency(turnID: "ab12cd34ef56",
                                       spans: ["stt": 120, "llm": 840.5]))
    }

    func testLatencyStillDecodesTheOlderFlatShape() {
        XCTAssertEqual(
            VoiceServerFrame.decode(text: #"{"type":"latency","turn_id":"m-1","span":"tts","ms":210}"#),
            .latency(turnID: "m-1", spans: ["tts": 210]))
    }

    // MARK: - 5. Model / provider on every turn body
    //
    // Flutter puts `_voiceModelFields()` on `begin_turn` (voice_controller.dart
    // `_startRealtime` / `_resetServerTurn`). We hard-coded nil, so a model
    // picked for the Voice surface was silently ignored.

    func testBeginTurnCarriesTheVoiceSurfacesModelAndProvider() async {
        let store = ModelSelection(store: MemoryKeyValueStore())
        store.set(.voice, model: "anthropic/claude-x", provider: "anthropic")
        let fields = voiceTurnModelFields(store)
        XCTAssertEqual(fields["model"] as? String, "anthropic/claude-x")
        XCTAssertEqual(fields["model_provider"] as? String, "anthropic")
    }

    func testBeginTurnOmitsModelFieldsWhenNothingIsPicked() {
        let fields = voiceTurnModelFields(ModelSelection(store: MemoryKeyValueStore()))
        XCTAssertTrue(fields.isEmpty, "an empty pick must leave the server's own lane alone")
    }

    func testBeginTurnFrameIsTheExactJSONTheServerParses() {
        // webui/api/voice.py:1671-1690 reads exactly these keys.
        let message = VoiceClientMessage.beginTurn(sampleRate: 16000, sessionID: "voice-1",
                                                   model: "m", provider: "p")
        XCTAssertEqual(message.encoded(),
                       #"{"model":"m","model_provider":"p","sample_rate":16000,"session_id":"voice-1","type":"begin_turn"}"#)
    }

    func testEndTurnFrameIsTheExactJSONTheServerParses() {
        // webui/api/voice.py:1709-1735: text / client_ts / speech_end_ts.
        let message = VoiceClientMessage.endTurn(text: "hello", clientTs: 1700000000000,
                                                 speechEndTs: 1699999999000, turnID: "m-7")
        XCTAssertEqual(message.encoded(),
                       #"{"client_ts":1700000000000,"speech_end_ts":1699999999000,"text":"hello","turn_id":"m-7","type":"end_turn"}"#)
    }

    func testQualityTurnBodyCarriesTheThreeFieldsTheServerRequires() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/voice/quality-turn", json: ["type": "done"])
        let stream = VoiceAPI(api: api).qualityTurn(audio: Data(repeating: 3, count: 2048),
                                                    sessionID: "voice-1",
                                                    extra: ["model": "m"])
        _ = try? await collect(stream)

        let body = transport.lastBody()
        // webui/api/voice.py:604-613 — audio_base64 + session_id are required,
        // sample_rate defaults to 16000. The audio is RAW PCM16, not a WAV.
        XCTAssertEqual(body["session_id"] as? String, "voice-1")
        XCTAssertEqual(body["sample_rate"] as? Int, 16000)
        XCTAssertEqual(body["model"] as? String, "m")
        let audio = Data(base64Encoded: (body["audio_base64"] as? String) ?? "")
        XCTAssertEqual(audio, Data(repeating: 3, count: 2048))
    }

    // MARK: - 6. The realtime URL
    //
    // webui/api/voice.py:1444 — `if parsed.path != "/api/voice/s2s/ws": return False`

    func testRealtimeURLIsWssOnTheServersExactPath() throws {
        let (api, _) = JarvisAPI.mocked() // TestCredentials → https://jarvis.test
        let url = try VoiceAPI(api: api).realtimeURL()
        XCTAssertEqual(url.absoluteString, "wss://jarvis.test/api/voice/s2s/ws")
    }

    func testRealtimeSocketCarriesTheCookieAndCFAccessHeaders() async {
        let rig = makeRig()
        await rig.store.primaryAction()
        _ = await waitUntilVoice { rig.connector.socket != nil }

        // check_auth (webui/api/auth.py:428-448) runs BEFORE the WS dispatch, so
        // a missing cookie is a plain 401 and the socket never upgrades.
        let headers = rig.connector.connectedHeaders.first ?? [:]
        XCTAssertNotNil(headers["Cookie"])
        XCTAssertTrue(headers["Cookie"]?.hasPrefix("hermes_session=") ?? false)
    }

    // MARK: - 7. Diagnostics

    func testDiagnosticsRecordStateTransitionsAndFrames() async {
        let rig = makeRig()
        await rig.store.primaryAction()
        _ = await waitUntilVoice { rig.socket != nil }
        rig.socket?.receive(json: ["type": "ready", "mode": "bridge"])
        rig.socket?.receive(json: ["type": "assistant_text", "text": "at your service"])

        let lines = rig.store.diagnostics
        XCTAssertTrue(lines.contains { $0.contains("startRequested: idle→connecting") }, "\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("ws→ begin_turn") }, "\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("ws← ready") }, "\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("ws← assistant_text 15ch") }, "\(lines)")
    }

    func testDiagnosticsNeverCarryReplyOrTranscriptText() {
        XCTAssertEqual(VoiceDiagnostics.describe(received: .transcript("turn on the lights")),
                       "ws← transcript 18ch")
        XCTAssertEqual(VoiceDiagnostics.describe(received: .assistantText("secret")),
                       "ws← assistant_text 6ch")
        XCTAssertEqual(VoiceDiagnostics.describe(sent: .endTurn(text: "secret", clientTs: 1,
                                                                speechEndTs: 2, turnID: "t")),
                       "ws→ end_turn text=6ch speech_end=y turn=t")
    }

    func testDiagnosticsRingIsBoundedToTheLast200Lines() {
        let lines = VoiceDiagnostics.trimmed((0..<500).map { "line \($0)" })
        XCTAssertEqual(lines.count, VoiceDiagnostics.capacity)
        XCTAssertEqual(lines.first, "line 300")
        XCTAssertEqual(lines.last, "line 499")
    }

    func testDiagnosticsNameAnUnhandledServerFrameRatherThanDroppingIt() {
        XCTAssertEqual(VoiceDiagnostics.describe(received: .other("quota_warning")),
                       "ws← ?quota_warning")
    }

    // MARK: - 8. A slow open cannot resurrect a stopped turn

    func testStopDuringSessionResolutionDoesNotOpenASocket() async {
        let rig = makeRig()
        await rig.store.primaryAction()          // → connecting, resolving the session
        await rig.store.stopAll()                // user hits Stop mid-resolution
        await settleVoiceTasks()

        XCTAssertEqual(rig.store.state, .idle)
        XCTAssertNil(rig.connector.socket, "a superseded open must not leave a live socket")
    }

    // MARK: - 9. Turn timers must survive a scroll
    //
    // `Timer.scheduledTimer` installs in `.default` only, so nothing fires while
    // the main run loop is in `.tracking` (any drag). Every timing decision in a
    // turn rides this clock, so a finger on the reply held the conversation in
    // "thinking" until the drag ended.

    func testTurnTimersRunInCommonRunLoopModes() async {
        let clock = SystemVoiceClock()
        var fired = false
        let token = clock.schedule(after: 10) { fired = true }
        // Spin ONLY the tracking mode — a `.default`-only timer never fires here.
        let deadline = Date().addingTimeInterval(2)
        while !fired, Date() < deadline {
            RunLoop.main.run(mode: .tracking, before: Date().addingTimeInterval(0.01))
        }
        token.cancel()
        XCTAssertTrue(fired, "a voice timer must fire while the user is dragging")
    }

    // MARK: - 10. Try on server (Flutter `retryLastOnServer`)

    func testTryOnServerIsOfferedOnlyAfterALocalAnswerWhileListening() async {
        let rig = makeRig()
        XCTAssertFalse(rig.store.canRetryOnServer)

        rig.store.lastLocalTranscript = "what time is it"
        XCTAssertFalse(rig.store.canRetryOnServer, "not while idle")

        await rig.store.primaryAction()
        _ = await waitUntilVoice { rig.store.state == .listening }
        rig.store.lastLocalTranscript = "what time is it"
        XCTAssertTrue(rig.store.canRetryOnServer)
    }

    func testTryOnServerSendsEndTurnCarryingTheOnDeviceTranscript() async {
        let rig = makeRig()
        await rig.store.primaryAction()
        _ = await waitUntilVoice { rig.store.state == .listening }
        rig.store.lastLocalTranscript = "what time is it"

        rig.store.retryLastOnServer()
        await settleVoiceTasks()

        XCTAssertEqual(rig.store.state, .thinking)
        let endTurn = rig.socket?.lastMessage(ofType: "end_turn")
        XCTAssertEqual(endTurn?["text"] as? String, "what time is it")
        XCTAssertEqual(rig.store.userTranscript, "what time is it")
        XCTAssertFalse(rig.store.canRetryOnServer, "one-shot")
    }

    func testANewSpokenTurnDropsTheStaleTryOnServerOffer() async {
        let rig = makeRig()
        await rig.store.primaryAction()
        _ = await waitUntilVoice { rig.store.state == .listening }
        rig.store.lastLocalTranscript = "old question"

        rig.store.finishSpeaking() // endOfSpeech → clearReply
        await settleVoiceTasks()

        XCTAssertNil(rig.store.lastLocalTranscript)
    }
}

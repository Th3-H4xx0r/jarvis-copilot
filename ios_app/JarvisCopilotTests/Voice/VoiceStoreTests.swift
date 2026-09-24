import XCTest
@testable import JarvisCopilot

/// End-to-end turns through `VoiceStore` with every platform boundary mocked:
/// realtime and push-to-talk, barge-in, interrupt, cancel, error, engine
/// persistence and audio-session interruptions.
@MainActor
final class VoiceStoreTests: XCTestCase {

    private struct Rig {
        let store: VoiceStore
        let transport: MockTransport
        let input: MockAudioInput
        let output: MockAudioOutput
        let recognizer: MockSpeechRecognizing
        let synthesizer: MockVoiceSynthesizing
        let audioSession: MockAudioSessionControlling
        let connector: MockVoiceSocketConnector
        let clock: TestVoiceClock
        let prefs: MemoryKeyValueStore
        // The nested struct isn't actor-isolated even though the test class is.
        @MainActor var socket: MockVoiceSocket? { connector.socket }
    }

    private func makeRig(mode: VoiceMode = .realtime,
                         prefs: MemoryKeyValueStore = MemoryKeyValueStore(),
                         launch: VoiceLaunchRequesting? = nil,
                         devices: Any = [],
                         transcription: VoiceTranscription = .server) -> Rig {
        let (api, transport) = JarvisAPI.mocked()
        // Routed (not FIFO) so background chatter can't eat a queued reply.
        transport.route("/api/voice/session", json: ["session_id": "voice-1"])
        transport.route("/api/devices", json: devices)
        transport.route("/api/session", json: ["session": ["active_stream_id": ""]])

        let input = MockAudioInput()
        let output = MockAudioOutput()
        let recognizer = MockSpeechRecognizing()
        let synthesizer = MockVoiceSynthesizing()
        let audioSession = MockAudioSessionControlling()
        let connector = MockVoiceSocketConnector()
        let clock = TestVoiceClock()
        prefs.set(mode.rawValue, forKey: VoiceSettings.modeKey)
        prefs.set(transcription.rawValue, forKey: VoiceSettings.transcriptionKey)

        let store = VoiceStore(api: api, input: input, output: output, recognizer: recognizer,
                                synthesizer: synthesizer, audioSession: audioSession,
                                connector: connector, clock: clock, keyValueStore: prefs,
                                launch: launch)
        return Rig(store: store, transport: transport, input: input, output: output,
                   recognizer: recognizer, synthesizer: synthesizer, audioSession: audioSession,
                   connector: connector, clock: clock, prefs: prefs)
    }

    /// Start a realtime session and settle on whatever state it lands in.
    private func startListening(_ rig: Rig) async {
        await rig.store.primaryAction()
        await waitUntilVoice { rig.store.state != .connecting }
        await settleVoiceTasks()
    }

    /// Speak, then go quiet long enough for the endpointer to close the turn.
    private func speakThenPause(_ rig: Rig, ms: Int = 1500) async {
        rig.input.emitFrames(amplitude: 0.5, ms: ms)
        rig.input.emitFrames(amplitude: 0.0, ms: Endpointer.extendedSilenceMs + 100)
        await settleVoiceTasks()
    }

    /// Drive a reply through to `speaking`.
    private func replyWithAudio(_ rig: Rig, text: String = "Clear skies.", audioMs: Int = 200) async throws {
        let socket = try XCTUnwrap(rig.socket)
        socket.receive(json: ["type": "assistant_text", "text": text])
        socket.receive(json: ["type": "audio_meta", "format": "pcm_s16le", "sample_rate": 24000])
        socket.receive(binary: replyPcm(ms: audioMs))
        await settleVoiceTasks()
        await rig.store.audio.settle()
    }

    // MARK: - Realtime start

    func testStartOpensTheSocketOwnsTheAudioSessionAndListens() async throws {
        let rig = makeRig()
        await startListening(rig)

        XCTAssertEqual(rig.store.state, .listening)
        XCTAssertEqual(rig.connector.connectedURLs.map(\.absoluteString),
                       ["wss://jarvis.test/api/voice/s2s/ws"])
        // The turn asserts the conversation category on the way in AND again in
        // `startMic` — `AVAudioSession` is process-wide and `BackgroundKeepalive`
        // / `SkillBoundariesMedia` both move it, so "configure once per launch"
        // was how a later turn ended up recording under `.playback`.
        // `DefaultAudioSessionControlling` is idempotent against the LIVE session,
        // so re-asserting is free; what matters is that it happens before the mic.
        XCTAssertTrue(rig.audioSession.configureCount >= 1)
        XCTAssertEqual(rig.audioSession.activeCalls.first, true)
        XCTAssertEqual(rig.input.startedRates, [VoiceStore.micRate])

        let socket = try XCTUnwrap(rig.socket)
        XCTAssertEqual(socket.sentTypes, ["begin_turn"])
        XCTAssertEqual(socket.sentJSON.first?["session_id"] as? String, "voice-1")
        XCTAssertEqual(socket.sentJSON.first?["sample_rate"] as? Int, 16000)
        XCTAssertEqual(rig.store.sessionID, "voice-1")
        // Server transcription (the default): the on-device engine is never
        // armed — the audio is the server's to transcribe.
        XCTAssertEqual(rig.recognizer.startCount, 0, "server mode arms no recognizer")
    }

    func testOnDeviceStartArmsTheRecognizerForTheUtterance() async throws {
        let rig = makeRig(transcription: .onDevice)
        await startListening(rig)
        XCTAssertEqual(rig.store.state, .listening)
        XCTAssertGreaterThanOrEqual(rig.recognizer.startCount, 1, "the recognizer is armed")
        XCTAssertEqual(rig.recognizer.promptFlags.last, true,
                       "on-device mode was chosen, so asking for permission is expected")
    }

    // MARK: - Startup latency

    func testTheMicStartsWhileTheSocketIsStillConnecting() async throws {
        let rig = makeRig()
        rig.connector.holdConnect = true
        await rig.store.primaryAction()
        await waitUntilVoice { !rig.input.startedRates.isEmpty }
        XCTAssertEqual(rig.store.state, .connecting)
        XCTAssertEqual(rig.input.startedRates, [VoiceStore.micRate],
                       "the mic does not wait for the socket")
        rig.connector.releaseConnect()
        await waitUntilVoice { rig.store.state == .listening }
    }

    func testWordsSpokenWhileConnectingReachTheServerAfterBeginTurn() async throws {
        let rig = makeRig()
        rig.connector.holdConnect = true
        await rig.store.primaryAction()
        await waitUntilVoice { !rig.input.startedRates.isEmpty }
        rig.input.emitFrames(amplitude: 0.5, ms: 400)
        await settleVoiceTasks()

        rig.connector.releaseConnect()
        await waitUntilVoice { rig.store.state == .listening }
        await settleVoiceTasks()

        let socket = try XCTUnwrap(rig.socket)
        XCTAssertFalse(socket.sentData.isEmpty, "audio from the connecting window was kept")
        XCTAssertEqual(socket.textsBeforeFirstData, 1, "begin_turn went out before any audio")
        XCTAssertEqual(socket.sentTypes.first, "begin_turn")
    }

    func testTheConnectingBufferKeepsOnlyTheMostRecentAudio() async throws {
        let rig = makeRig()
        rig.connector.holdConnect = true
        await rig.store.primaryAction()
        await waitUntilVoice { !rig.input.startedRates.isEmpty }
        rig.input.emitFrames(amplitude: 0.5, ms: VoiceStore.preConnectBufferMs * 3)
        await settleVoiceTasks()
        XCTAssertLessThanOrEqual(rig.store.preConnectBytes,
                                 VoiceStore.preConnectBufferMs * VoiceStore.micRate * 2 / 1000 + 4096,
                                 "a slow connect cannot grow the buffer without bound")
        rig.connector.releaseConnect()
        await waitUntilVoice { rig.store.state == .listening }
    }

    func testStartupIsMeasuredInTheDiagnostics() async throws {
        let rig = makeRig()
        await startListening(rig)
        rig.input.emitFrames(amplitude: 0.1, ms: 60)
        await settleVoiceTasks()
        let line = try XCTUnwrap(rig.store.diagnostics.last { $0.contains("startup:") })
        for part in ["checks=", "session=", "socket=", "mic=", "total="] {
            XCTAssertTrue(line.contains(part), "\(part) missing from \(line)")
        }
    }

    func testPrewarmOpensTheSocketAndTheNextStartReusesIt() async throws {
        let rig = makeRig()
        await rig.store.prewarmVoice()
        XCTAssertEqual(rig.connector.connectedURLs.count, 1)
        let warm = try XCTUnwrap(rig.socket)
        XCTAssertTrue(warm.sentTypes.isEmpty, "a warm socket says nothing until a turn starts")

        await startListening(rig)
        XCTAssertEqual(rig.connector.connectedURLs.count, 1, "the start adopted the warm socket")
        XCTAssertTrue(rig.socket === warm)
        XCTAssertEqual(warm.sentTypes, ["begin_turn"])
    }

    func testStartingWhileTheWarmUpIsStillConnectingUsesThatSocket() async throws {
        let rig = makeRig()
        rig.connector.holdConnect = true
        let warming = Task { await rig.store.prewarmVoice() }
        await waitUntilVoice { rig.connector.heldCount == 1 }

        await rig.store.primaryAction()
        await settleVoiceTasks()
        XCTAssertEqual(rig.connector.heldCount, 1,
                       "the start waits for the warm-up's handshake instead of dialing a second socket")

        rig.connector.releaseConnect()
        await waitUntilVoice { rig.store.state == .listening }
        await warming.value
        XCTAssertEqual(rig.connector.connectedURLs.count, 1)
        XCTAssertEqual(rig.socket?.sentTypes, ["begin_turn"])
        XCTAssertEqual(rig.socket?.closeCount, 0)
    }

    func testStoppingATurnWaitingOnTheWarmUpLeavesNoSocket() async throws {
        let rig = makeRig()
        rig.connector.holdConnect = true
        let warming = Task { await rig.store.prewarmVoice() }
        await waitUntilVoice { rig.connector.heldCount == 1 }
        await rig.store.primaryAction()
        await settleVoiceTasks()

        rig.store.voiceSurfaceHidden()
        await rig.store.stopAll()
        rig.connector.releaseConnect()
        await warming.value
        await settleVoiceTasks()

        XCTAssertEqual(rig.store.state, .idle)
        XCTAssertEqual(rig.connector.connectedURLs.count, 1, "nothing dials again after the stop")
        XCTAssertEqual(rig.socket?.closeCount, 1, "the warm-up's socket is closed when it lands")
        XCTAssertFalse(rig.store.session.isOpen)
    }

    func testAnUnusedWarmSocketIsClosedAfterTheIdleTimeout() async throws {
        let rig = makeRig()
        await rig.store.prewarmVoice()
        let warm = try XCTUnwrap(rig.socket)
        rig.clock.advance(ms: VoiceStore.warmSocketIdleMs + 10)
        await settleVoiceTasks()
        XCTAssertEqual(warm.closeCount, 1)
    }

    func testAWarmSocketTheServerDroppedIsReplacedOnStart() async throws {
        let rig = makeRig()
        await rig.store.prewarmVoice()
        try XCTUnwrap(rig.socket).serverClosed()
        await settleVoiceTasks()
        XCTAssertNil(rig.store.error, "a warm socket closing while idle is not an error")

        await startListening(rig)
        XCTAssertEqual(rig.connector.connectedURLs.count, 2)
        XCTAssertEqual(rig.store.state, .listening)
    }

    func testPrewarmPreparesTheMicWithoutOpeningIt() async {
        let rig = makeRig()
        await rig.store.prewarmVoice()
        XCTAssertEqual(rig.input.preparedRates, [VoiceStore.micRate])
        XCTAssertTrue(rig.input.startedRates.isEmpty, "preparing must not start recording")
        XCTAssertFalse(rig.input.isRunning)
    }

    func testTheMicIsPreparedEvenWhenTheSocketIsAlreadyWarm() async {
        let rig = makeRig()
        await rig.store.prewarmVoice()
        await rig.store.prewarmVoice()
        XCTAssertEqual(rig.connector.connectedURLs.count, 1)
        XCTAssertEqual(rig.input.preparedRates.count, 2)
    }

    func testLeavingTheVoiceSurfaceReleasesThePreparedMic() async {
        let rig = makeRig()
        await rig.store.prewarmVoice()
        rig.store.voiceSurfaceHidden()
        XCTAssertEqual(rig.input.releaseCount, 1)
    }

    func testLeavingTheVoiceSurfaceMidConversationKeepsTheMic() async {
        let rig = makeRig()
        await startListening(rig)
        rig.store.voiceSurfaceHidden()
        XCTAssertEqual(rig.input.releaseCount, 0)
        XCTAssertTrue(rig.input.isRunning)
    }

    func testMicPermissionDenialBlocksTheTurn() async {
        let rig = makeRig()
        rig.input.permission = false
        await startListening(rig)

        XCTAssertEqual(rig.store.state, .idle)
        XCTAssertNotNil(rig.store.error)
        XCTAssertTrue(rig.connector.connectedURLs.isEmpty)
        XCTAssertTrue(rig.input.startedRates.isEmpty)
    }

    func testAFailedConnectEntersErrorAndTearsDown() async {
        let rig = makeRig()
        rig.connector.connectError = APIError.badResponse("handshake failed")
        await startListening(rig)

        XCTAssertEqual(rig.store.state, .error)
        XCTAssertTrue(rig.store.error?.hasPrefix("Could not start voice") ?? false, rig.store.error ?? "")
        XCTAssertGreaterThan(rig.input.stopCount, 0)
    }

    func testAMicThatWontStartEntersError() async {
        let rig = makeRig()
        rig.input.startError = VoiceAudioError.micUnavailable("no input route")
        await startListening(rig)
        XCTAssertEqual(rig.store.state, .error)
        XCTAssertNotNil(rig.store.error)
    }

    // MARK: - A full realtime turn

    func testEndOfSpeechStreamsThePcmAndSendsEndTurn() async throws {
        let rig = makeRig()
        rig.recognizer.isAvailable = false // no on-device STT → server STT
        await startListening(rig)
        await speakThenPause(rig)

        XCTAssertEqual(rig.store.state, .thinking)
        let socket = try XCTUnwrap(rig.socket)
        XCTAssertFalse(socket.sentData.isEmpty, "the mic streamed while listening")
        XCTAssertEqual(socket.sentTypes, ["begin_turn", "end_turn"])
        let endTurn = try XCTUnwrap(socket.lastMessage(ofType: "end_turn"))
        XCTAssertNil(endTurn["text"], "no on-device transcript → the server runs its own STT")
        XCTAssertNotNil(endTurn["turn_id"])
        XCTAssertNotNil(endTurn["speech_end_ts"])
    }

    func testOnDeviceSendsTheTranscriptAndNoAudio() async throws {
        let rig = makeRig(transcription: .onDevice)
        rig.recognizer.nextTranscript = "turn on the lights"
        await startListening(rig)
        await speakThenPause(rig)

        let socket = try XCTUnwrap(rig.socket)
        XCTAssertTrue(socket.sentData.isEmpty, "on-device mode never streams audio")
        let endTurn = try XCTUnwrap(socket.lastMessage(ofType: "end_turn"))
        XCTAssertEqual(endTurn["text"] as? String, "turn on the lights")
        XCTAssertEqual(rig.store.userTranscript, "turn on the lights")
        XCTAssertGreaterThan(rig.recognizer.latest?.fedBytes ?? 0, 0,
                             "the recognizer got the mic frames")
    }

    func testServerTranscriptionNeverStartsTheRecognizer() async throws {
        let rig = makeRig()
        rig.recognizer.nextTranscript = "must never be used"
        await startListening(rig)
        await speakThenPause(rig)

        let socket = try XCTUnwrap(rig.socket)
        XCTAssertEqual(rig.recognizer.startCount, 0, "server mode: no on-device engine at all")
        XCTAssertEqual(rig.recognizer.prepareCount, 0)
        XCTAssertFalse(socket.sentData.isEmpty, "server mode streams the audio")
        XCTAssertNil(socket.lastMessage(ofType: "end_turn")?["text"])
    }

    func testOnDeviceThatHeardNoWordsSendsNothingAndKeepsListening() async throws {
        let rig = makeRig(transcription: .onDevice)
        rig.recognizer.nextTranscript = ""
        await startListening(rig)
        await speakThenPause(rig)

        let socket = try XCTUnwrap(rig.socket)
        XCTAssertFalse(socket.sentTypes.contains("end_turn"), "no words → nothing goes to the server")
        XCTAssertEqual(rig.store.toolStatus, "Didn't catch that")
        XCTAssertNil(rig.store.error, "a miss is not a failure")

        rig.clock.advance(ms: VoiceStore.resumeGraceMs + 10)
        await settleVoiceTasks()
        XCTAssertEqual(rig.store.state, .listening)
    }

    func testAMissLeavesNoWordsOnScreen() async throws {
        // The engine guessed words, then committed none: nothing is sent, so
        // nothing should stand on screen as what the user said.
        let rig = makeRig(transcription: .onDevice)
        rig.recognizer.nextTranscript = ""
        await startListening(rig)
        try XCTUnwrap(rig.recognizer.latest).emitPartial("uh")
        await speakThenPause(rig)

        XCTAssertFalse(try XCTUnwrap(rig.socket).sentTypes.contains("end_turn"))
        XCTAssertEqual(rig.store.userTranscript, "")
        XCTAssertEqual(rig.store.livePartial, "")
    }

    func testTheLivePartialSurvivesTheEndOfSpeechClear() async throws {
        let rig = makeRig(transcription: .onDevice)
        await startListening(rig)
        let speech = try XCTUnwrap(rig.recognizer.latest)
        speech.stallStop = true
        speech.emitPartial("what time is it")

        await speakThenPause(rig)
        XCTAssertEqual(rig.store.userTranscript, "what time is it",
                       "the words stay on screen while the final transcript is awaited")
    }

    func testOnDeviceThatCannotRunUsesSonioxAndSaysWhy() async throws {
        // This device cannot transcribe (permission, language): the turn goes to
        // the server's engine instead of not starting, and the panel says why.
        let rig = makeRig(transcription: .onDevice)
        rig.recognizer.readiness = .denied
        await startListening(rig)
        await speakThenPause(rig)

        let socket = try XCTUnwrap(rig.socket)
        XCTAssertFalse(socket.sentData.isEmpty, "the audio goes to the server")
        XCTAssertEqual(rig.recognizer.startCount, 0)
        XCTAssertEqual(rig.store.transcriptionInUse, .server)
        XCTAssertEqual(rig.store.onDeviceFallback, SpeechReadiness.denied.message)
        XCTAssertNil(rig.store.error)
        XCTAssertEqual(rig.store.transcription, .onDevice, "the choice itself is kept")
    }

    func testChoosingOnDevicePreparesAndReportsReady() async {
        let rig = makeRig()
        await rig.store.setTranscription(.onDevice)
        XCTAssertEqual(rig.store.transcription, .onDevice)
        XCTAssertEqual(rig.store.transcriptionStatus, .ready)
        XCTAssertEqual(rig.prefs.string(VoiceSettings.transcriptionKey), "on_device")
    }

    func testChoosingOnDeviceSurfacesAFailedPrepare() async {
        let rig = makeRig()
        rig.recognizer.readiness = .unsupportedLanguage("Klingon")
        await rig.store.setTranscription(.onDevice)
        XCTAssertEqual(rig.store.transcriptionStatus,
                       .failed(SpeechReadiness.unsupportedLanguage("Klingon").message))
    }

    func testQualityOnDevicePostsTextAndNoAudio() async throws {
        let rig = makeRig(mode: .quality, transcription: .onDevice)
        rig.recognizer.nextTranscript = "hello there"
        rig.transport.enqueue(text: """
        {"type":"segment","kind":"text","text":"Hi.","audio_base64":"\(Data([9, 9]).base64EncodedString())"}
        {"type":"done"}
        """, contentType: "application/x-ndjson")

        await rig.store.primaryAction()
        await settleVoiceTasks()
        rig.input.emitFrames(amplitude: 0.5, ms: 300)
        await rig.store.primaryAction()
        await settleVoiceTasks()

        let posted = try XCTUnwrap(rig.transport.requests.first { $0.url?.path == "/api/voice/quality-turn" })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: posted.httpBody ?? Data()) as? [String: Any])
        XCTAssertEqual(body["text"] as? String, "hello there")
        XCTAssertNil(body["audio_base64"], "on-device push-to-talk uploads no audio")
        XCTAssertGreaterThan(rig.recognizer.latest?.fedBytes ?? 0, 0)
    }

    func testQualityOnDeviceWithNoWordsSaysSoAndPostsNothing() async {
        let rig = makeRig(mode: .quality, transcription: .onDevice)
        rig.recognizer.nextTranscript = ""
        await rig.store.primaryAction()
        await settleVoiceTasks()
        rig.input.emitFrames(amplitude: 0.5, ms: 300)
        await rig.store.primaryAction()
        await settleVoiceTasks()

        XCTAssertNil(rig.transport.requests.first { $0.url?.path == "/api/voice/quality-turn" })
        XCTAssertEqual(rig.store.error, "Didn't catch that — try again.")
    }

    func testTheReplyWalksThinkingToSpeakingToListening() async throws {
        let rig = makeRig()
        await startListening(rig)
        await speakThenPause(rig)

        let socket = try XCTUnwrap(rig.socket)
        socket.receive(json: ["type": "assistant_text", "text": "Clear **skies** today."])
        await settleVoiceTasks()
        XCTAssertEqual(rig.store.state, .thinking, "text alone doesn't mean audio yet")
        XCTAssertEqual(rig.store.assistantText, "Clear skies today.")

        socket.receive(json: ["type": "audio_meta", "format": "pcm_s16le", "sample_rate": 24000])
        socket.receive(binary: replyPcm(ms: 200))
        await settleVoiceTasks()
        await rig.store.audio.settle()
        XCTAssertEqual(rig.store.state, .speaking)
        XCTAssertEqual(rig.output.startedStreams, [24000])

        socket.receive(json: ["type": "audio_end"])
        // The server closes the turn; until it does, a drained reply stays in
        // thinking (an ack before a long tool run is not the end of the turn).
        socket.receive(json: ["type": "end_turn"])
        await settleVoiceTasks()
        await rig.store.audio.settle()

        rig.clock.advance(ms: 200 + AudioQueue.nativeIdleGraceMs + AudioQueue.nativeTickMs)
        await settleVoiceTasks()
        XCTAssertEqual(rig.store.state, .thinking, "wait a beat for a trailing segment")

        rig.clock.advance(ms: VoiceStore.resumeGraceMs + 10)
        await settleVoiceTasks()
        XCTAssertEqual(rig.store.state, .listening)
        XCTAssertEqual(rig.store.spokenWords, rig.store.replySegments.reduce(0) { $0 + $1.words.count },
                       "the highlight is finalized when the reply ends")
    }

    func testTranscriptAndToolFramesDriveTheOnScreenLines() async throws {
        let rig = makeRig()
        await startListening(rig)
        let socket = try XCTUnwrap(rig.socket)

        socket.receive(json: ["type": "transcript", "text": "what's the weather"])
        await settleVoiceTasks()
        XCTAssertEqual(rig.store.userTranscript, "what's the weather")

        socket.receive(json: ["type": "tool", "name": "search_web", "status": "started"])
        await settleVoiceTasks()
        XCTAssertEqual(rig.store.toolStatus, "Running search_web")
        XCTAssertEqual(rig.store.state, .thinking)

        socket.receive(json: ["type": "tool", "name": "search_web", "status": "completed"])
        await settleVoiceTasks()
        XCTAssertNil(rig.store.toolStatus)
    }

    func testMp3RepliesAreBufferedUntilAudioEnd() async throws {
        let rig = makeRig()
        await startListening(rig)
        await speakThenPause(rig)
        let socket = try XCTUnwrap(rig.socket)

        socket.receive(json: ["type": "assistant_text", "text": "Hello."])
        socket.receive(json: ["type": "audio_meta", "format": "mp3", "sample_rate": 24000])
        socket.receive(binary: Data([1, 2, 3]))
        socket.receive(binary: Data([4, 5]))
        await settleVoiceTasks()
        await rig.store.audio.settle()
        XCTAssertTrue(rig.output.played.isEmpty, "the decoder needs the whole file")

        socket.receive(json: ["type": "audio_end"])
        await settleVoiceTasks()
        await rig.store.audio.settle()
        XCTAssertEqual(rig.output.played.count, 1)
        XCTAssertEqual(rig.output.played.first?.ext, "mp3")
        XCTAssertEqual(rig.output.played.first?.bytes, Data([1, 2, 3, 4, 5]))
        XCTAssertEqual(rig.store.state, .speaking)
    }

    // MARK: - Barge-in

    /// A reply long enough to talk over, past the moment right after playback
    /// starts when barge-in is not listening yet.
    private func speakingAndSettled(_ rig: Rig) async throws {
        await startListening(rig)
        await speakThenPause(rig)
        try await replyWithAudio(rig, audioMs: 5000)
        rig.clock.advance(ms: VoiceStore.bargeInSettleMs)
        XCTAssertEqual(rig.store.state, .speaking)
    }

    func testTalkingOverTheReplyInterruptsIt() async throws {
        let rig = makeRig()
        try await speakingAndSettled(rig)

        rig.input.emitFrames(amplitude: 0.06, ms: VoiceStore.bargeInSustainMs - 20)
        await settleVoiceTasks()
        XCTAssertEqual(rig.store.state, .speaking, "not yet — a moment of sound is not a sentence")

        rig.input.emitFrames(amplitude: 0.06, ms: 20)
        await settleVoiceTasks()
        await rig.store.audio.settle()
        XCTAssertEqual(rig.store.state, .listening)
        let socket = try XCTUnwrap(rig.socket)
        XCTAssertTrue(socket.sentTypes.contains("interrupt"))
        XCTAssertGreaterThan(rig.output.flushCount, 0, "queued reply audio is dropped")
        XCTAssertGreaterThan(rig.synthesizer.stopCount, 0)
    }

    // Measured on the phone: echo under the reply peaks 0.005–0.009 per 100 ms
    // frame; ordinary speech over it ~0.014, peaks to 0.034. The Mac's 0.03 bar
    // needed a shout.

    func testSpeakingOverTheReplyAtAnOrdinaryVolumeOnThePhoneInterruptsIt() async throws {
        let rig = makeRig()
        try await speakingAndSettled(rig)
        rig.input.emitFrames(amplitude: 0.005, ms: 2000, frameMs: 100)   // the reply's echo

        rig.input.emitFrames(amplitude: 0.016, ms: 400, frameMs: 100)    // "wait, stop"
        await settleVoiceTasks()
        XCTAssertEqual(rig.store.state, .listening, "a normal voice is enough")
    }

    /// Cutting in early, when the echo window is only a few frames long: your
    /// own first words must not become the "echo" the bar is measured against.
    func testCuttingInRightAfterTheReplyStartsWorks() async throws {
        let rig = makeRig()
        await startListening(rig)
        await speakThenPause(rig)
        try await replyWithAudio(rig, audioMs: 5000)
        rig.input.emitFrames(amplitude: 0.006, ms: VoiceStore.bargeInSettleMs, frameMs: 100)
        rig.clock.advance(ms: VoiceStore.bargeInSettleMs)
        rig.input.emitFrames(amplitude: 0.006, ms: 200, frameMs: 100)

        rig.input.emitFrames(amplitude: 0.018, ms: 500, frameMs: 100)
        await settleVoiceTasks()
        XCTAssertEqual(rig.store.state, .listening)
    }

    /// A reply that gets steadily louder over a couple of seconds: its echo
    /// ages into the level and lifts the bar with it.
    func testAReplyThatGrowsLouderDoesNotInterruptItself() async throws {
        let rig = makeRig()
        await startListening(rig)
        await speakThenPause(rig)
        try await replyWithAudio(rig, audioMs: 8000)
        rig.input.emitFrames(amplitude: 0.006, ms: VoiceStore.bargeInSettleMs, frameMs: 100)
        rig.clock.advance(ms: VoiceStore.bargeInSettleMs)
        for step in 0..<40 {
            let level = 0.006 + Double(step) * 0.0006          // 0.006 → 0.030 over 4 s
            rig.input.emitFrames(amplitude: step % 3 == 0 ? level * 0.3 : level, ms: 100, frameMs: 100)
        }
        await settleVoiceTasks()
        XCTAssertEqual(rig.store.state, .speaking)
    }

    func testTheEchoOfTheReplyAloneNeverInterruptsOnThePhone() async throws {
        let rig = makeRig()
        try await speakingAndSettled(rig)
        for _ in 0..<40 {
            rig.input.emitFrames(amplitude: 0.004, ms: 100, frameMs: 100)
            rig.input.emitFrames(amplitude: 0.009, ms: 100, frameMs: 100)
        }
        await settleVoiceTasks()
        XCTAssertEqual(rig.store.state, .speaking)
    }

    /// At high volume the phone's echo peaks well above the speech gate, in
    /// syllable-shaped bursts. Seen on device: barge-in fired about a second into
    /// replies with nobody talking, and the "speech" it then sent was the reply.
    func testTheEchoOfALoudReplyDoesNotInterruptIt() async throws {
        let rig = makeRig()
        await startListening(rig)
        await speakThenPause(rig)
        try await replyWithAudio(rig, audioMs: 8000)
        // Syllable-shaped: loud peaks with near-silent frames between words, so a
        // low percentile of it sits far under its peaks.
        let loudEcho: [Double] = [0.003, 0.028, 0.035, 0.004, 0.031, 0.026, 0.005, 0.033]
        // Heard from the first moment of playback, through the settle window.
        for amp in loudEcho.prefix(5) { rig.input.emitFrames(amplitude: amp, ms: 100, frameMs: 100) }
        rig.clock.advance(ms: VoiceStore.bargeInSettleMs)
        for _ in 0..<6 {
            for amp in loudEcho { rig.input.emitFrames(amplitude: amp, ms: 100, frameMs: 100) }
        }
        await settleVoiceTasks()
        XCTAssertEqual(rig.store.state, .speaking)
        XCTAssertFalse(try XCTUnwrap(rig.socket).sentTypes.contains("interrupt"))
    }

    func testARaisedVoiceStillCutsThroughALoudReply() async throws {
        let rig = makeRig()
        await startListening(rig)
        await speakThenPause(rig)
        try await replyWithAudio(rig, audioMs: 8000)
        // Syllable-shaped: loud peaks with near-silent frames between words, so a
        // low percentile of it sits far under its peaks.
        let loudEcho: [Double] = [0.003, 0.028, 0.035, 0.004, 0.031, 0.026, 0.005, 0.033]
        for amp in loudEcho.prefix(5) { rig.input.emitFrames(amplitude: amp, ms: 100, frameMs: 100) }
        rig.clock.advance(ms: VoiceStore.bargeInSettleMs)
        for _ in 0..<3 {
            for amp in loudEcho { rig.input.emitFrames(amplitude: amp, ms: 100, frameMs: 100) }
        }
        rig.input.emitFrames(amplitude: 0.08, ms: 400, frameMs: 100)
        await settleVoiceTasks()
        XCTAssertEqual(rig.store.state, .listening)
    }

    func testTalkingQuietlyFirstDoesNotRaiseTheBarAgainstYou() async throws {
        let rig = makeRig()
        try await speakingAndSettled(rig)
        rig.input.emitFrames(amplitude: 0.004, ms: 2000, frameMs: 100)   // echo
        // Speech just under the bar used to be learned as echo and push the
        // bar up past the voice that followed it.
        rig.input.emitFrames(amplitude: 0.010, ms: 1000, frameMs: 100)
        rig.input.emitFrames(amplitude: 0.022, ms: 400, frameMs: 100)
        await settleVoiceTasks()
        XCTAssertEqual(rig.store.state, .listening)
    }

    func testASpikeOfEchoDoesNotInterrupt() async throws {
        let rig = makeRig()
        try await speakingAndSettled(rig)

        // Echo cancellation lets single frames through at well over 0.4.
        for _ in 0..<10 {
            rig.input.emitFrames(amplitude: 0.57, ms: 40)
            rig.input.emitFrames(amplitude: 0.003, ms: 200)
        }
        await settleVoiceTasks()
        XCTAssertEqual(rig.store.state, .speaking)
        XCTAssertFalse(try XCTUnwrap(rig.socket).sentTypes.contains("interrupt"))
    }

    func testTheRepliesUsualEchoDoesNotInterruptIt() async throws {
        let rig = makeRig()
        try await speakingAndSettled(rig)

        for _ in 0..<30 {   // three seconds: mostly quiet, short leaks
            rig.input.emitFrames(amplitude: 0.003, ms: 60)
            rig.input.emitFrames(amplitude: 0.05, ms: 40)
        }
        await settleVoiceTasks()
        XCTAssertEqual(rig.store.state, .speaking)
    }

    func testNothingCountsJustAfterPlaybackStarts() async throws {
        let rig = makeRig()
        await startListening(rig)
        await speakThenPause(rig)
        try await replyWithAudio(rig, audioMs: 5000)

        // The canceller is still adapting to the new audio: this is echo.
        rig.input.emitFrames(amplitude: 0.2, ms: VoiceStore.bargeInSettleMs - 50)
        await settleVoiceTasks()
        XCTAssertEqual(rig.store.state, .speaking)
    }

    func testLouderEchoRaisesTheBar() async throws {
        let rig = makeRig()
        await startListening(rig)
        await speakThenPause(rig)
        try await replyWithAudio(rig, audioMs: 5000)

        // Speakers turned up: steady echo at 0.02 — above the phone's gate on its
        // own, so the bar has to come from the echo, heard from the first moment.
        rig.input.emitFrames(amplitude: 0.02, ms: VoiceStore.bargeInSettleMs)
        rig.clock.advance(ms: VoiceStore.bargeInSettleMs)
        rig.input.emitFrames(amplitude: 0.02, ms: 3000)
        await settleVoiceTasks()
        XCTAssertEqual(rig.store.state, .speaking, "the reply's own echo must not interrupt it")

        rig.input.emitFrames(amplitude: 0.028, ms: 600)
        await settleVoiceTasks()
        XCTAssertEqual(rig.store.state, .speaking, "0.028 is not clearly above a 0.02 echo")

        rig.input.emitFrames(amplitude: 0.12, ms: VoiceStore.bargeInSustainMs)
        await settleVoiceTasks()
        XCTAssertEqual(rig.store.state, .listening)
    }

    func testTheWordsThatInterruptedReachTheServerAfterTheInterrupt() async throws {
        let rig = makeRig()
        try await speakingAndSettled(rig)
        let socket = try XCTUnwrap(rig.socket)
        let dataBefore = socket.sentData.count

        rig.input.emitFrames(amplitude: 0.06, ms: VoiceStore.bargeInSustainMs)
        await settleVoiceTasks()

        XCTAssertEqual(rig.store.state, .listening)
        XCTAssertGreaterThan(socket.sentData.count, dataBefore,
                             "the start of what they said is not thrown away")
        let interruptIndex = try XCTUnwrap(socket.sentText.firstIndex { $0.contains("\"interrupt\"") })
        XCTAssertEqual(interruptIndex, socket.sentText.count - 1, "nothing but audio after the interrupt")
    }

    /// What the phone did: the interrupt went out, then the rest of the reply
    /// the server had already sent arrived and was played anyway.
    func testTheRestOfAReplyThatWasCutOffIsNeverPlayed() async throws {
        let rig = makeRig()
        try await speakingAndSettled(rig)
        let socket = try XCTUnwrap(rig.socket)

        rig.input.emitFrames(amplitude: 0.06, ms: VoiceStore.bargeInSustainMs)
        await settleVoiceTasks()
        XCTAssertEqual(rig.store.state, .listening)
        let fed = rig.output.fed.count
        let text = rig.store.reply.text

        socket.receive(json: ["type": "assistant_text", "text": "And another thing about the weather."])
        socket.receive(json: ["type": "audio_meta", "format": "pcm_s16le", "sample_rate": 24000])
        socket.receive(binary: replyPcm(ms: 800))
        socket.receive(json: ["type": "audio_end"])
        await settleVoiceTasks()
        await rig.store.audio.settle()

        XCTAssertEqual(rig.store.state, .listening, "the reply does not come back")
        XCTAssertEqual(rig.output.fed.count, fed, "none of it reaches the speaker")
        XCTAssertEqual(rig.store.reply.text, text, "none of it is shown")

        socket.receive(json: ["type": "end_turn"])
        await settleVoiceTasks()
        XCTAssertEqual(rig.store.state, .listening)

        // The next turn is answered normally.
        await speakThenPause(rig)
        XCTAssertEqual(rig.store.state, .thinking)
        try await replyWithAudio(rig, text: "Here is the answer.")
        XCTAssertEqual(rig.store.state, .speaking)
        XCTAssertGreaterThan(rig.output.fed.count, fed)
    }

    func testBargeInIsIgnoredWhileBackgrounded() async throws {
        let rig = makeRig()
        try await speakingAndSettled(rig)
        rig.store.pauseForBackground()

        rig.input.emitFrames(amplitude: 0.3, ms: 1000)
        await settleVoiceTasks()

        // Backgrounded, the loud reply leaks past echo cancellation and would
        // falsely trip the threshold.
        XCTAssertEqual(rig.store.state, .speaking)
        XCTAssertFalse(try XCTUnwrap(rig.socket).sentTypes.contains("interrupt"))
    }

    func testMuteStopsStreamingAndAudioReactivity() async throws {
        let rig = makeRig()
        await startListening(rig)
        let socket = try XCTUnwrap(rig.socket)
        rig.store.toggleMute()
        XCTAssertTrue(rig.store.muted)

        rig.input.emit(amplitude: 0.5, ms: 20)
        await settleVoiceTasks()

        XCTAssertTrue(socket.sentData.isEmpty, "muted frames never reach the server")
        XCTAssertEqual(rig.store.amplitude, 0, "muted audio must not look like it is being received")
        XCTAssertEqual(rig.store.state, .listening)
    }

    func testStartingANewConversationUnmutesTheMicrophone() async {
        let rig = makeRig()
        rig.store.muted = true
        await startListening(rig)
        XCTAssertFalse(rig.store.muted)
        await rig.store.stopAll()
    }

    func testLiveRecognitionUpdatesTheTranscriptAndIgnoresStaleSessions() async throws {
        let rig = makeRig(transcription: .onDevice)
        await startListening(rig)
        let speech = try XCTUnwrap(rig.recognizer.sessions.last)
        speech.emitPartial("A live sentence")
        XCTAssertEqual(rig.store.userTranscript, "A live sentence")
        rig.store.abortSpeechSession()
        speech.emitPartial("A stale callback")
        XCTAssertEqual(rig.store.userTranscript, "A live sentence")
        await rig.store.stopAll()
    }

    // MARK: - Interrupt / cancel

    func testTheInterruptButtonReturnsToListening() async throws {
        let rig = makeRig(transcription: .onDevice)
        await startListening(rig)
        await speakThenPause(rig)
        try await replyWithAudio(rig)

        rig.store.interrupt()
        await settleVoiceTasks()
        await rig.store.audio.settle()

        XCTAssertEqual(rig.store.state, .listening)
        let socket = try XCTUnwrap(rig.socket)
        XCTAssertTrue(socket.sentTypes.contains("interrupt"))
        let interrupt = try XCTUnwrap(socket.sentJSON.first { $0["type"] as? String == "interrupt" })
        XCTAssertNotNil(interrupt["heard"] as? String, "the server is told how much of the reply was heard")
        XCTAssertGreaterThan(rig.recognizer.startCount, 1, "a fresh recognizer for what they say now")
    }

    func testStopAllTearsEverythingDownButKeepsTheReplyOnScreen() async throws {
        let rig = makeRig()
        await startListening(rig)
        await speakThenPause(rig)
        try await replyWithAudio(rig, text: "Clear skies.")

        await rig.store.stopAll()
        await settleVoiceTasks()

        XCTAssertEqual(rig.store.state, .idle)
        XCTAssertEqual(try XCTUnwrap(rig.socket).closeCount, 1)
        XCTAssertGreaterThan(rig.input.stopCount, 0)
        XCTAssertEqual(rig.audioSession.activeCalls.last, false, "let other apps' audio resume")
        // Freezing the partial reply is honest about how far it got.
        XCTAssertEqual(rig.store.assistantText, "Clear skies.")
    }

    func testTheSecondPrimaryActionStopsARunningSession() async throws {
        let rig = makeRig()
        await startListening(rig)
        await rig.store.primaryAction()
        await settleVoiceTasks()
        XCTAssertEqual(rig.store.state, .idle)
    }

    func testACleanSocketCloseWhileActiveReturnsToIdle() async throws {
        let rig = makeRig()
        await startListening(rig)
        try XCTUnwrap(rig.socket).serverClosed(nil)
        await settleVoiceTasks()
        XCTAssertEqual(rig.store.state, .idle)
        XCTAssertNil(rig.store.error)
    }

    /// silent-failures H1: a DROPPED socket used to look exactly like the user
    /// pressing Stop, so a broken tunnel silently ended the conversation.
    func testASocketDropWithAnErrorSurfacesTheFailure() async throws {
        let rig = makeRig()
        await startListening(rig)
        try XCTUnwrap(rig.socket).serverClosed(APIError.badResponse("dropped"))
        await settleVoiceTasks()

        XCTAssertEqual(rig.store.state, .error)
        XCTAssertEqual(rig.store.error, "Unexpected server reply: dropped")
        XCTAssertGreaterThan(rig.input.stopCount, 0, "a failed turn still tears down")
    }

    // MARK: - Failed turns

    func testAFailedTurnReasonShowsAMessageAndResetsTheCachedSession() async throws {
        let rig = makeRig()
        await startListening(rig)
        await speakThenPause(rig)

        try XCTUnwrap(rig.socket).receive(json: ["type": "end_turn", "reason": "no_reply"])
        await settleVoiceTasks()

        XCTAssertEqual(rig.store.error, "I didn't catch a reply — please try again.")
        XCTAssertNil(rig.store.sessionID, "re-resolve the voice session on the next connect")
        XCTAssertEqual(rig.store.state, .thinking, "we stay in the conversation")

        rig.clock.advance(ms: VoiceStore.resumeGraceMs + 10)
        await settleVoiceTasks()
        XCTAssertEqual(rig.store.state, .listening)
    }

    func testASuccessfulTurnEndKeepsTheCachedSessionAndResumes() async throws {
        let rig = makeRig()
        await startListening(rig)
        await speakThenPause(rig)
        try await replyWithAudio(rig)

        try XCTUnwrap(rig.socket).receive(json: ["type": "end_turn", "reason": ""])
        await settleVoiceTasks()
        XCTAssertNil(rig.store.error)
        XCTAssertEqual(rig.store.sessionID, "voice-1")
    }

    // MARK: - Watchdogs

    func testTheThinkingWatchdogReassuresOnASlowTurn() async {
        let rig = makeRig()
        await startListening(rig)
        await speakThenPause(rig)
        XCTAssertNil(rig.store.toolStatus)

        rig.clock.advance(ms: VoiceStore.thinkingWatchdogMs + 10)
        await settleVoiceTasks()
        XCTAssertEqual(rig.store.toolStatus, "Still working…")
    }

    func testTheWatchdogDoesNotStompARealToolStatus() async throws {
        let rig = makeRig()
        await startListening(rig)
        await speakThenPause(rig)
        try XCTUnwrap(rig.socket).receive(json: ["type": "tool", "name": "search_web",
                                                  "status": "started"])
        await settleVoiceTasks()
        rig.clock.advance(ms: VoiceStore.thinkingWatchdogMs * 2)
        await settleVoiceTasks()
        XCTAssertEqual(rig.store.toolStatus, "Running search_web")
    }

    func testAForgottenBackgroundedSessionIsReapedWhenIdle() async {
        let rig = makeRig()
        await startListening(rig)
        rig.store.pauseForBackground()

        rig.clock.advance(ms: VoiceStore.bgIdleTimeoutMs + 10)
        await settleVoiceTasks()
        XCTAssertEqual(rig.store.state, .idle, "mic + socket + session must not stream forever")
    }

    func testABackgroundedSessionMidUtteranceIsNotReaped() async {
        let rig = makeRig()
        await startListening(rig)
        rig.input.emitFrames(amplitude: 0.5, ms: 400) // mid-utterance
        await settleVoiceTasks()
        rig.store.pauseForBackground()

        rig.clock.advance(ms: VoiceStore.bgIdleTimeoutMs + 10)
        await settleVoiceTasks()
        XCTAssertEqual(rig.store.state, .listening)
    }

    func testReturningToTheForegroundReAssertsTheAudioSession() async {
        let rig = makeRig()
        await startListening(rig)
        let before = rig.audioSession.activeCalls.count
        rig.store.pauseForBackground()
        await rig.store.resumeFromBackground()
        XCTAssertEqual(rig.audioSession.activeCalls.count, before + 1)
        XCTAssertEqual(rig.audioSession.activeCalls.last, true)
    }

    // MARK: - Audio-session interruptions

    func testAnEndedInterruptionReGrabsTheSession() async {
        let rig = makeRig()
        await startListening(rig)
        let before = rig.audioSession.activeCalls.count

        rig.audioSession.simulate(.began) // iOS paused us; nothing to do yet
        XCTAssertEqual(rig.audioSession.activeCalls.count, before)

        rig.audioSession.simulate(.ended)
        XCTAssertEqual(rig.audioSession.activeCalls.count, before + 1)
        XCTAssertEqual(rig.audioSession.activeCalls.last, true)
    }

    func testAnInterruptionWhileIdleIsIgnored() {
        let rig = makeRig()
        rig.audioSession.simulate(.ended)
        XCTAssertTrue(rig.audioSession.activeCalls.isEmpty, "don't grab audio we aren't using")
    }

    // MARK: - Push-to-talk (quality) mode

    func testQualityModeRecordsThenPostsTheClip() async throws {
        let rig = makeRig(mode: .quality)
        rig.transport.enqueue(text: """
        {"type":"transcript","text":"hello there"}
        {"type":"segment","kind":"text","text":"Hi.","audio_base64":"\(Data([9, 9]).base64EncodedString())"}
        {"type":"done"}
        """, contentType: "application/x-ndjson")

        await rig.store.primaryAction()
        await settleVoiceTasks()
        XCTAssertEqual(rig.store.state, .listening)
        XCTAssertTrue(rig.connector.connectedURLs.isEmpty, "push-to-talk needs no socket")

        rig.input.emitFrames(amplitude: 0.5, ms: 300)
        await rig.store.primaryAction() // second tap = send
        await settleVoiceTasks()
        await rig.store.audio.settle()

        let posted = rig.transport.requests.first { $0.url?.path == "/api/voice/quality-turn" }
        XCTAssertNotNil(posted)
        XCTAssertEqual(rig.store.userTranscript, "hello there")
        XCTAssertEqual(rig.store.assistantText, "Hi.")
        XCTAssertEqual(rig.output.played.first?.bytes, Data([9, 9]))
        XCTAssertGreaterThan(rig.input.stopCount, 0, "the mic is released before the POST")
    }

    func testQualityModeGoesIdleWhenTheClipFinishes() async throws {
        let rig = makeRig(mode: .quality)
        rig.transport.enqueue(text: """
        {"type":"segment","kind":"text","text":"Hi.","audio_base64":"\(Data([1]).base64EncodedString())"}
        """, contentType: "application/x-ndjson")

        await rig.store.primaryAction()
        await settleVoiceTasks()
        rig.input.emitFrames(amplitude: 0.5, ms: 300)
        await rig.store.primaryAction()
        await settleVoiceTasks()
        await rig.store.audio.settle()
        XCTAssertEqual(rig.store.state, .speaking)

        rig.output.finishClip()
        await settleVoiceTasks()
        await rig.store.audio.settle()
        XCTAssertEqual(rig.store.state, .idle, "one shot, not a conversation")
    }

    func testQualityModeRejectsAClipTooShortToBeSpeech() async {
        let rig = makeRig(mode: .quality)
        await rig.store.primaryAction()
        await settleVoiceTasks()
        rig.input.emit(amplitude: 0.5, ms: 5) // ~160 bytes
        await rig.store.primaryAction()
        await settleVoiceTasks()

        XCTAssertEqual(rig.store.state, .error)
        XCTAssertEqual(rig.store.error, "Didn't catch that — try again.")
    }

    func testSwitchingModeStopsTheRunningSessionAndPersists() async throws {
        let rig = makeRig()
        await startListening(rig)
        await rig.store.setMode(.quality)
        await settleVoiceTasks()

        XCTAssertEqual(rig.store.mode, .quality)
        XCTAssertEqual(rig.store.state, .idle)
        XCTAssertEqual(try XCTUnwrap(rig.socket).closeCount, 1)
        XCTAssertEqual(rig.prefs.string(VoiceSettings.modeKey), "quality")
    }

    // MARK: - Engines

    func testLoadEnginesPopulatesThePicker() async {
        let rig = makeRig()
        rig.transport.route("/api/voice/engines", json: [
            "active": "edge",
            "engines": [["id": "edge", "name": "Edge TTS", "configured": true,
                         "voices": ["en-GB-RyanNeural"]]],
        ])
        await rig.store.loadEngines()
        XCTAssertEqual(rig.store.engines.engines.map(\.id), ["edge"])
        XCTAssertEqual(rig.store.engines.active, "edge")
    }

    func testEngineSelectionIsPersistedAndReloadedByAFreshStore() {
        let prefs = MemoryKeyValueStore()
        let first = makeRig(prefs: prefs)
        first.store.selectEngine("elevenlabs", voice: "Rachel")

        XCTAssertEqual(first.store.selectedEngine, "elevenlabs")
        XCTAssertEqual(first.store.selectedVoice, "Rachel")
        XCTAssertEqual(prefs.string(VoiceSettings.engineKey), "elevenlabs")

        let relaunched = makeRig(prefs: prefs)
        XCTAssertEqual(relaunched.store.selectedEngine, "elevenlabs")
        XCTAssertEqual(relaunched.store.selectedVoice, "Rachel")
    }

    func testTheSelectedEngineAndVoiceAreUsedWhenSpeakingAReplyLocally() async throws {
        let rig = makeRig()
        rig.store.selectEngine("edge", voice: "en-GB-RyanNeural")
        rig.transport.route("/api/voice/synthesize", json: ["ignored": true])
        await startListening(rig)
        await speakThenPause(rig)

        // An escalation result is spoken through server TTS, not the socket.
        try XCTUnwrap(rig.socket).receive(json: ["type": "escalation_result",
                                                  "text": "It's 18 degrees."])
        await settleVoiceTasks()

        let posted = rig.transport.requests.first { $0.url?.path == "/api/voice/synthesize" }
        let body = (try? JSONSerialization.jsonObject(with: posted?.httpBody ?? Data()))
            as? [String: Any] ?? [:]
        XCTAssertEqual(body["engine"] as? String, "edge")
        XCTAssertEqual(body["voice"] as? String, "en-GB-RyanNeural")
        XCTAssertEqual(rig.store.assistantText, "It's 18 degrees.")
    }

    // MARK: - The Siri / Control-Center latch

    func testTheLaunchLatchStartsExactlyOneTurn() async {
        let bridge = VoiceLaunchBridge(store: MemoryKeyValueStore())
        let rig = makeRig(launch: bridge)

        let nothingPending = await rig.store.consumeVoiceLaunch()
        XCTAssertFalse(nothingPending, "nothing requested yet")
        XCTAssertEqual(rig.store.state, .idle)

        bridge.request()
        let honoured = await rig.store.consumeVoiceLaunch()
        XCTAssertTrue(honoured)
        await settleVoiceTasks()
        XCTAssertEqual(rig.store.state, .listening)
        XCTAssertEqual(rig.connector.connectedURLs.count, 1)

        // A re-render must not start a second turn.
        let alreadyTaken = await rig.store.consumeVoiceLaunch()
        XCTAssertFalse(alreadyTaken)
        await settleVoiceTasks()
        XCTAssertEqual(rig.connector.connectedURLs.count, 1)
    }

    func testAColdLaunchFlagIsReplayedOnce() {
        let prefs = MemoryKeyValueStore([VoiceSettings.pendingVoiceKey: true])
        let bridge = VoiceLaunchBridge(store: prefs)
        var requests = 0
        bridge.onRequest = { requests += 1 }
        bridge.start()

        XCTAssertEqual(requests, 1)
        XCTAssertTrue(bridge.voiceLaunchRequested)
        XCTAssertEqual(bridge.voiceLaunchGeneration, 1)
        XCTAssertNil(prefs.bool(VoiceSettings.pendingVoiceKey),
                     "cleared, so a relaunch doesn't start a turn nobody asked for")
        XCTAssertTrue(bridge.consumeVoiceLaunch())
        XCTAssertFalse(bridge.consumeVoiceLaunch())
    }

    func testAWarmLaunchNotificationIsObserved() {
        let center = NotificationCenter()
        let bridge = VoiceLaunchBridge(store: MemoryKeyValueStore(), center: center)
        var requests = 0
        bridge.onRequest = { requests += 1 }
        bridge.start()

        center.post(name: VoiceLaunchBridge.notificationName, object: nil)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(bridge.voiceLaunchGeneration, 1)
    }

    // MARK: - The Live Activity's device strip

    /// `/api/devices` was read with the shape-guessing `.array()`, which scans a
    /// fixed key list (`items`, `sessions`, …, `devices`, `list`) and returns
    /// whichever it meets FIRST. A reply that carries a second array — the server
    /// only has to grow one field — silently handed the island somebody else's
    /// list (or an empty one) instead of the devices.
    func testDeviceKindsComeFromTheDevicesKeyEvenWhenTheReplyCarriesAnotherArray() async {
        let rig = makeRig(devices: [
            "errors": [],
            // `sessions` sorts BEFORE `devices` in the guesser's key list.
            "sessions": [["id": "s1"]],
            "devices": [["kind": "desktop", "name": "Studio", "online": true],
                        ["kind": "mobile-ios", "name": "iPhone", "online": true],
                        ["kind": "desktop", "name": "Asleep", "online": false]],
        ])

        await startListening(rig)
        XCTAssertTrue(rig.store.state.isActive, "the strip only refreshes during a turn")
        await settleVoiceTasks()

        XCTAssertEqual(rig.store.deviceKinds, ["desktop", "phone"],
                       "the devices array, with the offline device dropped")
    }

    /// The plain top-level array shape the server also answers with still works.
    func testDeviceKindsAcceptABareArrayReply() async {
        let rig = makeRig(devices: [["kind": "watch", "name": "Apple Watch", "online": true]])
        await startListening(rig)
        await settleVoiceTasks()
        XCTAssertEqual(rig.store.deviceKinds, ["watch"])
    }

    // MARK: - Review fixes: things that used to hang or fail silently

    /// swift-correctness C1: SFSpeech's final callback is not guaranteed. Without
    /// a deadline the turn sat in `thinking` forever and the continuation leaked.
    func testAStalledRecognizerCannotWedgeTheTurn() async throws {
        let rig = makeRig(transcription: .onDevice)
        rig.recognizer.nextTranscript = "never delivered"
        await startListening(rig)
        let speech = try XCTUnwrap(rig.recognizer.latest)
        speech.stallStop = true

        await speakThenPause(rig)
        let socket = try XCTUnwrap(rig.socket)
        XCTAssertFalse(socket.sentTypes.contains("end_turn"), "still waiting on the recognizer")

        rig.clock.advance(ms: VoiceStore.sttFinalTimeoutMs + 10)
        await settleVoiceTasks()

        XCTAssertFalse(socket.sentTypes.contains("end_turn"),
                       "a stalled on-device recognizer is a miss, never a server turn")
        XCTAssertEqual(rig.store.toolStatus, "Didn't catch that",
                       "the deadline ends the wait instead of hanging")
        XCTAssertGreaterThan(speech.cancelCount, 0, "the stalled session is released")
    }

    /// swift-correctness C3: `DefaultAudioInput.start` retries for ~1.75 s, so a
    /// start issued before a teardown could finish after it — a live mic at idle.
    func testAMicThatFinishesStartingAfterTeardownIsStoppedAgain() async throws {
        let rig = makeRig()
        rig.input.stallStart = true
        await rig.store.primaryAction()
        await waitUntilVoice { rig.store.state == .listening }

        await rig.store.stopAll()
        await settleVoiceTasks()
        XCTAssertEqual(rig.store.state, .idle)

        rig.input.releaseStart() // the engine finally comes up, after the teardown
        await settleVoiceTasks()

        XCTAssertFalse(rig.input.isRunning, "the mic must never be live at idle")
    }

    /// swift-correctness H16: the resume / watchdog / background timers all
    /// belong to a turn; a teardown that leaves them armed keeps firing at idle.
    func testTeardownDisarmsEveryTimer() async throws {
        let rig = makeRig()
        await startListening(rig)
        await speakThenPause(rig)      // arms the thinking watchdog
        rig.store.pauseForBackground() // arms the background-idle reaper
        XCTAssertGreaterThan(rig.clock.pendingTimers, 0, "a live turn has timers armed")

        await rig.store.stopAll()
        await settleVoiceTasks()
        XCTAssertEqual(rig.clock.pendingTimers, 0)
    }

    /// swift-correctness H16: nothing the store owns may pin it.
    func testTheStoreDeallocates() async {
        weak var leaked: VoiceStore?
        // A synchronous scope, so the rig is definitely gone by the assertion.
        func build() { leaked = makeRig().store }
        build()
        await settleVoiceTasks(2)
        XCTAssertNil(leaked, "the store must not be pinned by its own callbacks")
    }

    /// silent-failures H2 + swift-correctness M20: a send into a socket that is
    /// already gone used to vanish, leaving the turn waiting for a reply forever.
    func testEndTurnOnAClosedSocketFailsTheTurnInsteadOfHanging() async throws {
        let rig = makeRig()
        await startListening(rig)
        // Drop the socket the way `close()` does — no onClose, so nothing else
        // can rescue the turn.
        rig.store.session.close()

        rig.store.finishSpeaking()
        await settleVoiceTasks()

        XCTAssertEqual(rig.store.state, .error)
        XCTAssertNotNil(rig.store.error)
    }

    /// silent-failures L8: losing the audio session on the way back from a phone
    /// call means playback never resumes — the user has to be told.
    func testAnAudioSessionThatWontComeBackIsReported() async {
        let rig = makeRig()
        await startListening(rig)
        rig.audioSession.activateError = APIError.badResponse("session busy")

        rig.audioSession.simulate(.ended)
        await settleVoiceTasks()
        XCTAssertNotNil(rig.store.error)

        XCTAssertEqual(rig.store.state, .error)

        let foregroundRig = makeRig()
        await startListening(foregroundRig)
        foregroundRig.audioSession.activateError = APIError.badResponse("session busy")
        foregroundRig.store.pauseForBackground()
        await foregroundRig.store.resumeFromBackground()
        XCTAssertNotNil(foregroundRig.store.error, "foreground recovery also surfaces the failure")
        XCTAssertEqual(foregroundRig.store.state, .error)
    }

    /// silent-failures M15: TTS that returns nothing left the reply on screen
    /// with no explanation of why it was never spoken.
    func testAReplyWithNoTtsAudioSaysWhyItStayedQuiet() async throws {
        let rig = makeRig()
        rig.transport.route("/api/voice/synthesize", json: [:], status: 502)
        await startListening(rig)
        await speakThenPause(rig)

        try XCTUnwrap(rig.socket).receive(json: ["type": "escalation_result",
                                                 "text": "It's 18 degrees."])
        await settleVoiceTasks()

        XCTAssertEqual(rig.store.assistantText, "It's 18 degrees.")
        XCTAssertEqual(rig.store.error, VoiceStore.ttsUnavailableNotice)
    }

    // MARK: - Push-to-talk: tool, error and failure frames (test-gaps 4)

    func testQualityToolSegmentsDriveTheStatusLine() async throws {
        let rig = makeRig(mode: .quality)
        rig.transport.enqueue(text: """
        {"type":"segment","kind":"tool","name":"search_web","status":"started"}
        {"type":"segment","kind":"tool","name":"search_web","status":"completed"}
        {"type":"segment","kind":"text","text":"Sunny."}
        {"type":"done"}
        """, contentType: "application/x-ndjson")

        await rig.store.primaryAction()
        await settleVoiceTasks()
        rig.input.emitFrames(amplitude: 0.5, ms: 300)
        await rig.store.primaryAction()
        await settleVoiceTasks()

        XCTAssertNil(rig.store.toolStatus, "completed clears the status")
        XCTAssertEqual(rig.store.assistantText, "Sunny.")
        XCTAssertEqual(rig.store.state, .idle)
    }

    func testQualityToolStartShowsTheRunningLine() async throws {
        let rig = makeRig(mode: .quality)
        rig.transport.enqueue(text: """
        {"type":"segment","kind":"tool","name":"search_web","status":"started"}
        """, contentType: "application/x-ndjson")

        await rig.store.primaryAction()
        await settleVoiceTasks()
        rig.input.emitFrames(amplitude: 0.5, ms: 300)
        await rig.store.primaryAction()
        await settleVoiceTasks()

        XCTAssertEqual(rig.store.toolStatus, "Running search_web")
    }

    func testAQualityErrorFrameEndsTheTurnInError() async throws {
        let rig = makeRig(mode: .quality)
        rig.transport.enqueue(text: """
        {"type":"error","error":"the model is unavailable"}
        """, contentType: "application/x-ndjson")

        await rig.store.primaryAction()
        await settleVoiceTasks()
        rig.input.emitFrames(amplitude: 0.5, ms: 300)
        await rig.store.primaryAction()
        await settleVoiceTasks()

        XCTAssertEqual(rig.store.state, .error)
        XCTAssertEqual(rig.store.error, "the model is unavailable")
    }

    func testAQualityTurnThatCannotResolveASessionLandsInError() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/voice/session", json: ["session_id": ""])
        transport.route("/api/session/new", json: ["session": [:]])
        let input = MockAudioInput()
        let prefs = MemoryKeyValueStore()
        prefs.set(VoiceMode.quality.rawValue, forKey: VoiceSettings.modeKey)
        let store = VoiceStore(api: api, input: input, output: MockAudioOutput(),
                               recognizer: MockSpeechRecognizing(),
                               synthesizer: MockVoiceSynthesizing(),
                               audioSession: MockAudioSessionControlling(),
                               connector: MockVoiceSocketConnector(),
                               clock: TestVoiceClock(), keyValueStore: prefs)

        await store.primaryAction()
        await settleVoiceTasks()
        input.emitFrames(amplitude: 0.5, ms: 300)
        await store.primaryAction()
        await settleVoiceTasks()

        XCTAssertEqual(store.state, .error, "not a turn stuck in thinking")
        XCTAssertNotNil(store.error)
    }

    func testAQualityStreamThatFailsLandsInErrorNotThinking() async throws {
        let rig = makeRig(mode: .quality)
        rig.transport.enqueue(error: APIError.http(status: 500, message: "boom"))

        await rig.store.primaryAction()
        await settleVoiceTasks()
        rig.input.emitFrames(amplitude: 0.5, ms: 300)
        await rig.store.primaryAction()
        await settleVoiceTasks()

        XCTAssertEqual(rig.store.state, .error, "a broken stream must not wedge the turn")
        XCTAssertEqual(rig.store.error, "boom")
    }

    /// swift-correctness M37: a segment carrying audio but NO text used to be
    /// tagged with the PREVIOUS segment, so the stray clip's playhead drove that
    /// segment's word highlight a second time.
    func testAnAudioOnlyQualitySegmentDoesNotStealThePreviousSegmentsTag() async throws {
        let rig = makeRig(mode: .quality)
        rig.transport.enqueue(text: """
        {"type":"segment","kind":"text","text":"One two three four.","audio_base64":"\(Data([1, 1]).base64EncodedString())"}
        {"type":"segment","kind":"text","audio_base64":"\(Data([2, 2]).base64EncodedString())"}
        """, contentType: "application/x-ndjson")

        await rig.store.primaryAction()
        await settleVoiceTasks()
        rig.input.emitFrames(amplitude: 0.5, ms: 300)
        await rig.store.primaryAction()
        await settleVoiceTasks()
        await rig.store.audio.settle()

        XCTAssertEqual(rig.store.replySegments.count, 1, "the audio-only frame adds no segment")
        XCTAssertEqual(rig.output.played.map(\.bytes), [Data([1, 1])])
        XCTAssertEqual(rig.store.spokenWords, 0)

        rig.output.finishClip() // the first clip ends, the stray clip starts
        await settleVoiceTasks()
        await rig.store.audio.settle()
        XCTAssertEqual(rig.output.played.map(\.bytes), [Data([1, 1]), Data([2, 2])])

        // A playhead report from the stray clip. Tagged with segment 0 it walks
        // that segment's word schedule a second time; untagged it is ignored.
        rig.output.report(position: 1.1)
        XCTAssertEqual(rig.store.spokenWords, 0,
                       "a clip with no segment of its own must not advance the highlight")
    }
}

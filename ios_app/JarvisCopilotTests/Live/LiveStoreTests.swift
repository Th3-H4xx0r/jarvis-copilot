import XCTest
@testable import JarvisCopilot

/// `LiveStore` driven from the server side: the handshake it answers with, the
/// resume cursor, and the loud stop.
///
/// The microphone is a `MockAudioInput`, the socket a `MockVoiceSocket`, and the
/// audio session a mock applier behind a real `AudioSessionArbiter` — so no test
/// here touches CoreAudio.
@MainActor
final class LiveStoreTests: XCTestCase {

    private struct Rig {
        let store: LiveStore
        let transport: MockTransport
        let input: MockAudioInput
        let recognizer: MockSpeechRecognizing
        let connector: MockVoiceSocketConnector
        let clock: TestVoiceClock
        let spool: LiveSpool
        let settings: LiveSettings
        let applier: MockAudioSessionApplying
        let arbiter: AudioSessionArbiter
        let directory: URL
    }

    private var directories: [URL] = []

    override func tearDown() {
        directories.forEach { try? FileManager.default.removeItem(at: $0) }
        directories = []
        super.tearDown()
    }

    /// `transcript` is a parameter rather than something a test routes for
    /// itself: `MockTransport` matches the FIRST route registered for a path,
    /// so a route added afterwards for `/api/live/transcript` is silently
    /// ignored and the test reads an empty transcript it did not ask for.
    private func makeRig(spoolLimit: Int = 1024 * 1024,
                         readiness: SpeechReadiness = .ready,
                         transcript: [String: Any] = ["segments": []],
                         keyValues: [String: Any] = [:],
                         voiceprints: VoiceprintEmbedding? = nil,
                         onDevice: OnDeviceTranscribing? = nil,
                         speakers: LiveSpeakerTracking? = nil) -> Rig {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("live-store-\(UUID().uuidString)", isDirectory: true)
        directories.append(directory)

        let (api, transport) = JarvisAPI.mocked()
        let input = MockAudioInput()
        let recognizer = MockSpeechRecognizing()
        recognizer.readiness = readiness
        let connector = MockVoiceSocketConnector()
        let clock = TestVoiceClock()
        let spool = LiveSpool(directory: directory, limitBytes: spoolLimit)
        let settings = LiveSettings(store: MemoryKeyValueStore())
        let applier = MockAudioSessionApplying()
        let arbiter = AudioSessionArbiter(session: applier)
        let session = AmbientAudioSession(arbiter: arbiter)

        // `/api/live/session/start` is best-effort in the store, but routing it here
        // keeps the tests off the FIFO queue so they do not consume each other's
        // replies.
        transport.route("/api/live/session/start",
                        json: ["live_session_id": "L1", "chat_session_id": "C1"])
        transport.route("/api/live/session/end", json: [:])
        transport.route("/api/live/config", json: [:])
        transport.route("/api/live/speakers", json: ["speakers": []])
        transport.route("/api/live/storage", json: ["total_bytes": 0])
        transport.route("/api/live/transcript", json: transcript)

        let store = LiveStore(api: LiveAPI(api: api),
                              input: input,
                              session: session,
                              recognizer: recognizer,
                              connector: connector,
                              clock: clock,
                              spool: spool,
                              settings: settings,
                              preferences: MemoryKeyValueStore(keyValues),
                              voiceprints: voiceprints.map { made -> (@Sendable () -> VoiceprintEmbedding?) in { made } },
                              onDevice: onDevice.map { made -> (@MainActor () async -> OnDeviceTranscribing?) in { made } },
                              speakers: speakers.map { made -> (@MainActor () -> LiveSpeakerTracking?) in { made } })
        return Rig(store: store, transport: transport, input: input, recognizer: recognizer,
                   connector: connector, clock: clock, spool: spool, settings: settings,
                   applier: applier, arbiter: arbiter, directory: directory)
    }

    /// Frames the client has put on the socket, decoded.
    private func sent(_ rig: Rig) -> [[String: Any]] {
        (rig.connector.socket?.sentText ?? []).compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
    }

    private func lastFrame(_ rig: Rig, t: String) -> [String: Any]? {
        sent(rig).last { ($0["t"] as? String) == t }
    }

    private func readyFrame(sessionID: String = "L1", seq: Int = 0,
                            lane: String = "edge") -> String {
        let json: [String: Any] = ["t": "ready", "live_session_id": sessionID,
                                   "chat_session_id": "C1", "seq": seq, "lane": lane]
        return String(data: try! JSONSerialization.data(withJSONObject: json), encoding: .utf8)!
    }

    // MARK: - Handshake

    func testStartingSendsHelloDeclaringOnDeviceSTTWhenTheModelIsReady() async {
        let rig = makeRig(readiness: .ready)
        await rig.store.start()

        let hello = lastFrame(rig, t: "hello")
        XCTAssertNotNil(hello, "the client must introduce itself before anything else")
        let caps = hello?["caps"] as? [String: Any]
        XCTAssertEqual(caps?["stt"] as? String, "on_device")
        XCTAssertTrue(rig.store.capturing)
        XCTAssertEqual(rig.input.startedRates, [16000])
    }

    /// Design §8: the model not being downloaded falls back to the server lane and
    /// SAYS so. Claiming the edge lane and then sending no `seg` would read to the
    /// server as a silent room.
    func testAnUndownloadedSpeechModelDeclaresNoSttAndStatesItInTheStatusLine() async {
        let rig = makeRig(readiness: .downloadFailed)
        await rig.store.start()

        let caps = lastFrame(rig, t: "hello")?["caps"] as? [String: Any]
        XCTAssertEqual(caps?["stt"] as? String, "none")
        XCTAssertFalse(rig.store.sttNotice.isEmpty, "the fallback has to be visible, not silent")
        XCTAssertTrue(rig.store.sttNotice.lowercased().contains("server"), rig.store.sttNotice)
    }

    /// A device that asked for the edge lane and was given the server lane must not
    /// keep claiming on-device transcription on screen.
    func testBeingRefusedTheEdgeLaneIsReportedToo() async {
        let rig = makeRig(readiness: .ready)
        await rig.store.start()
        rig.store.receive(text: readyFrame(lane: "server"))

        XCTAssertEqual(rig.store.lane, .server)
        XCTAssertFalse(rig.store.sttNotice.isEmpty)
    }

    // MARK: - A server speech engine's lane

    private func engineReady(lane: String = "server", engine: String? = "Soniox") -> String {
        var frame: [String: Any] = ["t": "ready", "live_session_id": "L1", "chat_session_id": "C1",
                                    "seq": 0, "lane": lane, "relane": true]
        if let engine { frame["engine"] = engine }
        return json(frame)
    }

    /// The phone stops its own transcription but keeps saying it CAN: otherwise
    /// every later hello declares "none" and the edge lane never comes back.
    func testAServerEngineLaneSaysWhoIsListeningAndKeepsTheCapability() async {
        let rig = makeRig(readiness: .ready)
        await rig.store.start()
        rig.store.receive(text: engineReady())

        XCTAssertEqual(rig.store.lane, .server)
        XCTAssertTrue(rig.store.sttNotice.contains("Soniox"), rig.store.sttNotice)
        XCTAssertFalse(rig.store.transcribingOnDevice)
        XCTAssertEqual(rig.store.declaredSTT, "on_device")
    }

    /// The engine failed (or Live went back to the phone): the server hands the
    /// edge lane back and Apple's transcriber takes over again.
    func testAnEdgeReadyAfterAnEngineLaneHandsTranscriptionBack() async {
        let rig = makeRig(readiness: .ready)
        await rig.store.start()
        rig.store.receive(text: engineReady())
        rig.store.receive(text: engineReady(lane: "edge", engine: nil))

        XCTAssertEqual(rig.store.lane, .edge)
        XCTAssertTrue(rig.store.transcribingOnDevice)
        XCTAssertTrue(rig.store.sttNotice.isEmpty, rig.store.sttNotice)
    }

    /// A plain server lane (no engine) keeps its old meaning: the edge was refused.
    func testAServerLaneWithoutAnEngineStillGivesTheEdgeUp() async {
        let rig = makeRig(readiness: .ready)
        await rig.store.start()
        rig.store.receive(text: readyFrame(lane: "server"))

        XCTAssertEqual(rig.store.declaredSTT, "none")
    }

    func testTheEnginesWordsInProgressShowForThisDeviceOnly() async {
        let rig = makeRig(readiness: .ready)
        await rig.store.start()
        rig.store.receive(text: engineReady())
        let me = lastFrame(rig, t: "hello")?["device_id"] as? String ?? ""

        rig.store.receive(text: json(["t": "partial", "device_id": me, "text": "hola que", "start_ms": 1200]))
        XCTAssertEqual(rig.store.partialText, "hola que")
        rig.store.receive(text: json(["t": "partial", "device_id": "someone-else", "text": "other words"]))
        XCTAssertEqual(rig.store.partialText, "hola que")
        rig.store.receive(text: json(["t": "seg", "seq": 1, "text": "hola que tal", "ts_start_ms": 1200,
                                      "ts_end_ms": 2400, "device_id": me]))
        XCTAssertEqual(rig.store.partialText, "", "the finished line replaces the words in progress")
    }

    func testAnEngineWarningIsShownInWords() async {
        let rig = makeRig(readiness: .ready)
        await rig.store.start()
        rig.store.receive(text: json(["t": "state", "warning": "speech_engine",
                                      "message": "Soniox stopped transcribing (no key)."]))
        XCTAssertEqual(rig.store.warningText, "Soniox stopped transcribing (no key).")
    }

    func testReadyAdoptsTheSessionIdsAndTheCursor() async {
        let rig = makeRig()
        await rig.store.start()
        rig.store.receive(text: readyFrame(sessionID: "L9", seq: 4417))

        XCTAssertEqual(rig.store.liveSessionID, "L9")
        XCTAssertEqual(rig.store.chatSessionID, "C1")
        XCTAssertEqual(rig.settings.lastSessionID, "L9")
        XCTAssertEqual(rig.settings.lastSeq, 4417)
        XCTAssertEqual(rig.spool.sessionID, "L9", "the spool must be bound to the session it holds")
    }

    /// The capture source goes up so the transcript can say where the audio came
    /// from.
    func testTheCaptureSourceLabelIsSentOnceTheSessionIsReady() async {
        let rig = makeRig()
        await rig.store.start()
        rig.store.receive(text: readyFrame())
        XCTAssertNotNil(lastFrame(rig, t: "source"))
    }

    // MARK: - Resume

    /// §8 treats a drop as the normal path, so a reconnect must claim the cursor it
    /// had rather than starting the conversation again.
    func testReconnectingResumesFromTheRememberedCursor() async {
        let rig = makeRig()
        await rig.store.start()
        rig.store.receive(text: readyFrame(sessionID: "L1", seq: 120))

        rig.connector.socket?.serverClosed(NSError(domain: "test", code: 1))
        XCTAssertFalse(rig.store.connected)

        // The backoff's first step is deliberately short.
        rig.clock.advance(ms: 500)
        await Task.yield()

        let resume = lastFrame(rig, t: "hello")?["resume"] as? [String: Any]
        XCTAssertEqual(resume?["live_session_id"] as? String, "L1")
        XCTAssertEqual(resume?["after_seq"] as? Int, 120)
    }

    /// A fresh recording claims the session REST just minted, at seq 0 — that is how
    /// the socket binds to the session `source_label` was sent on.
    func testAFreshRecordingBindsTheSocketToTheSessionRestCreated() async {
        let rig = makeRig()
        await rig.store.start()

        let resume = lastFrame(rig, t: "hello")?["resume"] as? [String: Any]
        XCTAssertEqual(resume?["live_session_id"] as? String, "L1")
        XCTAssertEqual(resume?["after_seq"] as? Int, 0)

        let started = rig.transport.requests.first { $0.url?.path.contains("/api/live/session/start") == true }
        XCTAssertNotNil(started, "source_label belongs on the session-start call")
        let body = try? JSONSerialization.jsonObject(with: started?.httpBody ?? Data()) as? [String: Any]
        XCTAssertNotNil((body ?? [:])["source_label"])
    }

    /// A cursor from a previous LAUNCH still resumes — the drop that outlived the
    /// process is the one that would otherwise lose the most.
    func testACursorFromAPreviousLaunchIsUsedOnTheFirstConnection() async {
        let rig = makeRig()
        rig.settings.rememberCursor(sessionID: "L-old", seq: 77)
        await rig.store.start()

        let resume = lastFrame(rig, t: "hello")?["resume"] as? [String: Any]
        XCTAssertEqual(resume?["live_session_id"] as? String, "L-old")
        XCTAssertEqual(resume?["after_seq"] as? Int, 77)
    }

    // MARK: - Frames in

    func testSegmentsAndInsightsLandInOneTimeline() async {
        let rig = makeRig()
        await rig.store.start()
        rig.store.receive(text: readyFrame())

        rig.store.receive(text: json(["t": "seg", "seq": 1, "text": "first", "speaker_id": "sp-1"]))
        rig.store.receive(text: json(["t": "insight", "seq": 2, "kind": "monitor", "text": "a note"]))
        rig.store.receive(text: json(["t": "seg", "seq": 3, "text": "second", "speaker_id": "sp-2"]))

        XCTAssertEqual(rig.store.rows.map(\.seq), [1, 2, 3])
        XCTAssertEqual(rig.store.segments.count, 2)
        XCTAssertEqual(rig.store.insights.count, 1)
    }

    /// The retroactive merge, end to end through the socket.
    func testAMergeArrivingOnTheSocketRelabelsRowsAlreadyRendered() async {
        let rig = makeRig()
        await rig.store.start()
        rig.store.receive(text: readyFrame())
        rig.store.receive(text: json(["t": "seg", "seq": 1, "text": "a", "speaker_id": "sp-4"]))
        rig.store.receive(text: json(["t": "seg", "seq": 2, "text": "b", "speaker_id": "sp-1",
                                      "speaker_name": "Ada"]))

        rig.store.receive(text: json(["t": "speaker", "op": "merge",
                                      "speaker_id": "sp-1", "from": ["sp-4"]]))

        XCTAssertEqual(rig.store.segments.map(\.speakerID), ["sp-1", "sp-1"])
        XCTAssertEqual(rig.store.segments.map(\.speakerName), ["Ada", "Ada"])
    }

    func testAStateFrameUpdatesTheStoredTotalAndTheWarning() async {
        let rig = makeRig()
        await rig.store.start()
        rig.store.receive(text: json(["t": "state", "storage_bytes": 5 * 1024 * 1024,
                                      "warning": "the queue is full"]))
        XCTAssertEqual(rig.store.storageBytes, 5 * 1024 * 1024)
        XCTAssertEqual(rig.store.serverWarning, "the queue is full")
        XCTAssertTrue(rig.store.storageText.contains("5.0 MB"), rig.store.storageText)
    }

    func testAnErrorFrameIsSurfacedRatherThanSwallowed() async {
        let rig = makeRig()
        await rig.store.start()
        rig.store.receive(text: json(["t": "error", "error": "live.db is locked"]))
        XCTAssertEqual(rig.store.error, "live.db is locked")
    }

    /// An unreadable frame must not take the session down with it.
    func testAnUndecodableFrameIsIgnoredAndCaptureContinues() async {
        let rig = makeRig()
        await rig.store.start()
        rig.store.receive(text: "<html>gateway error</html>")
        XCTAssertTrue(rig.store.capturing)
        XCTAssertEqual(rig.store.error, "")
    }

    // MARK: - The loud stop

    /// §8: running out of spool stops capture with a state that cannot be missed.
    func testExhaustingTheSpoolStopsCaptureLoudly() async {
        // A bound small enough that one audio frame crosses it.
        let rig = makeRig(spoolLimit: 64)
        await rig.store.start()
        // No socket yet from the server's side, and then it drops: everything after
        // this goes to the spool.
        rig.connector.socket?.serverClosed(nil)

        // Speech, loudly enough to open an ambient utterance so audio is streamed.
        rig.input.emitFrames(amplitude: 0.05, ms: 800)
        await Task.yield()

        XCTAssertNotNil(rig.store.halt, "the spool bound must produce a halt, not a silent drop")
        XCTAssertTrue((rig.store.halt?.detail ?? "").lowercased().contains("deleted"),
                      "the halt must reassure that nothing captured was lost: \(rig.store.halt?.detail ?? "")")
        XCTAssertEqual(rig.store.statusText, "Recording stopped")
    }

    func testClearingAHaltLetsTheUserTryAgain() async {
        let rig = makeRig(spoolLimit: 64)
        await rig.store.start()
        rig.connector.socket?.serverClosed(nil)
        rig.input.emitFrames(amplitude: 0.05, ms: 800)
        await Task.yield()
        XCTAssertNotNil(rig.store.halt)

        rig.store.clearHalt()
        XCTAssertNil(rig.store.halt)
        XCTAssertEqual(rig.store.error, "")
    }

    // MARK: - The last utterance

    /// The bug this pins: `stop()` tears down the socket and resets the spool, so a
    /// transcription still in flight used to resolve with nowhere to send its text
    /// and the last thing anybody said vanished.
    func testTheFinalUtteranceIsSentBeforeTheSocketIsTornDown() async {
        let rig = makeRig()
        rig.recognizer.nextTranscript = "one last thing"
        await rig.store.start()
        rig.store.receive(text: readyFrame())

        // Speech, long enough to be an utterance rather than a blip.
        rig.input.emitFrames(amplitude: 0.05, ms: 200)
        await Task.yield()
        await Task.yield()
        rig.input.emitFrames(amplitude: 0.05, ms: 800)
        await Task.yield()

        await rig.store.stop()

        let segments = sent(rig).filter { ($0["t"] as? String) == "seg" }
        XCTAssertEqual(segments.count, 1, "the utterance still open at stop must be sent")
        XCTAssertEqual(segments.first?["text"] as? String, "one last thing")
        XCTAssertEqual(segments.first?["partial"] as? Bool, false)
    }

    // MARK: - The utterance in progress

    /// Speech shows up as it is said, from this phone's own recogniser, without
    /// waiting for the server.
    func testTheWordsBeingSpokenAppearBeforeAnyServerRoundTrip() async {
        let rig = makeRig()
        await rig.store.start()
        rig.store.receive(text: readyFrame())
        await openUtterance(rig)

        rig.recognizer.latest?.onPartial?("we should ship on")

        XCTAssertEqual(rig.store.partialText, "we should ship on")
        XCTAssertTrue(rig.store.rows.isEmpty, "and it is not a transcript row")
        XCTAssertEqual(rig.store.transcript.cursor, 0,
                       "so it cannot move the resume cursor or count toward the rollover budget")
    }

    /// The guess and the record must never both be on screen. When the utterance
    /// ends its words wait in their own slot, and the committed row arriving is
    /// what takes them away.
    func testTheCommittedRowReplacesTheInProgressOne() async {
        let rig = makeRig()
        rig.recognizer.nextTranscript = "we should ship on friday"
        await rig.store.start()
        rig.store.receive(text: readyFrame())
        await openUtterance(rig)
        rig.recognizer.latest?.onPartial?("we should ship on")
        XCTAssertFalse(rig.store.partialText.isEmpty)

        rig.input.emitFrames(amplitude: 0.0, ms: 1500)
        await settle()
        XCTAssertEqual(rig.store.committingText, "we should ship on",
                       "the words stay up while their row is on its way")
        XCTAssertEqual(rig.store.partialText, "")

        rig.store.receive(text: json(["t": "seg", "seq": 1,
                                      "text": "We should ship on Friday."]))

        XCTAssertEqual(rig.store.committingText, "",
                       "the guess goes the moment the record lands")
        XCTAssertEqual(rig.store.segments.map(\.text), ["We should ship on Friday."])
    }

    // MARK: - The recogniser decides when a line is over

    /// Why rows took up to fifteen seconds: in a room whose noise sits above the
    /// level gate, the gate never closes, so only the cap ever ended an
    /// utterance — measured on real sessions, every row landed on a 15 s grid.
    /// The recogniser knows when the words stopped, and that is what ends it.
    func testALineIsCommittedOnceItsWordsStopEvenInANoisyRoom() async {
        let rig = makeRig()
        rig.recognizer.nextTranscript = "hello there"
        await rig.store.start()
        rig.store.receive(text: readyFrame())
        await openUtterance(rig)
        rig.recognizer.latest?.emitPartial("hello there")
        rig.input.emitFrames(amplitude: 0.12, ms: 300)

        // The voice has stopped; the room stays above anything the level gate
        // could close on (its highest close gate is 0.028).
        rig.input.emitFrames(amplitude: 0.03, ms: LiveStore.wordsSettledMs + 200)
        await settle()

        XCTAssertEqual(segs(rig).map { $0["text"] as? String }, ["hello there"])
    }

    /// Apple's English recogniser makes no words for a stretch of Chinese, so
    /// settled words alone cut "你好,我来自中国 | 你好吗" in two while the
    /// speaker was still talking. The line stays open while the voice does.
    func testSettledWordsDoNotEndALineWhileTheVoiceGoesOn() async {
        let rig = makeRig()
        rig.recognizer.nextTranscript = "Ni hao"
        await rig.store.start()
        rig.store.receive(text: readyFrame())
        await openUtterance(rig)
        rig.recognizer.latest?.emitPartial("Ni hao")

        rig.input.emitFrames(amplitude: 0.05, ms: LiveStore.wordsSettledMs + 600)
        await settle()
        XCTAssertTrue(segs(rig).isEmpty, "still talking, however settled the words")

        rig.input.emitFrames(amplitude: 0.01, ms: 600)
        await settle()
        XCTAssertEqual(segs(rig).count, 1, "and it ends when the voice does")
    }

    /// Continuous sound cannot hold a line open to the 15 s cap: after
    /// `wordsSettledAnywayMs` without new words it ends regardless.
    func testALineStillEndsWhenTheSoundNeverStops() async {
        let rig = makeRig()
        rig.recognizer.nextTranscript = "hello"
        await rig.store.start()
        rig.store.receive(text: readyFrame())
        await openUtterance(rig)
        rig.recognizer.latest?.emitPartial("hello")

        rig.input.emitFrames(amplitude: 0.05, ms: LiveStore.wordsSettledAnywayMs + 200)
        await settle()

        XCTAssertEqual(segs(rig).count, 1)
    }

    /// A pause shorter than the settle time is the same line, not two.
    func testWordsStillArrivingKeepTheLineOpen() async {
        let rig = makeRig()
        rig.recognizer.nextTranscript = "one two three"
        await rig.store.start()
        rig.store.receive(text: readyFrame())
        await openUtterance(rig)
        for words in ["one", "one two", "one two three"] {
            rig.recognizer.latest?.emitPartial(words)
            rig.input.emitFrames(amplitude: 0.05, ms: LiveStore.wordsSettledMs - 300)
            await settle()
        }
        XCTAssertTrue(segs(rig).isEmpty)

        rig.input.emitFrames(amplitude: 0.01, ms: 500)
        await settle()
        XCTAssertEqual(segs(rig).count, 1)
    }

    /// Room noise with no words in it is not cut into windows. Cutting it at the
    /// cap is what split a sentence that began just before the boundary into two
    /// rows ("Hello." / "Como te llamas…"), measured on a real recording.
    func testNoiseWithNoWordsIsNotCutIntoWindows() async {
        let rig = makeRig()
        await rig.store.start()
        rig.store.receive(text: readyFrame())
        await openUtterance(rig)

        rig.input.emitFrames(amplitude: 0.05, ms: AmbientSegmenter.maxUtteranceMs + 2000)
        await settle()

        XCTAssertEqual(rig.recognizer.sessions.count, 1, "one window, never cut and reopened")
        XCTAssertEqual(rig.recognizer.latest?.stopCount, 0)
        XCTAssertTrue(segs(rig).isEmpty)
    }

    /// A monologue still reaches the transcript in pieces while it is being
    /// spoken — but the cap counts from the first WORD, so the noise before
    /// anyone spoke does not shorten the first piece.
    func testALongMonologueIsStillChunkedFromItsFirstWord() async {
        let rig = makeRig()
        rig.recognizer.nextTranscript = "a very long story"
        await rig.store.start()
        rig.store.receive(text: readyFrame())
        await openUtterance(rig)
        rig.input.emitFrames(amplitude: 0.05, ms: 5000)
        await settle()

        var said = ""
        for n in 0..<28 {  // 14 s of words, 19 s into the window
            said += " w\(n)"
            rig.recognizer.latest?.emitPartial(said)
            rig.input.emitFrames(amplitude: 0.05, ms: 500)
            await settle()
        }
        XCTAssertTrue(segs(rig).isEmpty, "not yet: the words have run 14 s")

        for n in 28..<34 {
            said += " w\(n)"
            rig.recognizer.sessions.first?.emitPartial(said)
            rig.input.emitFrames(amplitude: 0.05, ms: 500)
            await settle()
        }
        XCTAssertEqual(segs(rig).count, 1, "cut once the words have run for the cap")
    }

    /// Lines now end back to back. The echo of the one just committed must take
    /// only ITS words away, never the next line being spoken.
    func testTheEchoOfOneLineLeavesTheNextLinesWordsOnScreen() async {
        let rig = makeRig()
        rig.recognizer.nextTranscript = "first line"
        await rig.store.start()
        rig.store.receive(text: readyFrame())
        await openUtterance(rig)
        rig.recognizer.latest?.emitPartial("first line")
        wordsStop(rig)
        await settle()
        XCTAssertEqual(rig.store.committingText, "first line")
        XCTAssertEqual(rig.recognizer.sessions.count, 2,
                       "the room is still loud, so the next window is already open")

        rig.recognizer.latest?.emitPartial("and the second")
        rig.store.receive(text: json(["t": "seg", "seq": 1, "text": "First line."]))

        XCTAssertEqual(rig.store.committingText, "")
        XCTAssertEqual(rig.store.partialText, "and the second")
        XCTAssertEqual(rig.store.segments.map(\.text), ["First line."])
    }

    /// Nothing heard means nothing waits: an utterance the recogniser produced no
    /// text for must not leave its guess up for the grace window.
    func testAnUtteranceThatTranscribesToNothingTakesItsWordsDownAtOnce() async {
        let rig = makeRig()
        rig.recognizer.nextTranscript = ""
        await rig.store.start()
        rig.store.receive(text: readyFrame())
        await openUtterance(rig)
        rig.recognizer.latest?.emitPartial("uh")

        rig.input.emitFrames(amplitude: 0.0, ms: 1500)
        await settle()

        XCTAssertEqual(rig.store.committingText, "")
        XCTAssertTrue(segs(rig).isEmpty)
    }

    // MARK: - Voiceprints made on the phone

    /// Stands in for the CoreML embedder: records what it was handed.
    private final class FakeVoiceprints: VoiceprintEmbedding, @unchecked Sendable {
        private let lock = NSLock()
        private var _bytes: [Int] = []
        var bytes: [Int] { lock.withLock { _bytes } }
        func embed(pcm16: Data) -> [Float]? {
            lock.withLock { _bytes.append(pcm16.count) }
            return [Float](repeating: 1.0 / 16, count: LiveVoiceprint.dimension)
        }
    }

    /// The embedding runs off the main actor, so wait for the frame rather
    /// than counting yields.
    private func waitForSeg(_ rig: Rig) async {
        for _ in 0..<200 where segs(rig).isEmpty {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// The server only trusts a voiceprint from a device that says which model
    /// made it — and a phone without the model must not claim one.
    func testHelloDeclaresVoiceprintsOnlyWhenThePhoneMakesThem() async {
        let with = makeRig(voiceprints: FakeVoiceprints())
        await with.store.start()
        let caps = lastFrame(with, t: "hello")?["caps"] as? [String: Any]
        XCTAssertEqual(caps?["embed"] as? String, "on_device")
        XCTAssertEqual(caps?["embed_model"] as? String, LiveVoiceprint.modelID)

        let without = makeRig()
        await without.store.start()
        let plain = lastFrame(without, t: "hello")?["caps"] as? [String: Any]
        XCTAssertEqual(plain?["embed"] as? String, "none")
    }

    /// The phone already holds the samples; sending the voiceprint saves the
    /// server reading the audio back, decoding it and embedding it.
    func testACommittedLineCarriesItsVoiceprint() async {
        let fake = FakeVoiceprints()
        let rig = makeRig(voiceprints: fake)
        rig.recognizer.nextTranscript = "hello there"
        await rig.store.start()
        rig.store.receive(text: readyFrame())
        await openUtterance(rig)
        rig.recognizer.latest?.emitPartial("hello there")
        wordsStop(rig)
        await waitForSeg(rig)

        let emb = segs(rig).first?["emb"] as? [Double]
        XCTAssertEqual(emb?.count, LiveVoiceprint.dimension)
        XCTAssertGreaterThanOrEqual(fake.bytes.first ?? 0,
                                    LiveVoiceprint.minSpeechMs * LiveStore.micRate * 2 / 1000,
                                    "the utterance's own audio, not a sliver")
    }

    func testWithoutTheModelALineCarriesNoVoiceprint() async {
        let rig = makeRig()
        rig.recognizer.nextTranscript = "hello there"
        await rig.store.start()
        rig.store.receive(text: readyFrame())
        await openUtterance(rig)
        rig.recognizer.latest?.emitPartial("hello there")
        wordsStop(rig)
        await waitForSeg(rig)

        XCTAssertEqual(segs(rig).count, 1)
        XCTAssertNil(segs(rig).first?["emb"])
    }

    // MARK: - Overlapping voices

    /// Voice slot 0 until `switchAfterMs` past the start of the line's window,
    /// slot 1 after it — laid out wide enough around the window that the
    /// recogniser's own clock offset cannot move a word across the switch.
    private final class FakeSpeakerTracker: LiveSpeakerTracking, @unchecked Sendable {
        let switchAfterMs: Int
        private(set) var fedFrames = 0
        init(switchAfterMs: Int) { self.switchAfterMs = switchAfterMs }
        func feed(_ pcm16: Data, atMs: Int) { fedFrames += 1 }
        func activity(fromMs: Int, toMs: Int) async -> LiveSpeakerActivity? {
            let start = fromMs - 2000, pivot = fromMs + switchAfterMs
            let frames = (0..<(12_000 / 80)).map { index -> [Float] in
                start + index * 80 < pivot ? [0.95, 0.02, 0.02, 0.02] : [0.02, 0.95, 0.02, 0.02]
            }
            return LiveSpeakerActivity(startMs: start, frameMs: 80, frames: frames)
        }
    }

    // MARK: - The second hearing, on the phone

    private final class FakeSecondHearing: OnDeviceTranscribing, @unchecked Sendable {
        let answer: OnDeviceHeard?
        init(_ answer: OnDeviceHeard?) { self.answer = answer }
        func transcribe(pcm16: Data) async -> OnDeviceHeard? { answer }
    }

    /// Apple's recogniser takes one locale: Spanish into an English phone comes
    /// out as phonetic English, labelled English, and is never translated.
    func testALineTheModelHeardInAnotherLanguageTakesItsWords() {
        let line = LiveStore.chooseLine(apple: "Hola, Como Stas", appleLang: "en-US",
                                        heard: OnDeviceHeard(text: "Hola, ¿cómo estás?",
                                                             language: "es", confidence: 0.99))
        XCTAssertEqual(line.text, "Hola, ¿cómo estás?")
        XCTAssertEqual(line.lang, "es")
    }

    /// Same language: Apple's words stay — they are the ones the user just
    /// watched appear, and the model is no better at English.
    func testTheSameLanguageKeepsApplesWords() {
        let line = LiveStore.chooseLine(apple: "Hello, hello, are you there?", appleLang: "en-US",
                                        heard: OnDeviceHeard(text: "Hello, hello are there?",
                                                             language: "en", confidence: 0.95))
        XCTAssertEqual(line.text, "Hello, hello, are you there?")
        XCTAssertEqual(line.lang, "en-US")
    }

    func testAGuessIsNotALanguage() {
        let unsure = LiveStore.chooseLine(apple: "Okay, plus okay, is Modo", appleLang: "en-US",
                                          heard: OnDeviceHeard(text: "Okati plus Okati is Modu.",
                                                               language: "tr", confidence: 0.6))
        XCTAssertEqual(unsure.text, "Okay, plus okay, is Modo")
        XCTAssertEqual(LiveStore.chooseLine(apple: "hi", appleLang: "en", heard: nil).text, "hi")
    }

    func testACommittedLineCarriesTheSecondHearingsLanguage() async {
        let rig = makeRig(onDevice: FakeSecondHearing(
            OnDeviceHeard(text: "Hola, ¿cómo estás?", language: "es", confidence: 0.99)))
        rig.recognizer.nextTranscript = "Hola, Como Stas"
        await rig.store.start()
        rig.store.receive(text: readyFrame())
        await openUtterance(rig)
        rig.recognizer.latest?.emitPartial("Hola, Como Stas")
        wordsStop(rig)
        await waitForSeg(rig)

        XCTAssertEqual(segs(rig).first?["text"] as? String, "Hola, ¿cómo estás?")
        XCTAssertEqual(segs(rig).first?["lang"] as? String, "es")
    }

    /// A line tells the server the phone translates it only when this phone is
    /// set to; otherwise the server translates it, as it would a web line.
    func testALineSaysWhetherThisPhoneTranslatesIt() async {
        for onPhone in [true, false] {
            let rig = makeRig()
            rig.settings.translateOnPhone = onPhone
            rig.recognizer.nextTranscript = "Hola"
            await rig.store.start()
            rig.store.receive(text: readyFrame())
            await openUtterance(rig)
            rig.recognizer.latest?.emitPartial("Hola")
            wordsStop(rig)
            await waitForSeg(rig)

            XCTAssertEqual(segs(rig).first?["translate"] as? String, onPhone ? "device" : nil,
                           "on phone: \(onPhone)")
            await rig.store.stop()
        }
    }

    /// One voice, then another, inside one line: two rows, each with its own
    /// words and time range, instead of everything under whoever was louder.
    func testALineWhoseVoiceChangesIsSentAsTwoRows() async {
        let tracker = FakeSpeakerTracker(switchAfterMs: 2500)
        let rig = makeRig(speakers: tracker)
        rig.recognizer.nextTranscript = "one two three four"
        rig.recognizer.nextWords = [
            SpeechWord(text: "one", startMs: 0, endMs: 300), SpeechWord(text: "two", startMs: 300, endMs: 600),
            SpeechWord(text: "three", startMs: 5000, endMs: 5300),
            SpeechWord(text: "four", startMs: 5300, endMs: 5600),
        ]
        await rig.store.start()
        rig.store.receive(text: readyFrame())
        await openUtterance(rig)
        rig.recognizer.latest?.emitPartial("one two three four")
        wordsStop(rig)
        await waitForSeg(rig)
        await settle()

        XCTAssertEqual(segs(rig).map { $0["text"] as? String }, ["one two", "three four"])
        let starts = segs(rig).compactMap { $0["ts_start_ms"] as? Int }
        XCTAssertEqual(starts.count, 2)
        XCTAssertLessThan(starts[0], starts[1])
        XCTAssertGreaterThan(tracker.fedFrames, 0, "every captured frame reaches the tracker")
    }

    /// One voice throughout: the line goes up whole, exactly as before.
    func testALineWithOneVoiceStaysWhole() async {
        let tracker = FakeSpeakerTracker(switchAfterMs: 1_000_000)
        let rig = makeRig(speakers: tracker)
        rig.recognizer.nextTranscript = "just me talking"
        rig.recognizer.nextWords = [SpeechWord(text: "just", startMs: 0, endMs: 300),
                                    SpeechWord(text: "me", startMs: 300, endMs: 500),
                                    SpeechWord(text: "talking", startMs: 500, endMs: 900)]
        await rig.store.start()
        rig.store.receive(text: readyFrame())
        await openUtterance(rig)
        rig.recognizer.latest?.emitPartial("just me talking")
        wordsStop(rig)
        await waitForSeg(rig)
        await settle()

        XCTAssertEqual(segs(rig).map { $0["text"] as? String }, ["just me talking"])
    }

    /// A line the phone could not translate is retried when the server is
    /// busy, quietly — fast talk used to leave it untranslated under an error.
    func testAnAutomaticTranslationIsRetriedQuietlyWhenTheServerIsBusy() async {
        let rig = makeRig()
        LiveStore.translateRetryWaits = [0, 0]
        defer { LiveStore.translateRetryWaits = [2, 5] }
        await rig.store.start()
        rig.store.receive(text: readyFrame())
        let row = LiveSegment(seq: 7, text: "你好吗", lang: "zh")
        rig.transport.enqueue(json: ["ok": false, "error": "translations are queued up"], status: 429)
        rig.transport.enqueue(json: ["ok": true, "accepted": true], status: 202)

        await rig.store.translate(row, quietly: true)

        let asked = rig.transport.requests.filter { $0.url?.path.contains("/api/live/translate") == true }
        XCTAssertEqual(asked.count, 2, "refused once, then accepted")
        XCTAssertEqual(rig.store.error, "", "an automatic request shows no error")
    }

    /// NaturalLanguage on the model's own output, as measured on his recordings:
    /// real Spanish is certain; a romanised Telugu guess must not pass as a
    /// language the model transcribes.
    func testTheLanguageLabelOnRealOutputs() {
        let spanish = OnDeviceTranscriber.label("Hola, ¿cómo te llamas? Me gusta dinero.")
        XCTAssertEqual(spanish.language, "es")
        XCTAssertGreaterThanOrEqual(spanish.confidence, 0.9)
        let telugu = OnDeviceTranscriber.label("Okati plus Okati is Modu.")
        XCTAssertFalse(telugu.confidence >= 0.9
                       && LiveModelKind.parakeet.languages.contains(telugu.language),
                       "\(telugu.language) \(telugu.confidence) would relabel a Telugu line")
    }

    private func segs(_ rig: Rig) -> [[String: Any]] {
        sent(rig).filter { ($0["t"] as? String) == "seg" }
    }

    /// Enough turns of the main actor for a detached transcription to finish
    /// and send its frame.
    private func settle() async {
        for _ in 0..<8 { await Task.yield() }
    }

    /// A partial must not outlive its utterance. Stopping mid-sentence drops it
    /// rather than leaving a guess on screen wearing the transcript's clothes.
    func testStoppingMidSentenceDropsTheInProgressRow() async {
        let rig = makeRig()
        await rig.store.start()
        rig.store.receive(text: readyFrame())
        await openUtterance(rig)
        rig.recognizer.latest?.onPartial?("half a sentence")
        XCTAssertFalse(rig.store.partialText.isEmpty)

        await rig.store.stop()

        XCTAssertEqual(rig.store.partialText, "")
    }

    /// And it ages out if no committed row ever arrives — a recogniser that
    /// produced text and then failed must not strand it there for the session.
    func testAnInProgressRowThatIsNeverCommittedAgesOut() async {
        let rig = makeRig()
        await rig.store.start()
        rig.store.receive(text: readyFrame())
        await openUtterance(rig)
        rig.recognizer.latest?.onPartial?("never committed")

        // The utterance ends, and nothing comes back for it.
        rig.input.emitFrames(amplitude: 0.0, ms: 1500)
        await Task.yield()
        await Task.yield()
        rig.clock.advance(ms: LiveStore.partialGraceMs + 100)

        XCTAssertEqual(rig.store.partialText, "")
        XCTAssertEqual(rig.store.committingText, "")
    }

    // MARK: - The indicator and the Live Activity cannot outlive capture

    /// The tab-bar dot and the Live Activity both read `LiveCaptureBeacon`. A
    /// beacon still saying "recording" after the microphone stopped tells the
    /// user their room is being listened to when it is not, which is the worst
    /// thing this feature can do.
    func testTheRecordingBeaconGoesDownWithTheMicrophone() async {
        let rig = makeRig()
        await rig.store.start()
        rig.store.receive(text: readyFrame())

        XCTAssertTrue(LiveCaptureBeacon.shared.capturing)
        XCTAssertNotNil(rig.store.captureStartedAt)

        await rig.store.stop()

        XCTAssertFalse(LiveCaptureBeacon.shared.capturing)
        XCTAssertNil(LiveCaptureBeacon.shared.startedAt)
        XCTAssertNil(rig.store.captureStartedAt)
    }

    /// Including when capture stops ITSELF. A halt is exactly the case where
    /// the user is not watching the screen.
    func testAHaltTakesTheRecordingBeaconDownToo() async {
        let rig = makeRig(spoolLimit: 4096)
        await rig.store.start()
        rig.store.receive(text: readyFrame())
        rig.connector.socket?.serverClosed(nil)
        rig.input.emitFrames(amplitude: 0.05, ms: 2000)
        await Task.yield()
        await Task.yield()
        // The halt's own teardown is a detached `stop()`.
        for _ in 0..<8 { await Task.yield() }

        XCTAssertNotNil(rig.store.halt)
        XCTAssertFalse(rig.store.capturing)
        XCTAssertFalse(LiveCaptureBeacon.shared.capturing,
                       "capture stopped itself, so the indicator must have gone with it")
    }

    /// Opens an utterance: enough voiced audio for the segmenter to call it
    /// speech and for the store to attach a transcription session.
    /// The speaker stops: the words settle and the voice goes quiet.
    private func wordsStop(_ rig: Rig) {
        rig.input.emitFrames(amplitude: 0.01, ms: LiveStore.wordsSettledMs + 200)
    }

    private func openUtterance(_ rig: Rig) async {
        rig.input.emitFrames(amplitude: 0.05, ms: 200)
        await Task.yield()
        await Task.yield()
        rig.input.emitFrames(amplitude: 0.05, ms: 400)
        await Task.yield()
        await Task.yield()
    }

    // MARK: - Unsent conversation is never discarded

    /// The invariant behind `haltCapture`'s promise. It used to call `spool.reset()`
    /// two lines after saying "Nothing already captured has been deleted."
    func testAHaltKeepsTheBufferedConversationItPromisesToKeep() async {
        let rig = makeRig(spoolLimit: 4096)
        await rig.store.start()
        rig.store.receive(text: readyFrame())
        rig.connector.socket?.serverClosed(nil)

        // Fill past the bound so the halt fires with a real backlog behind it.
        rig.input.emitFrames(amplitude: 0.05, ms: 2000)
        await Task.yield()
        await Task.yield()

        XCTAssertNotNil(rig.store.halt)
        XCTAssertGreaterThan(rig.store.spooledFrames, 0,
                             "the halt must not delete the audio its own message promises it kept")
        XCTAssertFalse(rig.settings.lastSessionID.isEmpty,
                       "the resume cursor has to survive too, or the backlog can never be uploaded")
    }

    /// Tapping Stop while the status line says "Reconnecting — … buffered" must not be
    /// a delete. The next start resumes the same session and drains it.
    func testStoppingWithABacklogKeepsItAndSaysSo() async {
        let rig = makeRig()
        await rig.store.start()
        rig.store.receive(text: readyFrame())
        rig.connector.socket?.serverClosed(nil)
        rig.input.emitFrames(amplitude: 0.05, ms: 1000)
        await Task.yield()
        let buffered = rig.store.spooledFrames
        XCTAssertGreaterThan(buffered, 0)

        await rig.store.stop()

        XCTAssertGreaterThan(rig.store.spooledFrames, 0, "Stop must not delete unsent audio")
        XCTAssertEqual(rig.settings.lastSessionID, "L1", "so the next start can resume and upload it")
        XCTAssertFalse(rig.store.warningText.isEmpty, "and the user must be told it is still waiting")
    }

    /// A clean stop clears the SPOOL but keeps the CURSOR: Stop followed by
    /// Record is one conversation with a pause in it, not two. Clearing the
    /// cursor is what made every tap of Record open a new session — and a new
    /// chat — so a burst of short recordings never added up into a window worth
    /// summarising.
    func testACleanStopKeepsTheCursorSoTheNextRecordContinues() async {
        let rig = makeRig()
        await rig.store.start()
        rig.store.receive(text: readyFrame())
        await rig.store.stop()

        XCTAssertEqual(rig.store.spooledFrames, 0)
        XCTAssertEqual(rig.settings.lastSessionID, "L1")

        await rig.store.start()
        let resume = lastFrame(rig, t: "hello")?["resume"] as? [String: Any]
        XCTAssertEqual(resume?["live_session_id"] as? String, "L1",
                       "the next start asks to continue the same conversation")
    }

    /// The one path that deletes unsent conversation is the user choosing it.
    func testDiscardingTheBacklogIsExplicit() async {
        let rig = makeRig()
        await rig.store.start()
        rig.store.receive(text: readyFrame())
        rig.connector.socket?.serverClosed(nil)
        rig.input.emitFrames(amplitude: 0.05, ms: 1000)
        await Task.yield()
        XCTAssertGreaterThan(rig.store.spooledFrames, 0)

        rig.store.discardBacklog()

        XCTAssertEqual(rig.store.spooledFrames, 0)
        XCTAssertEqual(rig.store.warningText, "")
    }

    /// `URLSessionWebSocketTask.send` reports failure asynchronously, so a dead socket
    /// swallows everything written in the seconds before `onClose`. Those frames go
    /// back into the spool — nothing else in the protocol can recover them.
    func testFramesWrittenBeforeASocketDeathAreRequeuedNotLost() async {
        let rig = makeRig()
        await rig.store.start()
        rig.store.receive(text: readyFrame())
        // Speech that goes straight down a socket that is still believed healthy.
        rig.input.emitFrames(amplitude: 0.05, ms: 600)
        await Task.yield()
        XCTAssertEqual(rig.store.spooledFrames, 0, "with a live socket nothing should be spooled")
        XCTAssertGreaterThan(rig.connector.socket?.sentData.count ?? 0, 0)

        rig.connector.socket?.serverClosed(NSError(domain: "test", code: 1))

        XCTAssertGreaterThan(rig.store.spooledFrames, 0,
                             "audio written into a socket that then died must be re-queued")
    }

    // MARK: - Honest status

    func testTheServerSayingItIsNotReceivingAudioReachesTheStatusLine() async {
        let rig = makeRig()
        await rig.store.start()
        rig.store.receive(text: readyFrame())
        XCTAssertEqual(rig.store.statusText, "Recording on device")

        rig.store.receive(text: json(["t": "state", "paused": true]))
        XCTAssertEqual(rig.store.statusText, "Recording — but Jarvis isn't receiving audio")

        rig.store.receive(text: json(["t": "state", "recording": true, "paused": false]))
        XCTAssertEqual(rig.store.statusText, "Recording on device")
    }

    /// A server that clears its warning with an empty string must actually clear it.
    func testAnEmptyWarningWithdrawsTheBanner() async {
        let rig = makeRig()
        await rig.store.start()
        rig.store.receive(text: json(["t": "state", "warning": "slow consumer"]))
        XCTAssertEqual(rig.store.warningText, "slow consumer")

        rig.store.receive(text: json(["t": "state", "warning": ""]))
        XCTAssertEqual(rig.store.warningText, "", "an amber banner must not outlive its cause")
    }

    /// A transient load failure must not pin a toast over the transcript forever.
    func testAnErrorCanBeDismissedAndIsWithdrawnByASuccessfulLoad() async {
        let rig = makeRig()
        rig.store.receive(text: json(["t": "error", "error": "momentary blip"]))
        XCTAssertEqual(rig.store.error, "momentary blip")

        rig.store.dismissError()
        XCTAssertEqual(rig.store.error, "")

        rig.store.receive(text: json(["t": "error", "error": "another"]))
        await rig.store.loadStorage()
        XCTAssertEqual(rig.store.error, "", "a successful load withdraws a previous complaint")
    }

    // MARK: - Session isolation

    /// Stop, then Record again: the transcript must still be there. Clearing it
    /// on the second tap of Record is exactly the report — "when I click stop
    /// and start again it is clearing the chat".
    func testASecondRecordingContinuesTheSameConversation() async {
        let rig = makeRig()
        await rig.store.start()
        rig.store.receive(text: readyFrame(sessionID: "L1", seq: 5))
        rig.store.receive(text: json(["t": "seg", "seq": 5, "text": "from the first meeting"]))
        rig.input.emitFrames(amplitude: 0.05, ms: 1500)
        await Task.yield()
        await rig.store.stop()

        await rig.store.start()
        rig.store.receive(text: readyFrame(sessionID: "L1", seq: 5))

        XCTAssertEqual(rig.store.segments.map(\.seq), [5],
                       "the conversation so far stays on screen")
        let resume = lastFrame(rig, t: "hello")?["resume"] as? [String: Any]
        XCTAssertEqual(resume?["live_session_id"] as? String, "L1")
        XCTAssertEqual(resume?["after_seq"] as? Int, 5,
                       "and it resumes from where it got to, not from zero")
    }

    /// The SERVER decides when a conversation has grown past its budget. The
    /// client always asks to continue the last one; a different id in `ready` is
    /// how it learns it was rolled over, and the old rows, cursor and audio
    /// clock all belong to the session that just ended.
    func testTheServerRollingOverClearsTheTimelineAndTheCursor() async {
        let rig = makeRig()
        await rig.store.start()
        rig.store.receive(text: readyFrame(sessionID: "L1", seq: 5))
        rig.store.receive(text: json(["t": "seg", "seq": 5, "text": "from the first meeting"]))
        await rig.store.stop()

        await rig.store.start()
        // The server declines the resume and mints a new session.
        rig.store.receive(text: readyFrame(sessionID: "L2", seq: 0))

        XCTAssertTrue(rig.store.segments.isEmpty,
                      "the previous conversation's rows must not still be on screen")
        XCTAssertEqual(rig.store.liveSessionID, "L2", "the server's id wins")
        XCTAssertEqual(rig.settings.lastSessionID, "L2")
        XCTAssertEqual(rig.settings.lastSeq, 0,
                       "a new session must not be asked to continue from a seq it never reached")
    }

    /// A session the user deleted is not resumed on the next tap of Record.
    func testDeletingTheSessionBeingRecordedForgetsItsCursor() async {
        let rig = makeRig()
        rig.transport.route("/api/live/delete", json: ["ok": true])
        await rig.store.start()
        rig.store.receive(text: readyFrame(sessionID: "L1", seq: 3))

        await rig.store.delete(kind: .session, id: "L1")

        XCTAssertTrue(rig.store.segments.isEmpty)
        XCTAssertEqual(rig.settings.lastSessionID, "")
    }

    /// A `ready` with no session id used to blank `liveSessionID` — which silently
    /// disabled backfill, fact-check, translate and endSession, and left the spool
    /// holding the previous session's frames ready to drain into this one.
    func testAReadyWithNoSessionIDIsRefused() async {
        let rig = makeRig()
        await rig.store.start()
        rig.store.receive(text: readyFrame(sessionID: "L1"))
        XCTAssertEqual(rig.store.liveSessionID, "L1")

        rig.store.receive(text: json(["t": "ready", "live_session_id": "", "seq": 0]))

        XCTAssertEqual(rig.store.liveSessionID, "L1", "a malformed ready must not blank the session")
        XCTAssertFalse(rig.store.error.isEmpty)
    }

    /// `capturing` is not true until three awaits into `start()`, so the only thing
    /// stopping a double-tap from running two concurrent starts is a synchronous latch.
    func testADoubleTapOnRecordStartsOnlyOneCapture() async {
        let rig = makeRig()
        async let first: Void = rig.store.start()
        async let second: Void = rig.store.start()
        _ = await (first, second)

        XCTAssertTrue(rig.store.capturing)
        XCTAssertEqual(rig.input.startedRates.count, 1,
                       "two concurrent starts would have the loser stop the winner's microphone")
        XCTAssertTrue(rig.input.isRunning)
    }

    // MARK: - Capture gating

    /// "Record on this phone" off must mean off — not a screen that looks like it is
    /// recording while nothing is captured.
    func testCaptureIsRefusedWhenThisDeviceIsSetNotToRecord() async {
        let rig = makeRig()
        rig.settings.captureHere = false
        await rig.store.start()

        XCTAssertFalse(rig.store.capturing)
        XCTAssertTrue(rig.input.startedRates.isEmpty, "the mic must never have opened")
        XCTAssertFalse(rig.store.error.isEmpty)
    }

    func testDeniedMicPermissionIsReportedAndOpensNothing() async {
        let rig = makeRig()
        rig.input.permission = false
        await rig.store.start()

        XCTAssertFalse(rig.store.capturing)
        XCTAssertTrue(rig.input.startedRates.isEmpty)
        XCTAssertTrue(rig.store.error.lowercased().contains("microphone"), rig.store.error)
    }

    // MARK: - The ambient claim

    /// The crux of deliverable 2: Live must NOT take the voice plan. `.videoChat`'s
    /// echo cancellation attenuates the distant speakers ambient mode exists to hear.
    func testLiveTakesTheAmbientClaimAndNotTheVoiceOne() async {
        let rig = makeRig()
        await rig.store.start()

        XCTAssertTrue(AudioSessionArbiter.ambientPlan.mode == .default)
        XCTAssertNotEqual(AudioSessionArbiter.ambientPlan.mode, AudioSessionArbiter.voicePlan.mode)
        XCTAssertEqual(rig.applier.mode, .default,
                       "the live session must not be configured with the voice turn's .videoChat")
        XCTAssertTrue(rig.applier.categoryOptions.contains(.allowBluetooth),
                      "AirPods can only be an INPUT with the hands-free profile allowed")
    }

    func testStoppingReleasesTheClaimAndTheMic() async {
        let rig = makeRig()
        await rig.store.start()
        rig.store.receive(text: readyFrame())
        XCTAssertTrue(rig.arbiter.holds(.ambient))

        await rig.store.stop()

        XCTAssertFalse(rig.store.capturing)
        XCTAssertGreaterThan(rig.input.stopCount, 0)
        XCTAssertFalse(rig.arbiter.holds(.ambient),
                       "nothing may be left holding the ambient claim after a stop")
    }

    // MARK: - The codec is what the bytes are

    /// **The claim the whole Opus change rests on.** `hello` tells the server how to
    /// store everything that follows it, so a mismatch between the declared codec
    /// and the encoding of the frames does not fail — it silently writes samples
    /// into a file labelled `opus-packets-len32@48000`, which nothing can decode
    /// afterwards.
    ///
    /// Deliberately written to pass EITHER way: if CoreAudio here will not encode
    /// Opus, the honest outcome is `pcm16` and PCM-sized frames, and that is a pass.
    /// What it will not accept is an Opus label over PCM-sized bytes.
    func testTheDeclaredCodecIsWhatTheAudioFramesActuallyAre() async {
        let rig = makeRig()
        await rig.store.start()
        rig.store.receive(text: readyFrame())

        let caps = lastFrame(rig, t: "hello")?["caps"] as? [String: Any]
        let declared = caps?["codec"] as? String
        XCTAssertEqual(declared, rig.store.audioCodec,
                       "hello must declare exactly what the store encodes with")
        XCTAssertEqual(caps?["rate"] as? Int, rig.store.audioRate)

        let speechMs = 400
        rig.input.emitFrames(amplitude: 0.05, ms: speechMs)
        await Task.yield()

        let frames = (rig.connector.socket?.sentData ?? []).compactMap(LiveAudioFrame.decode)
        XCTAssertFalse(frames.isEmpty, "speech has to reach the socket")
        let sentBytes = frames.reduce(0) { $0 + $1.payload.count }
        let pcmBytes = LiveStore.micRate * speechMs / 1000 * 2

        if declared == AmbientOpusEncoder.wireCodec {
            XCTAssertEqual(caps?["rate"] as? Int, 48000,
                           "the declared rate must be the Opus rate a decoder needs")
            XCTAssertLessThan(sentBytes, pcmBytes / 2,
                              "\(sentBytes)B for \(pcmBytes)B of audio is not encoded")
            for frame in frames {
                XCTAssertLessThanOrEqual(frame.payload.count, AmbientOpusEncoder.maxPacketBytes,
                                         "one frame must carry exactly ONE Opus packet")
            }
        } else {
            XCTAssertEqual(declared, "pcm16", "the only honest alternative to Opus")
            XCTAssertEqual(caps?["rate"] as? Int, LiveStore.micRate)
            XCTAssertGreaterThanOrEqual(sentBytes, pcmBytes / 2,
                                        "PCM16 declared, so PCM16 must be what went up")
        }
    }

    /// The frame header exists to keep audio timing correct (§2.2), and each packet
    /// is its own 20 ms of it — so the packets of one captured chunk must not all
    /// claim the same instant.
    func testEveryAudioFrameGetsItsOwnSeqAndPlaceOnTheClock() async {
        let rig = makeRig()
        await rig.store.start()
        rig.store.receive(text: readyFrame())
        rig.input.emitFrames(amplitude: 0.05, ms: 400)
        await Task.yield()

        let frames = (rig.connector.socket?.sentData ?? []).compactMap(LiveAudioFrame.decode)
        XCTAssertGreaterThan(frames.count, 1)
        let seqs = frames.map { $0.seq }
        XCTAssertEqual(seqs, seqs.sorted(), "a seq that goes backwards reorders the recording")
        XCTAssertEqual(Set(seqs).count, seqs.count, "two frames may not share a seq")
        let stamps = frames.map { $0.tsMs }
        XCTAssertEqual(stamps, stamps.sorted(), "the audio clock must not run backwards")
        XCTAssertGreaterThan(Set(stamps).count, 1,
                             "every frame claiming one instant loses the timing the header is for")
    }

    /// The spool has to know which encoding it is holding, or a relaunch drains it
    /// under whatever the next launch happens to declare.
    func testTheSpoolIsToldWhichEncodingItsQueuedAudioIs() async {
        let rig = makeRig()
        await rig.store.start()
        XCTAssertEqual(rig.spool.codec, rig.store.audioCodec)
        XCTAssertFalse(rig.store.audioCodec.isEmpty)
    }

    /// Falling back to PCM16 is allowed; falling back QUIETLY is not, because the
    /// cost lands on the user as ten times the storage.
    func testAnyFallbackToUncompressedAudioIsStated() async {
        let rig = makeRig()
        await rig.store.start()
        if rig.store.audioCodec == "pcm16" {
            XCTAssertFalse(rig.store.codecNotice.isEmpty,
                           "uncompressed recording has to be visible, not silent")
        } else {
            XCTAssertTrue(rig.store.codecNotice.isEmpty,
                          "nothing to explain when the audio is compressed")
        }
    }

    // MARK: - Stamping the real utterance

    /// The recogniser knows where the words were; the amplitude gate only knows
    /// where it was open. Narrowing to the former is the whole point — a 15 s
    /// window around two spoken words had the server embed 15 s of room tone.
    func testTheRecognisersRangeNarrowsTheGatesWindow() {
        // Gate open 0…15000, recogniser found words 2000…2400 from its first
        // sample, which sat at 1000 on the session clock.
        let bounds = LiveStore.narrowedBounds(startMs: 0, endMs: 15_000, anchorMs: 1_000,
                                              observedMs: 2_000...2_400)
        XCTAssertEqual(bounds.start, 3_000 - LiveStore.boundsPadMs)
        XCTAssertEqual(bounds.end, 3_400 + LiveStore.boundsPadMs)
        XCTAssertLessThan(bounds.end - bounds.start, 1_000,
                          "a short utterance must not keep a long window's span")
    }

    /// No range, no change. The engines that do not report one must not end up
    /// with a zero-length segment.
    func testNoReportedRangeLeavesTheGatesWindowAlone() {
        let bounds = LiveStore.narrowedBounds(startMs: 400, endMs: 2_600, anchorMs: 300,
                                              observedMs: nil)
        XCTAssertEqual(bounds.start, 400)
        XCTAssertEqual(bounds.end, 2_600)
    }

    /// A range that lands outside the window means the analyzer's clock is not
    /// ours. A wrong span is worse than a loose one — the server slices the
    /// identification audio out of exactly these numbers — so it is discarded.
    func testARangeOutsideTheWindowIsDiscardedRatherThanTrusted() {
        let far = LiveStore.narrowedBounds(startMs: 1_000, endMs: 2_000, anchorMs: 0,
                                           observedMs: 90_000...95_000)
        XCTAssertEqual(far.start, 1_000)
        XCTAssertEqual(far.end, 2_000)

        let before = LiveStore.narrowedBounds(startMs: 5_000, endMs: 6_000, anchorMs: 0,
                                              observedMs: 10...20)
        XCTAssertEqual(before.start, 5_000)
        XCTAssertEqual(before.end, 6_000)
    }

    /// The narrowed bounds can never escape the window the audio gate opened, so
    /// the padding cannot invent audio that was never captured.
    func testTheNarrowedBoundsStayInsideTheCapturedWindow() {
        let bounds = LiveStore.narrowedBounds(startMs: 1_000, endMs: 3_000, anchorMs: 1_000,
                                              observedMs: 0...2_000)
        XCTAssertGreaterThanOrEqual(bounds.start, 1_000)
        XCTAssertLessThanOrEqual(bounds.end, 3_000)
    }

    // MARK: - Asking for a fact-check

    /// The card appears on TAP, not when the answer arrives. The request is a
    /// whole agent turn; without this the transcript showed nothing at all for
    /// several seconds.
    func testTappingFactCheckPutsALoadingCardUpAtOnce() async {
        let rig = makeRig()
        rig.transport.route("/api/live/factcheck", json: ["ok": true])
        await rig.store.start()
        rig.store.receive(text: readyFrame())
        rig.store.receive(text: json(["t": "seg", "seq": 1, "text": "The bridge opened in 1937."]))

        await rig.store.factCheckConversation()
        XCTAssertEqual(rig.store.factCheck?.pending, true,
                       "the card has to be up while the check runs")
        XCTAssertTrue(rig.store.checkingConversation,
                      "and the button has to stay busy for the same length of time")
    }

    /// The loading card BECOMES the verdict — same card, same place — rather than
    /// a placeholder vanishing and a different card arriving.
    func testTheLoadingCardBecomesTheVerdictInPlace() async {
        let rig = makeRig()
        rig.transport.route("/api/live/factcheck", json: ["ok": true])
        await rig.store.start()
        rig.store.receive(text: readyFrame())
        rig.store.receive(text: json(["t": "seg", "seq": 1, "text": "The bridge opened in 1937."]))
        await rig.store.factCheckConversation()

        rig.store.receive(text: json(["t": "insight", "kind": "fact_check", "seq": 1,
                                      "text": "It opened in 1937.", "verdict": "true",
                                      "anchor_seq": 1]))
        XCTAssertEqual(rig.store.factCheck?.pending, false)
        XCTAssertEqual(rig.store.factCheck?.anchorSeq, 1)
        XCTAssertFalse(rig.store.checkingConversation,
                       "the button must come back once the verdict has landed")
    }

    /// The server refusing the job is not a verdict, and must not leave the card
    /// spinning over work that is not happening.
    func testARefusedFactCheckReplacesTheLoadingCardWithAFailure() async {
        let rig = makeRig()
        rig.transport.route("/api/live/factcheck", json: ["error": "nope"], status: 404)
        await rig.store.start()
        rig.store.receive(text: readyFrame())
        rig.store.receive(text: json(["t": "seg", "seq": 1, "text": "something"]))

        await rig.store.factCheckConversation()
        XCTAssertEqual(rig.store.factCheck?.failed, true)
        XCTAssertEqual(rig.store.factCheck?.pending, false)
        XCTAssertFalse(rig.store.checkingConversation)
        XCTAssertFalse(rig.store.factCheck?.isRefuted ?? true,
                       "“we couldn't check” must never read as “this is false”")
    }

    // MARK: - Merging two voices

    /// A name is the strongest signal there is — somebody typed it. Throwing it
    /// away to keep an anonymous "Speaker 4" would undo work done by hand.
    func testTheNamedVoiceSurvivesAMergeByDefault() {
        let named = LiveSpeaker(id: "a", name: "Pranav", segmentCount: 2)
        let anonymous = LiveSpeaker(id: "b", name: "", segmentCount: 90)
        XCTAssertEqual(LiveStore.survivorOfMerge(named, anonymous).id, "a")
        XCTAssertEqual(LiveStore.survivorOfMerge(anonymous, named).id, "a",
                       "and regardless of which one was tapped first")
    }

    /// With nothing to choose between them, the bigger voiceprint wins: fewer
    /// rows to rewrite and the better thing to keep matching against.
    func testWithoutNamesTheVoiceWithMoreHistorySurvives() {
        let small = LiveSpeaker(id: "a", segmentCount: 3)
        let large = LiveSpeaker(id: "b", segmentCount: 40)
        XCTAssertEqual(LiveStore.survivorOfMerge(small, large).id, "b")
        XCTAssertEqual(LiveStore.survivorOfMerge(large, small).id, "b")
    }

    /// Two named voices are the user's call, not ours — so the choice is stable
    /// and the screen offers a swap rather than picking a winner on a hunch.
    func testTwoNamedVoicesFallBackToTheFirstRatherThanGuessing() {
        let first = LiveSpeaker(id: "a", name: "Pranav", segmentCount: 5)
        let second = LiveSpeaker(id: "b", name: "Alex", segmentCount: 5)
        XCTAssertEqual(LiveStore.survivorOfMerge(first, second).id, "a")
    }

    // MARK: - Helpers

    private func json(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    // MARK: - Notes survive being away

    /// A verdict, a monitor note and the wrap-up only ever existed as frames on
    /// this device, so closing the app lost them from the screen while the
    /// paired chat kept them forever. The server stores every one.
    func testLookingBackAtAConversationRestoresWhatWasSaidAboutIt() async {
        let rig = makeRig(transcript: [
            "segments": [["seq": 1, "ts_start_ms": 0, "ts_end_ms": 900,
                          "text": "the nile is the shortest river"],
                         ["seq": 2, "ts_start_ms": 1000, "ts_end_ms": 1900,
                          "text": "anyway what is nine plus nine"]],
            "insights": [["kind": "fact_check", "seq": 1, "anchor_seq": 1,
                          "scope": "conversation", "verdict": "false",
                          "text": "It is the longest.",
                          "sources": ["https://example.invalid/nile"]]],
        ])

        await rig.store.view(session: LiveSessionSummary(id: "L9", state: "ended"))

        XCTAssertEqual(rig.store.rows.count, 2, "both utterances are back")
        XCTAssertEqual(rig.store.factCheck?.text, "It is the longest.")
        XCTAssertEqual(rig.store.factCheck?.anchorSeq, 1,
                       "and it still knows which line it was about")
    }

    /// The one thing a delete must never do quietly: claim to have removed a
    /// remembered fact that is still in MEMORY.md.
    func testADeleteThatKeptSomethingSaysSo() async {
        let rig = makeRig()
        rig.transport.route("/api/live/delete", json: [
            "ok": true, "freed_bytes": 1024,
            "facts_retracted": 2, "facts_unattributable": 1,
        ])

        await rig.store.delete(kind: .speakerForget, id: "spk_a")

        XCTAssertEqual(rig.store.error,
                       "Deleted, but 1 could not be tied to this voice and was kept.")
    }

    func testADeleteThatTookEverythingSaysNothing() async {
        let rig = makeRig()
        rig.transport.route("/api/live/delete",
                            json: ["ok": true, "freed_bytes": 1024, "facts_retracted": 2])

        await rig.store.delete(kind: .session, id: "L9")

        XCTAssertTrue(rig.store.error.isEmpty,
                      "nothing was kept, so there is nothing to say")
    }
}

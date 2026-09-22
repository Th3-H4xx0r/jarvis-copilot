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

    private func makeRig(spoolLimit: Int = 1024 * 1024,
                         readiness: SpeechReadiness = .ready,
                         keyValues: [String: Any] = [:]) -> Rig {
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
        transport.route("/api/live/transcript", json: ["segments": []])

        let store = LiveStore(api: LiveAPI(api: api),
                              input: input,
                              session: session,
                              recognizer: recognizer,
                              connector: connector,
                              clock: clock,
                              spool: spool,
                              settings: settings,
                              preferences: MemoryKeyValueStore(keyValues))
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

    /// The guess and the record must never both be on screen. The committed row
    /// arriving is what takes the in-progress one away.
    func testTheCommittedRowReplacesTheInProgressOne() async {
        let rig = makeRig()
        await rig.store.start()
        rig.store.receive(text: readyFrame())
        await openUtterance(rig)
        rig.recognizer.latest?.onPartial?("we should ship on")
        XCTAssertFalse(rig.store.partialText.isEmpty)

        rig.store.receive(text: json(["t": "seg", "seq": 1,
                                      "text": "We should ship on Friday."]))

        XCTAssertEqual(rig.store.partialText, "",
                       "the guess goes the moment the record lands")
        XCTAssertEqual(rig.store.segments.map(\.text), ["We should ship on Friday."])
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
}

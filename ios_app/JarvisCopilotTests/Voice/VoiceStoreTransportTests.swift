import XCTest
@testable import JarvisCopilot

/// The half of `VoiceStore` that speaks a reply in the JARVIS voice
/// (`VoiceStoreTransport.speakLocally` / `acknowledgeLocally`).
///
/// The property that matters is ATOMICITY: every sentence of a reply is
/// synthesized concurrently but enqueued as ONE batch. Enqueuing each clip as it
/// resolved let a slow middle sentence drain the queue between clips, which
/// flipped the orb to "thinking" and let the resume-grace timer abandon the rest
/// of the reply.
@MainActor
final class VoiceStoreTransportTests: XCTestCase {

    private struct Rig {
        let store: VoiceStore
        let transport: MockTransport
        let input: MockAudioInput
        let output: MockAudioOutput
        let synthesizer: MockVoiceSynthesizing
        let connector: MockVoiceSocketConnector
        let clock: TestVoiceClock
    }

    private func makeRig(ttsBody: Any? = ["ok": true]) -> Rig {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/voice/session", json: ["session_id": "voice-1"])
        transport.route("/api/devices", json: [])
        transport.route("/api/session", json: ["session": ["active_stream_id": ""]])
        if let ttsBody { transport.route("/api/voice/synthesize", json: ttsBody) }
        else { transport.route("/api/voice/synthesize", json: [:], status: 502) }

        let input = MockAudioInput()
        let output = MockAudioOutput()
        let synthesizer = MockVoiceSynthesizing()
        let connector = MockVoiceSocketConnector()
        let clock = TestVoiceClock()
        let store = VoiceStore(api: api, input: input, output: output,
                               recognizer: MockSpeechRecognizing(), synthesizer: synthesizer,
                               audioSession: MockAudioSessionControlling(), connector: connector,
                               clock: clock, keyValueStore: MemoryKeyValueStore())
        return Rig(store: store, transport: transport, input: input, output: output,
                   synthesizer: synthesizer, connector: connector, clock: clock)
    }

    private func startListening(_ rig: Rig) async {
        await rig.store.primaryAction()
        await waitUntilVoice { rig.store.state != .connecting }
        await settleVoiceTasks()
    }

    /// Three sentences, each long enough that `voiceSplitForSpeech` keeps them
    /// apart rather than merging the short ones.
    private let threeSentences = """
    Sentence number one is long enough to stand on its own here. \
    Sentence number two is also quite long enough to stand alone. \
    Sentence number three closes the whole reply out nicely.
    """

    // MARK: - speakLocally

    func testEverySentenceBecomesItsOwnClipAndSegment() async throws {
        let rig = makeRig()
        await startListening(rig)

        await rig.store.speakLocally(threeSentences)
        await settleVoiceTasks()
        await rig.store.audio.settle()

        XCTAssertEqual(rig.store.replySegments.count, 3)
        let synthesized = rig.transport.requests.filter { $0.url?.path == "/api/voice/synthesize" }
        XCTAssertEqual(synthesized.count, 3, "one clip per sentence, so the highlight can advance")
        // All three were handed to the queue as one batch: the first is playing
        // and the other two are already behind it.
        XCTAssertEqual(rig.output.played.count, 1)
        XCTAssertTrue(rig.store.audio.isBusy)
        XCTAssertEqual(rig.store.state, .speaking)
        XCTAssertNil(rig.store.error)
    }

    /// The clips must be enqueued in SENTENCE order, not in the order the
    /// concurrent TTS calls happened to finish.
    func testClipsPlayInSentenceOrder() async throws {
        let rig = makeRig()
        await startListening(rig)

        await rig.store.speakLocally(threeSentences)
        await settleVoiceTasks()
        await rig.store.audio.settle()
        XCTAssertEqual(rig.store.spokenWords, 0, "segment 0 is the one playing")

        rig.output.finishClip()
        await settleVoiceTasks()
        await rig.store.audio.settle()
        let afterFirst = rig.store.spokenWords
        XCTAssertEqual(afterFirst, rig.store.replySegments[0].words.count,
                       "clip 2 belongs to segment 1, so segment 0 is fully spoken")

        rig.output.finishClip()
        await settleVoiceTasks()
        await rig.store.audio.settle()
        XCTAssertEqual(rig.store.spokenWords,
                       afterFirst + rig.store.replySegments[1].words.count)
        XCTAssertEqual(rig.output.played.count, 3)
    }

    /// A chunk that the reply drops (a fenced code block strips to nothing) must
    /// not shift the remaining clips onto the wrong segments.
    func testADroppedChunkKeepsTheClipsAlignedWithTheirSegments() async throws {
        let rig = makeRig()
        await startListening(rig)

        let withCode = """
        Sentence number one is long enough to stand on its own here.
        ```
        print("this is never spoken")
        ```
        Sentence number two is also quite long enough to stand alone.
        """
        await rig.store.speakLocally(withCode)
        await settleVoiceTasks()
        await rig.store.audio.settle()

        XCTAssertEqual(rig.store.replySegments.count, 2)
        XCTAssertFalse(rig.store.assistantText.contains("print"))
        let synthesized = rig.transport.requests.filter { $0.url?.path == "/api/voice/synthesize" }
        XCTAssertEqual(synthesized.count, 2, "one clip per SEGMENT, never one per split")

        rig.output.finishClip()
        await settleVoiceTasks()
        await rig.store.audio.settle()
        XCTAssertEqual(rig.store.spokenWords, rig.store.replySegments[0].words.count)
    }

    func testAReplyThatStripsToNothingJustDrainsPlayback() async {
        let rig = makeRig()
        await startListening(rig)

        await rig.store.speakLocally("```\ncode only\n```")
        await settleVoiceTasks()

        XCTAssertTrue(rig.store.replySegments.isEmpty)
        XCTAssertTrue(rig.output.played.isEmpty)
        XCTAssertEqual(rig.store.state, .listening, "nothing to say → straight back to listening")
    }

    /// silent-failures M15: offline, the reply stays on screen as text and the
    /// user is told why they heard nothing.
    func testNoTtsAudioLeavesTheTextAndSaysSo() async {
        let rig = makeRig(ttsBody: nil)
        await startListening(rig)

        await rig.store.speakLocally(threeSentences)
        await settleVoiceTasks()

        XCTAssertEqual(rig.store.replySegments.count, 3)
        XCTAssertTrue(rig.output.played.isEmpty)
        XCTAssertEqual(rig.store.error, VoiceStore.ttsUnavailableNotice)
        XCTAssertEqual(rig.store.spokenWords, rig.store.reply.totalWords,
                       "nothing will voice it, so light the whole reply up")
    }

    /// swift-correctness M24: a barge-in / Stop while the sentences are still
    /// being synthesized must drop the whole batch rather than talk over
    /// whatever the user is saying now.
    func testATurnStoppedMidSynthesisEnqueuesNothing() async {
        let (_, mock) = JarvisAPI.mocked()
        mock.route("/api/voice/session", json: ["session_id": "voice-1"])
        mock.route("/api/devices", json: [])
        mock.route("/api/session", json: ["session": ["active_stream_id": ""]])
        mock.route("/api/voice/synthesize", json: ["ok": true])

        let hook = VoiceRequestHook(inner: mock)
        let input = MockAudioInput()
        let output = MockAudioOutput()
        let store = VoiceStore(api: JarvisAPI(credentials: TestCredentials(), transport: hook),
                               input: input, output: output,
                               recognizer: MockSpeechRecognizing(),
                               synthesizer: MockVoiceSynthesizing(),
                               audioSession: MockAudioSessionControlling(),
                               connector: MockVoiceSocketConnector(),
                               clock: TestVoiceClock(), keyValueStore: MemoryKeyValueStore())
        await store.primaryAction()
        await waitUntilVoice { store.state != .connecting }
        await settleVoiceTasks()

        // Interrupt from INSIDE the first TTS call, i.e. while the task group is
        // still running — exactly when a real barge-in lands.
        hook.onRequest = { path in
            guard path.contains("/api/voice/synthesize") else { return }
            await MainActor.run { store.turnEpoch += 1 }
        }
        await store.speakLocally(threeSentences)
        await settleVoiceTasks()

        XCTAssertTrue(output.played.isEmpty, "the abandoned reply must never reach the speaker")
    }

    // MARK: - acknowledgeLocally

    func testALocalAckUsesThePhoneVoiceAndFinishesTheTurn() async {
        let rig = makeRig()
        await startListening(rig)

        await rig.store.acknowledgeLocally("Flashlight on, sir.")
        await settleVoiceTasks()

        XCTAssertEqual(rig.synthesizer.spoken, ["Flashlight on, sir."])
        XCTAssertTrue(rig.output.played.isEmpty, "no round trip for a sub-100 ms ack")
        XCTAssertEqual(rig.store.assistantText, "Flashlight on, sir.")
        XCTAssertEqual(rig.store.spokenWords, rig.store.reply.totalWords)
    }

    /// No phone synthesizer (a silenced/failed AVSpeechSynthesizer) → fall back
    /// to the JARVIS voice rather than acknowledging nothing.
    func testALocalAckFallsBackToTheJarvisVoice() async {
        let rig = makeRig()
        rig.synthesizer.speakSucceeds = false
        await startListening(rig)

        await rig.store.acknowledgeLocally("Flashlight on, sir.")
        await settleVoiceTasks()
        await rig.store.audio.settle()

        XCTAssertTrue(rig.synthesizer.spoken.isEmpty)
        XCTAssertEqual(rig.output.played.count, 1)
        XCTAssertEqual(rig.store.assistantText, "Flashlight on, sir.")
    }
}

/// A transport that lets a test run code at the exact moment a request goes out —
/// the only way to land a barge-in *inside* the concurrent TTS task group.
final class VoiceRequestHook: APITransport, @unchecked Sendable {
    private let inner: MockTransport
    var onRequest: (@Sendable (String) async -> Void)?

    init(inner: MockTransport) { self.inner = inner }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await onRequest?(request.url?.path ?? "")
        return try await inner.send(request)
    }

    func stream(_ request: URLRequest) async throws
        -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse) {
        await onRequest?(request.url?.path ?? "")
        return try await inner.stream(request)
    }
}

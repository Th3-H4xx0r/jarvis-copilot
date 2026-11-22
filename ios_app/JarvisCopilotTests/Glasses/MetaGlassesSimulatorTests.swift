import XCTest
@testable import JarvisCopilot

/// A spy `MetaVoiceTurnController` so a glasses turn can be asserted without a live `VoiceStore`
/// (no real audio/engine). It mimics what `VoiceStore` does: it adopts the external input and,
/// on `beginExternalTurn`, "starts" it and drains frames — so streamed glasses PCM is observable.
@MainActor
final class FakeVoiceTurnController: MetaVoiceTurnController {
    private(set) var useExternalInputCalls = 0
    private(set) var beginTurnCalls = 0
    private(set) var cleared = 0
    private(set) weak var boundInput: AudioInput?
    private(set) var capturedAudio: [Data] = []
    /// What `snapshot()` reports before a turn begins (set non-idle to fake a busy voice chat).
    var current = MetaVoiceSnapshot.idle
    /// Played one per `snapshot()` call once a turn has begun; the last one sticks.
    var script: [MetaVoiceSnapshot] = []

    func useExternalInput(_ input: AudioInput?, isCurrent: @escaping () -> Bool) async {
        useExternalInputCalls += 1
        guard isCurrent() else { return }
        if let input {
            boundInput = input
            input.onFrame = { [weak self] chunk in self?.capturedAudio.append(chunk) }
        } else {
            cleared += 1
            boundInput?.onFrame = nil
            boundInput = nil
        }
    }

    func beginExternalTurn(isCurrent: @escaping () -> Bool) async {
        beginTurnCalls += 1
        guard isCurrent() else { return }
        try? await boundInput?.start(sampleRate: 16_000)
    }

    func snapshot() -> MetaVoiceSnapshot {
        if beginTurnCalls > 0, !script.isEmpty { current = script.removeFirst() }
        return current
    }
}

/// Drives `MetaGlassesDevice` + `MetaGlassesSession` through `SimulatedGlassesTransport` with no
/// hardware: a full wake→turn→reply→close cycle, a photo capability returning {base64,mime}, and
/// touch events mapping to actions.
@MainActor
final class MetaGlassesSimulatorTests: XCTestCase {

    private func makeSession() -> (MetaGlassesSession, SimulatedGlassesTransport, FakeVoiceTurnController) {
        let transport = SimulatedGlassesTransport()
        let voice = FakeVoiceTurnController()
        let session = MetaGlassesSession(transport: transport, voice: voice)
        return (session, transport, voice)
    }

    /// Let the transport's buffered events drain through the session pump.
    private func settle() async throws {
        for _ in 0..<5 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(25))
        for _ in 0..<5 { await Task.yield() }
    }

    func testStartBringsLinkThroughTrustToReady() async throws {
        let (session, transport, _) = makeSession()
        try await session.start()
        XCTAssertEqual(session.state, .ready)
        XCTAssertTrue(session.isReady)
        XCTAssertTrue(session.stateHistory.contains(.trusted), "connected → trusted(simulated) → ready")
        XCTAssertTrue(transport.sentFrames.contains(.enableWakeWord), "wake word armed once ready")
    }

    func testFullWakeTurnReplyCloseCycle() async throws {
        let (session, transport, voice) = makeSession()
        try await session.start()

        // Wake → the session must request a VoiceStore external turn with a glasses-only input.
        transport.scriptWake()
        try await settle()
        XCTAssertTrue(session.turnActive)
        XCTAssertEqual(session.wakeCount, 1)
        XCTAssertEqual(voice.useExternalInputCalls, 1)
        XCTAssertEqual(voice.beginTurnCalls, 1)
        XCTAssertTrue(voice.boundInput === session.audioInput, "phone mic is never substituted")

        // Spoken prompt → transcript echoed to the lens, PCM streamed into the voice input.
        let pcm = Data([1, 2, 3, 4, 5, 6])
        transport.scriptSpokenPrompt(transcript: "what am I looking at", pcm: pcm)
        try await settle()
        XCTAssertEqual(session.lastUserTranscript, "what am I looking at")
        XCTAssertTrue(transport.sentFrames.contains(.showTranscript(text: "what am I looking at", isFinal: true)))
        XCTAssertEqual(voice.capturedAudio, [pcm], "glasses PCM reached the voice engine")

        // Canned reply → rendered back to the lens, then the turn closes.
        transport.scriptCannedReply("A laptop on a desk.")
        try await settle()
        XCTAssertEqual(session.lastAnswer, "A laptop on a desk.")
        XCTAssertTrue(transport.sentFrames.contains(.showAnswer(text: "A laptop on a desk.", isFinal: true)))
        XCTAssertTrue(transport.sentFrames.contains(.closeAssistant), "turn closed")
        XCTAssertFalse(session.turnActive)
        XCTAssertGreaterThanOrEqual(voice.cleared, 1, "external input released on close")
    }

    func testPhotoCapabilityReturnsBase64AndMime() async throws {
        let transport = SimulatedGlassesTransport()
        let device = MetaGlassesDevice(transport: transport, voice: FakeVoiceTurnController(),
                                       defaults: isolatedDefaults())
        try await device.session.start()

        // Without confirm the shutter refuses (plan §6.2 trust rule).
        do {
            _ = try await device.invoke("meta_glasses_photo", args: ["question": "what is this"])
            XCTFail("photo should require confirm=true")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("confirm=true"), error.localizedDescription)
        }

        let result = try await device.invoke("meta_glasses_photo", args: ["question": "what is this", "confirm": true])
        let base64 = try XCTUnwrap(result["base64"] as? String)
        XCTAssertEqual(result["mime"] as? String, "image/jpeg")
        XCTAssertEqual(result["question"] as? String, "what is this")
        let decoded = try XCTUnwrap(Data(base64Encoded: base64))
        XCTAssertFalse(decoded.isEmpty)
        XCTAssertEqual(Array(decoded.prefix(2)), [0xFF, 0xD8], "JPEG SOI marker")
    }

    func testTouchGesturesMapToActions() async throws {
        // Pure mapping (plan §6.5).
        XCTAssertEqual(MetaTouchBinding.defaultAction(for: .doubleTap), .startAssistant)
        XCTAssertEqual(MetaTouchBinding.defaultAction(for: .tripleTap), .endAssistant)
        XCTAssertEqual(MetaTouchBinding.defaultAction(for: .capture), .capturePhoto)
        XCTAssertEqual(MetaTouchBinding.defaultAction(for: .swipeForward), .nextTrack)

        let (session, transport, voice) = makeSession()
        try await session.start()

        // A double tap starts a turn.
        transport.scriptTouch(.doubleTap)
        try await settle()
        XCTAssertEqual(session.lastTouchGesture, .doubleTap)
        XCTAssertEqual(session.lastTouchAction, .startAssistant)
        XCTAssertTrue(session.turnActive)
        XCTAssertEqual(voice.beginTurnCalls, 1)

        // A triple tap ends it.
        transport.scriptTouch(.tripleTap)
        try await settle()
        XCTAssertEqual(session.lastTouchAction, .endAssistant)
        XCTAssertFalse(session.turnActive)

        // A capture gesture requests a still from the glasses.
        transport.scriptTouch(.capture)
        try await settle()
        XCTAssertEqual(session.lastTouchAction, .capturePhoto)
        XCTAssertTrue(transport.sentFrames.contains { if case .capturePhoto = $0 { return true }; return false })
    }
}

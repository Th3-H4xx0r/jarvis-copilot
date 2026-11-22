import Foundation

/// Drives one Meta glasses session on top of a `GlassesTransport`: brings the link up
/// (connected → trusted(simulated) → ready), fans inbound events into the wake→turn lifecycle,
/// streams glasses mic PCM into the voice engine, renders replies back to the lens, captures
/// photos, and maps touch gestures to actions (plan §6.1/§6.2/§6.3/§6.5).
///
/// Transport-agnostic and voice-engine-agnostic: real BLE+AirShield is the `MetaGlassesTransport`
/// skeleton, the in-memory `SimulatedGlassesTransport` exercises every path here, and `VoiceStore`
/// sits behind `MetaVoiceTurnController`. The device is never registered in production, so none of
/// this runs on a user's phone yet.
@MainActor
final class MetaGlassesSession {
    enum State: String, Equatable, Sendable {
        case idle, connecting, connected, trusted, ready, closed, failed
    }

    let transport: GlassesTransport
    let voice: MetaVoiceTurnController
    let audioInput: MetaGlassesAudioInput

    private(set) var state: State = .idle {
        didSet { if oldValue != state { stateHistory.append(state) } }
    }
    /// Every distinct state the session has passed through, for the UI and tests.
    private(set) var stateHistory: [State] = []
    private(set) var turnActive = false
    private(set) var wakeCount = 0
    private(set) var lastUserTranscript: String?
    private(set) var lastAnswer: String?
    private(set) var lastTouchGesture: MetaTouchGesture?
    private(set) var lastTouchAction: MetaTouchAction?

    /// Gesture→action bindings (plan §6.5); starts at the documented defaults.
    var touchBindings: [MetaTouchGesture: MetaTouchAction] = MetaTouchBinding.defaults

    /// Bumped on each turn so a stale async step no-ops (the INMO generation guard).
    private var generation = 0
    private var pump: Task<Void, Never>?
    private var photoWaiter: ((Result<Data, Error>) -> Void)?

    var isReady: Bool { state == .ready }

    init(transport: GlassesTransport,
         voice: MetaVoiceTurnController = VoiceStoreTurnController.shared,
         audioInput: MetaGlassesAudioInput? = nil) {
        self.transport = transport
        self.voice = voice
        // Resolve the default here, not as a default argument: constructing a @MainActor type
        // in a default-argument expression is a nonisolated call and fails to compile.
        self.audioInput = audioInput ?? MetaGlassesAudioInput()
    }

    // MARK: Lifecycle

    /// Bring the link up and arm the wake word. The trust step is hardware-gated on the real
    /// transport (AirShield owner trust, plan §5.2); here the session records the
    /// connected → trusted → ready progression and the transport proves (or simulates) it.
    func start() async throws {
        guard state == .idle || state == .closed || state == .failed else { return }
        state = .connecting
        startPump()
        do {
            try await transport.connect()
        } catch {
            state = .failed
            throw error
        }
        state = .connected
        state = .trusted            // real: AirShield owner-trust; simulator: already trusted
        try await transport.send(.enableWakeWord)
        state = .ready
    }

    /// Close the session: end any live turn, drop the link, stop the pump. Idempotent.
    func stop() async {
        await endTurn()
        await transport.disconnect()
        pump?.cancel()
        pump = nil
        failPhotoWaiter(MetaGlassesError.notReady)
        state = .closed
    }

    private func startPump() {
        guard pump == nil else { return }
        let stream = transport.inbound
        pump = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    // MARK: Inbound handling

    private func handle(_ event: GlassesInboundEvent) async {
        switch event {
        case .linkState(let link):
            apply(link)
        case .wake:
            await startTurn()
        case .userTranscript(let text, let isFinal):
            await handleTranscript(text, isFinal: isFinal)
        case .userAudio(let pcm):
            if turnActive { audioInput.receive(pcm) }
        case .assistantAnswer(let text, let isFinal):
            await renderAnswer(text, isFinal: isFinal)
        case .photo(let jpeg):
            photoWaiter?(.success(jpeg))
        case .touch(let gesture):
            await handleTouch(gesture)
        }
    }

    private func apply(_ link: GlassesLinkState) {
        switch link {
        case .disconnected: if state != .closed { state = .failed }
        case .connecting: state = .connecting
        case .connected: state = .connected
        case .trusted: state = .trusted
        case .ready: state = .ready
        case .failed: state = .failed
        }
    }

    // MARK: Turn lifecycle (wake → turn → reply → close)

    private func startTurn() async {
        wakeCount += 1
        generation += 1
        let epoch = generation
        turnActive = true
        // Hand the glasses-only input to the voice engine and open a realtime turn — the INMO
        // sequence (plan §6.3). The isCurrent guard makes a stale turn no-op.
        await voice.useExternalInput(audioInput, isCurrent: { [weak self] in self?.generation == epoch })
        guard generation == epoch else { return }
        await voice.beginExternalTurn(isCurrent: { [weak self] in self?.generation == epoch })
    }

    private func handleTranscript(_ text: String, isFinal: Bool) async {
        guard turnActive else { return }
        lastUserTranscript = text
        // Echo the on-device transcript back to the lens, as InmoAIChannel does.
        try? await transport.send(.showTranscript(text: text, isFinal: isFinal))
    }

    private func renderAnswer(_ text: String, isFinal: Bool) async {
        lastAnswer = text
        try? await transport.send(.showAnswer(text: text, isFinal: isFinal))
        try? await transport.send(.setSpeaking(true))
        if isFinal {
            try? await transport.send(.setSpeaking(false))
            await endTurn()
        }
    }

    /// End the current turn: release the external input and tell the lens to close the assistant
    /// surface. Idempotent.
    func endTurn() async {
        guard turnActive else { return }
        generation += 1
        let epoch = generation
        turnActive = false
        await voice.useExternalInput(nil, isCurrent: { [weak self] in self?.generation == epoch })
        await audioInput.stop()
        guard generation == epoch else { return }
        try? await transport.send(.closeAssistant)
    }

    // MARK: Photo capture (plan §6.2)

    /// Capture a still. Requests the frame and awaits the next inbound `.photo`.
    func capturePhoto(question: String?, timeout: Duration = .seconds(5)) async throws -> (data: Data, mime: String) {
        guard isReady else { throw MetaGlassesError.notReady }
        guard photoWaiter == nil else { throw MetaGlassesError.busy("a photo capture is already in flight") }
        let data: Data = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            var resumed = false
            let finish: (Result<Data, Error>) -> Void = { [weak self] result in
                guard !resumed else { return }
                resumed = true
                self?.photoWaiter = nil
                cont.resume(with: result)
            }
            photoWaiter = finish
            Task { @MainActor in
                do { try await self.transport.send(.capturePhoto(question: question)) }
                catch { finish(.failure(error)) }
            }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                finish(.failure(MetaGlassesError.timedOut("photo capture")))
            }
        }
        return (data, "image/jpeg")
    }

    private func failPhotoWaiter(_ error: Error) {
        photoWaiter?(.failure(error))
    }

    // MARK: Touch (plan §6.5)

    func handleTouch(_ gesture: MetaTouchGesture) async {
        lastTouchGesture = gesture
        let action = touchBindings[gesture] ?? MetaTouchBinding.defaultAction(for: gesture)
        lastTouchAction = action
        switch action {
        case .startAssistant:
            await startTurn()
        case .endAssistant:
            await endTurn()
        case .capturePhoto:
            Task { @MainActor in _ = try? await self.capturePhoto(question: nil) }
        case .nextTrack, .previousTrack, .none:
            break   // music stays on A2DP; these are recorded for the UI/bridge to act on
        }
    }

    // MARK: Snapshot

    func snapshot() -> [String: Any] {
        [
            "state": state.rawValue,
            "connected": isReady,
            "turn_active": turnActive,
            "wake_count": wakeCount,
        ]
    }
}

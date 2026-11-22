import Foundation

/// What a glasses turn did, for the page and tests: final transcript, final answer, speaking
/// on/off, the assistant closed, and how the turn ended.
enum MetaSessionEvent: Equatable, Sendable {
    case heard(String)
    case answer(String)
    case speaking(Bool)
    case closed
    case ended(MetaVoiceRelay.Outcome)
}

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

    /// Every turn milestone, as it happens (the sim page's log).
    var onEvent: ((MetaSessionEvent) -> Void)?
    /// How often the voice engine is read during a turn (InmoAIChannel's cadence).
    var pollInterval: Duration = .milliseconds(100)
    /// A turn that hasn't finished by then is ended as failed.
    var turnTimeout: Duration = .seconds(60)
    /// A voice engine that never leaves idle (mic refused, engine down) fails this fast.
    var startTimeout: Duration = .seconds(10)
    /// How the last turn ended.
    private(set) var lastOutcome: MetaVoiceRelay.Outcome?
    private var watch: Task<Void, Never>?
    private var videoWaiter: ((Result<MetaClip, Error>) -> Void)?
    /// The newest live-stream frame (JPEG) while streaming.
    private(set) var latestLiveFrame: Data?
    /// A Jarvis action bound to a touch gesture, run in addition to the glasses' own default.
    var onTouchBinding: ((MetaTouchGesture) -> Void)?
    /// What the glasses report about themselves (battery, heat, storage, worn…).
    var hardware: MetaHardwareState? { transport.hardware }

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
        await endTurn(outcome: .failed("Stopped"))
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
        case .video(let clip):
            videoWaiter?(.success(clip))
        case .liveFrame(let jpeg):
            latestLiveFrame = jpeg
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
        guard generation == epoch, turnActive else { return }
        startWatch(epoch: epoch)
    }

    /// Mirror the voice engine's turn back to the glasses until it finishes, fails, or times out.
    private func startWatch(epoch: Int) {
        watch?.cancel()
        let baseline = voice.snapshot()
        watch = Task { [weak self] in
            var relay = MetaVoiceRelay(baseline: baseline)
            let clock = ContinuousClock()
            let began = clock.now
            while !Task.isCancelled {
                guard let self, self.generation == epoch, self.turnActive else { return }
                let step = relay.step(self.voice.snapshot())
                for frame in step.frames {
                    guard self.generation == epoch else { return }
                    try? await self.transport.send(frame)
                    self.report(frame)
                }
                var outcome = step.outcome
                if outcome == .running {
                    let elapsed = clock.now - began
                    if !relay.seenActive, elapsed > self.startTimeout {
                        outcome = .failed("Jarvis voice didn't start (is the microphone allowed?)")
                    } else if elapsed > self.turnTimeout {
                        outcome = .failed("Timed out waiting for Jarvis")
                    }
                }
                if outcome != .running {
                    guard self.generation == epoch else { return }
                    await self.endTurn(outcome: outcome)
                    return
                }
                try? await Task.sleep(for: self.pollInterval)
            }
        }
    }

    private func report(_ frame: GlassesFrame) {
        switch frame {
        case .showTranscript(let text, true):
            lastUserTranscript = text
            onEvent?(.heard(text))
        case .showAnswer(let text, true):
            lastAnswer = text
            onEvent?(.answer(text))
        case .setSpeaking(let on):
            onEvent?(.speaking(on))
        default:
            break
        }
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
    /// surface. Idempotent. `outcome` is what `.ended` reports (a touch or canned reply = finished).
    func endTurn(outcome: MetaVoiceRelay.Outcome = .finished) async {
        guard turnActive else { return }
        generation += 1
        let epoch = generation
        turnActive = false
        watch?.cancel()
        watch = nil
        lastOutcome = outcome
        await voice.useExternalInput(nil, isCurrent: { [weak self] in self?.generation == epoch })
        await audioInput.stop()
        if generation == epoch {
            try? await transport.send(.closeAssistant)
            onEvent?(.closed)
        }
        onEvent?(.ended(outcome))
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
        videoWaiter?(.failure(error))
    }

    // MARK: Video, live, speaker (Gen 2 camera + open-ear speakers)

    /// Record a clip of up to `seconds` (the glasses cap it at their clip-length setting) and
    /// wait for it. A clip the glasses cut short still returns, with `stopReason` set.
    func recordVideo(seconds: Int) async throws -> MetaClip {
        guard isReady else { throw MetaGlassesError.notReady }
        guard videoWaiter == nil else { throw MetaGlassesError.busy("a recording is already in progress") }
        try await transport.send(.startVideo(seconds: seconds))
        let limit = Duration.seconds(Double(seconds) + 20)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<MetaClip, Error>) in
            var resumed = false
            let finish: (Result<MetaClip, Error>) -> Void = { [weak self] result in
                guard !resumed else { return }
                resumed = true
                self?.videoWaiter = nil
                cont.resume(with: result)
            }
            videoWaiter = finish
            Task { @MainActor in
                try? await Task.sleep(for: limit)
                finish(.failure(MetaGlassesError.timedOut("video recording")))
            }
        }
    }

    func stopVideo() async throws {
        guard isReady else { throw MetaGlassesError.notReady }
        try await transport.send(.stopVideo)
    }

    func startLive() async throws {
        guard isReady else { throw MetaGlassesError.notReady }
        try await transport.send(.startLiveStream)
    }

    func stopLive() async throws {
        latestLiveFrame = nil
        guard isReady else { return }
        try await transport.send(.stopLiveStream)
    }

    func speak(_ text: String) async throws {
        guard isReady else { throw MetaGlassesError.notReady }
        try await transport.send(.speak(text: text))
    }

    /// Enrol the custom wake phrase on the glasses (they build the detector themselves).
    func enrolWakeWord(phrase: String, samples: [Data]) async throws {
        guard isReady else { throw MetaGlassesError.notReady }
        try await transport.send(.enrolWakeWord(phrase: phrase, samples: samples))
    }

    func setVolume(_ level: Int) async throws {
        guard isReady else { throw MetaGlassesError.notReady }
        try await transport.send(.setVolume(level))
    }

    // MARK: Touch (plan §6.5)

    /// A gesture the glasses reported. They already did their own default (play/pause, tracks,
    /// volume, a capture — those can't be suppressed); here the assistant gesture starts or ends a
    /// Jarvis turn, and any Jarvis action bound to the gesture runs too.
    func handleTouch(_ gesture: MetaTouchGesture) async {
        lastTouchGesture = gesture
        let action = touchBindings[gesture] ?? MetaTouchBinding.defaultAction(for: gesture)
        lastTouchAction = action
        switch action {
        case .startAssistant:
            if turnActive { await endTurn() } else { await startTurn() }
        case .endAssistant:
            await endTurn()
        case .capturePhoto, .nextTrack, .previousTrack, .playPause, .volumeUp, .volumeDown, .none:
            break   // done on the glasses
        }
        onTouchBinding?(gesture)
    }

    // MARK: Snapshot

    func snapshot() -> [String: Any] {
        [
            "state": state.rawValue,
            "connected": isReady,
            "turn_active": turnActive,
            "wake_count": wakeCount,
            "streaming_frame": latestLiveFrame != nil,
        ]
    }
}

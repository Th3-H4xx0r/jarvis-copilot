import Foundation

/// Runs one simulated glasses turn through the REAL Jarvis voice engine, for the Meta glasses
/// page: the phone voices the prompt into glasses-mic audio, software glasses (`SimulatedGlassesTransport`)
/// say "Hey Jarvis" and stream it, `MetaGlassesSession` opens a `VoiceStore` external turn, Jarvis
/// answers out loud, and `MetaVoiceRelay` mirrors the turn back to the glasses — the path real
/// glasses will take. The rows are what the glasses received.
///
/// Its own transport + session, never `MetaGlassesDevice.shared` and never registered with
/// `DeviceRegistry`, so the agent sees no `meta_*` tools and no Bluetooth starts.
@MainActor
final class MetaGlassesSimRunner: ObservableObject {
    struct Row: Identifiable, Equatable {
        let id: Int
        /// Since Run was tapped.
        let at: Duration
        let symbol: String
        let title: String
        let detail: String?
    }

    enum Phase: Equatable {
        case idle, running, done
        case failed(String)
    }

    static let defaultPrompt = "What's seven times eight?"
    static let busyMessage = "Finish your voice chat first"

    @Published private(set) var rows: [Row] = []
    @Published private(set) var phase: Phase = .idle
    /// From the wake to Jarvis starting to speak.
    @Published private(set) var wakeToAnswer: Duration?
    @Published var prompt = MetaGlassesSimRunner.defaultPrompt

    var isRunning: Bool { phase == .running }

    private let voice: MetaVoiceTurnController
    private let speech: MetaPromptSpeaking
    private let frameInterval: Duration
    private let sessionTuning: ((MetaGlassesSession) -> Void)?
    /// The live simulated glasses to drive (the hub's); nil = a private pair (tests).
    private let target: (() -> (MetaGlassesSession, SimulatedGlassesTransport)?)?
    private var usingTarget = false

    private var transport: SimulatedGlassesTransport?
    private var session: MetaGlassesSession?
    private var ended: AsyncStream<MetaVoiceRelay.Outcome>.Continuation?
    private var stopping = false
    private var answered = false
    private let clock = ContinuousClock()
    private var began = ContinuousClock.now
    private var wakeAt: ContinuousClock.Instant?

    init(voice: MetaVoiceTurnController? = nil,
         speech: MetaPromptSpeaking? = nil,
         frameInterval: Duration = .milliseconds(40),
         sessionTuning: ((MetaGlassesSession) -> Void)? = nil,
         target: (() -> (MetaGlassesSession, SimulatedGlassesTransport)?)? = nil) {
        self.target = target
        // Resolved here, not as default arguments: building @MainActor types there is a
        // nonisolated call (see MetaGlassesSession.init).
        self.voice = voice ?? VoiceStoreTurnController.shared
        self.speech = speech ?? MetaPromptVoice()
        self.frameInterval = frameInterval
        self.sessionTuning = sessionTuning
    }

    /// One simulated turn from the typed prompt (voiced into glasses-mic audio).
    func run() async {
        guard phase != .running else { return }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { phase = .failed("Type something for the glasses to hear"); return }
        guard begin() else { return }
        let pcm: Data
        do { pcm = try await speech.pcm16k(for: text) } catch {
            phase = .failed("Couldn't voice the prompt: \(error.localizedDescription)")
            return
        }
        guard !stopping else { return finishStopped() }
        guard !pcm.isEmpty else { phase = .failed("Couldn't voice the prompt"); return }
        await runTurn(pcm: pcm, said: "“\(text)”")
    }

    /// One simulated turn from your own voice (hold to talk), already 16 kHz PCM.
    func run(recorded pcm: Data) async {
        guard phase != .running else { return }
        guard pcm.count >= 3_200 else { phase = .failed("Hold to talk, then speak — that was too short"); return }
        guard begin() else { return }
        await runTurn(pcm: pcm, said: "Your voice · \(String(format: "%.1f", Double(pcm.count) / 32_000)) s")
    }

    /// Refuses while a voice chat is running; resets the run state.
    private func begin() -> Bool {
        guard voice.snapshot().state == .idle else { phase = .failed(Self.busyMessage); return false }
        rows = []
        wakeToAnswer = nil
        wakeAt = nil
        stopping = false
        answered = false
        began = clock.now
        phase = .running
        return true
    }

    private func runTurn(pcm: Data, said: String) async {
        let session: MetaGlassesSession
        let transport: SimulatedGlassesTransport
        if let live = target?() {
            (session, transport) = live
            usingTarget = true
        } else {
            transport = SimulatedGlassesTransport()
            session = MetaGlassesSession(transport: transport, voice: voice)
            usingTarget = false
        }
        sessionTuning?(session)
        let (stream, continuation) = AsyncStream<MetaVoiceRelay.Outcome>.makeStream()
        self.transport = transport
        self.session = session
        ended = continuation
        session.onEvent = { [weak self] event in self?.record(event) }

        if !usingTarget {
            do { try await session.start() } catch {
                cleanUp()
                phase = .failed("Simulated link failed: \(error.localizedDescription)")
                return
            }
        } else if !session.isReady {
            cleanUp()
            phase = .failed(transport.hw.unreachableReason ?? "The simulated glasses aren't connected")
            return
        }
        add("link", "Link ready", "Simulated glasses")
        guard !stopping else { await tearDown(session, transport); return finishStopped() }

        if usingTarget, let reason = transport.hw.voiceRefusal() {
            transport.wake()     // logs the refusal in the feed
            cleanUp()
            phase = .failed(reason)
            return
        }
        wakeAt = clock.now
        if usingTarget { transport.wake() } else { transport.scriptWake() }
        add("waveform", "Wake", "“Hey Jarvis”")
        transport.streamSpokenAudio(pcm, frameInterval: frameInterval)
        add("mic", "Glasses mic", said)

        var outcome = MetaVoiceRelay.Outcome.failed("Stopped")
        for await value in stream { outcome = value; break }
        await tearDown(session, transport)

        if stopping { return finishStopped() }
        switch outcome {
        case .finished where answered: phase = .done
        case .finished: phase = .failed("Jarvis didn't answer — try again")
        case .failed(let why): phase = .failed(why)
        case .running: phase = .failed("Jarvis didn't finish")
        }
    }

    /// End a run early: closes the turn, releases the glasses input, stops the mic stream.
    func stop() async {
        guard phase == .running else { return }
        stopping = true
        transport?.stopStreaming()
        ended?.yield(.failed("Stopped"))
        ended?.finish()
        ended = nil
        if usingTarget { await session?.endTurn(outcome: .failed("Stopped")) } else { await session?.stop() }
    }

    // MARK: Internals

    private func record(_ event: MetaSessionEvent) {
        switch event {
        case .heard(let text):
            // The engine refines a final transcript ("What's 7 times 8?" → …): update, don't repeat.
            if let last = rows.last, last.title == "Heard" {
                rows[rows.count - 1] = Row(id: last.id, at: last.at, symbol: last.symbol, title: last.title, detail: "“\(text)”")
            } else {
                add("ear", "Heard", "“\(text)”")
            }
        case .answer(let text):
            answered = true
            add("text.bubble", "Jarvis", text)
        case .speaking(true):
            if wakeToAnswer == nil, let wakeAt { wakeToAnswer = clock.now - wakeAt }
            add("speaker.wave.2", "Speaking", nil)
        case .speaking(false):
            break
        case .closed:
            add("checkmark.circle", "Assistant closed", nil)
        case .ended(let outcome):
            if case .failed(let why) = outcome, !stopping { add("exclamationmark.triangle", "Ended", why) }
            ended?.yield(outcome)
            ended?.finish()
            ended = nil
        }
    }

    private func add(_ symbol: String, _ title: String, _ detail: String?) {
        rows.append(Row(id: rows.count, at: clock.now - began, symbol: symbol, title: title, detail: detail))
    }

    private func tearDown(_ session: MetaGlassesSession, _ transport: SimulatedGlassesTransport) async {
        transport.stopStreaming()
        if usingTarget {
            if session.turnActive { await session.endTurn(outcome: .failed("Stopped")) }
        } else {
            await session.stop()
        }
        cleanUp()
    }

    private func cleanUp() {
        ended?.finish()
        ended = nil
        session?.onEvent = nil
        session = nil
        transport = nil
    }

    private func finishStopped() {
        add("stop.circle", "Stopped", nil)
        phase = .idle
    }
}

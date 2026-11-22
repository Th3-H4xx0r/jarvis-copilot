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
         sessionTuning: ((MetaGlassesSession) -> Void)? = nil) {
        // Resolved here, not as default arguments: building @MainActor types there is a
        // nonisolated call (see MetaGlassesSession.init).
        self.voice = voice ?? VoiceStoreTurnController.shared
        self.speech = speech ?? MetaPromptVoice()
        self.frameInterval = frameInterval
        self.sessionTuning = sessionTuning
    }

    /// One simulated turn, start to finish. Refuses while a voice chat is running.
    func run() async {
        guard phase != .running else { return }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { phase = .failed("Type something for the glasses to hear"); return }
        guard voice.snapshot().state == .idle else { phase = .failed(Self.busyMessage); return }

        rows = []
        wakeToAnswer = nil
        wakeAt = nil
        stopping = false
        answered = false
        began = clock.now
        phase = .running

        let pcm: Data
        do { pcm = try await speech.pcm16k(for: text) } catch {
            phase = .failed("Couldn't voice the prompt: \(error.localizedDescription)")
            return
        }
        guard !stopping else { return finishStopped() }
        guard !pcm.isEmpty else { phase = .failed("Couldn't voice the prompt"); return }

        let transport = SimulatedGlassesTransport()
        let session = MetaGlassesSession(transport: transport, voice: voice)
        sessionTuning?(session)
        let (stream, continuation) = AsyncStream<MetaVoiceRelay.Outcome>.makeStream()
        self.transport = transport
        self.session = session
        ended = continuation
        session.onEvent = { [weak self] event in self?.record(event) }

        do { try await session.start() } catch {
            cleanUp()
            phase = .failed("Simulated link failed: \(error.localizedDescription)")
            return
        }
        add("link", "Link ready", "Simulated glasses")
        guard !stopping else { await tearDown(session, transport); return finishStopped() }

        wakeAt = clock.now
        transport.scriptWake()
        add("waveform", "Wake", "“Hey Jarvis”")
        transport.streamSpokenAudio(pcm, frameInterval: frameInterval)
        add("mic", "Glasses mic", "“\(text)”")

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
        await session?.stop()
    }

    // MARK: Internals

    private func record(_ event: MetaSessionEvent) {
        switch event {
        case .heard(let text):
            add("ear", "Heard", "“\(text)”")
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
        await session.stop()
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

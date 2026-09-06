import Foundation
import Observation

/// Drives the voice screen. Port of `voice/voice_controller.dart`.
///
/// Owns the mic, the FSM (`VoiceTurnMachine`), the playback queue
/// (`AudioQueue`), the reply + karaoke model (`VoiceReply`) and both
/// conversation transports:
///
///  • **Quality** — push-to-talk: record a clip, POST `/api/voice/quality-turn`,
///    stream back transcript + text + MP3 segments.
///  • **Realtime** — continuous: stream 16 kHz PCM over `/api/voice/s2s/ws` with
///    client-side VAD + barge-in, play 24 kHz PCM replies.
///
/// Single session for the app: the mic, the audio session and the socket are all
/// process-wide, so a second store would fight the first. Views take `shared`.
@MainActor
@Observable
final class VoiceStore {

    /// `launch:` is what makes the Siri / Control-Center / wake-word latch reach
    /// the store — `consumeVoiceLaunch()` takes it and starts a turn. `local:` is
    /// the on-device lane (`VoiceLocalLane`); with the on-device tier off it
    /// escalates every turn, i.e. today's server-only behaviour.
    static let shared = VoiceStore(launch: AppRouter.shared, local: VoiceLocalLane())

    // MARK: - Tuning

    static let micRate = 16000
    /// After playback drains we wait this long for a trailing segment before
    /// resuming listening — replies arrive as several segments with gaps, so
    /// resuming instantly made the orb flip listening↔speaking mid-reply.
    static let resumeGraceMs = 1600
    /// While "thinking", reassure the user if the server is slow and hasn't
    /// streamed anything yet. Without this a slow turn looks like a frozen app.
    static let thinkingWatchdogMs = 18000
    /// Barge-in threshold (normalized 0..1), mirroring voice.js.
    static let bargeInThreshold = 0.40
    /// Sustained-speech barge-in: a single frame over 0.40 almost never happens
    /// for normal speech once echo cancellation has attenuated the mic, so also
    /// trip on a run of moderately loud frames (~200 ms) — the reply's own echo
    /// leak stays short and quiet, real speech doesn't.
    static let bargeInSustainAmp = 0.18
    static let bargeInSustainFrames = 4
    /// A backgrounded realtime session sitting in `listening` with nobody talking
    /// is the worst-case battery drain (mic + audio session + WS all live). End it
    /// after this long — but only when genuinely idle.
    static let bgIdleTimeoutMs = 120_000
    /// Below this a push-to-talk clip isn't worth sending.
    static let minQualityBytes = 1000
    static let devicesRefreshSeconds = 15.0
    /// How long `end_turn` waits for the on-device recognizer's FINAL transcript.
    /// SFSpeech's final callback is not guaranteed (a dropped session, memory
    /// pressure): without a deadline the turn sat in `thinking` forever and the
    /// `stop()` continuation leaked. Past this we simply let the server do STT.
    static let sttFinalTimeoutMs = 2000
    /// Shown when the reply is on screen but the JARVIS voice couldn't speak it.
    static let ttsUnavailableNotice = "Voice unavailable — showing the text."
    /// Shown when a message could not be handed to the realtime socket at all.
    static let connectionLostNotice = "Lost the voice connection — tap to try again."
    /// One diagnostics line per this many outbound mic frames. At ~43 ms a frame
    /// that is a line every ~2 s, so a single utterance can't evict the whole
    /// ring buffer.
    static let micLogBatch = 50

    // MARK: - Dependencies

    // Internal, not private: `VoiceStoreTransport.swift` is the other half of
    // this store and Swift's `private` is file-scoped.
    let voice: VoiceAPI
    let settings: VoiceSettings
    let input: AudioInput
    let recognizer: SpeechRecognizing
    let synthesizer: VoiceSynthesizing
    let audioSession: AudioSessionControlling
    let clock: VoiceClock
    private let launch: VoiceLaunchRequesting?
    /// The on-device answer path. nil = every turn goes to the server.
    let local: VoiceLocalLane?
    let audio: AudioQueue
    let session: VoiceSession
    let liveActivity: VoiceLiveActivityThrottle

    // MARK: - Observable state

    // Internal rather than private only so `VoiceStoreTransport.swift` (the
    // other half of this store) can reach them. Nothing outside the store
    // mutates either — views read the projections below.
    var machine: VoiceTurnMachine
    var reply = VoiceReply()

    var state: VoiceState { machine.state }
    var mode: VoiceMode { machine.mode }
    /// 0..1 mic peak while listening, playback envelope while speaking.
    var amplitude: Double = 0
    var userTranscript = ""
    /// Plain (markdown-stripped) reply, joined segments.
    var assistantText: String { reply.text }
    /// Leading words of `assistantText` already spoken — the view colours these
    /// white and the rest grey.
    var spokenWords: Int { reply.spokenWords }
    /// Segment-level view of the reply, for a per-segment renderer.
    var replySegments: [VoiceSegment] { reply.segments }
    /// e.g. "Running search_web".
    var toolStatus: String?
    var error: String?
    var muted = false
    var captureReady = false
    var audioInterrupted = false
    var engines = VoiceEngineList()
    /// Icon kinds for the Live Activity devices strip.
    var deviceKinds: [String] = []

    /// The last ``VoiceDiagnostics/capacity`` voice events — state transitions,
    /// frames in and out (type + size, never content), and every error. The
    /// Voice screen shows these behind a long-press; DEBUG builds also mirror
    /// them to stderr so `devicectl … --console` shows a live turn.
    var diagnostics: [String] = []

    var isActive: Bool { machine.state.isActive }
    var isPlaying: Bool { audio.isBusy }
    var selectedEngine: String? { settings.engine }
    var selectedVoice: String? { settings.voice }
    var wakeWordEnabled: Bool { settings.wakeWordEnabled }

    // MARK: - Internal turn state

    var sessionID: String?
    /// The ``VoiceSessionSelection/Target`` `sessionID` was resolved for, so a
    /// change in the picker re-resolves instead of reusing the old socket target.
    var boundSessionTarget: VoiceSessionSelection.Target?
    let endpointer = Endpointer()
    var speech: SpeechSession?
    private var resumeTimer: VoiceTimerToken?
    private var thinkingWatchdog: VoiceTimerToken?
    private var bgIdleTimer: VoiceTimerToken?
    private var micHealthTimer: VoiceTimerToken?
    private var micRecoveryAttempts = 0
    /// Invalidates in-flight per-turn async work (STT, TTS) when the user
    /// interrupts, stops, or starts a new turn.
    var turnEpoch = 0
    var foreground = true
    var bargeRun = 0
    /// The transcript of the last turn the ON-DEVICE lane answered, kept so the
    /// user can re-run it on the server ("Try on server"). One-shot: cleared on
    /// retry, on a new spoken turn, on interrupt and on Stop.
    var lastLocalTranscript: String?
    /// Set by `retryLastOnServer` and consumed by `sendTurnToServer`, so the
    /// retry rides the ordinary end-of-speech path instead of a second one.
    var pendingRetryText: String?
    /// Batching counters for `noteMicFrame`.
    var micFramesSent = 0
    var micBytesSent = 0
    /// One "the socket is gone" line per turn, not one per 43 ms frame.
    var loggedMicDrop = false

    // Inbound audio assembly.
    var inFormat = "pcm_s16le"
    var inRate = 24000
    var segMp3 = Data()
    /// Karaoke segment the CURRENT streamed PCM reply belongs to (plan 1.7).
    var pcmTag: Int?

    // Quality mode capture.
    var qualityPcm = Data()
    /// The push-to-talk NDJSON pump. A `TaskHandle` rather than a bare `Task` so
    /// `deinit` — which is nonisolated — can still cancel it.
    let qualityTask = TaskHandle()

    /// Mic effects run ONE AT A TIME through here. `DefaultAudioInput.start`
    /// retries for up to ~1.75 s, so a `startMic` issued before a teardown could
    /// otherwise finish after it and leave the mic live at `.idle`.
    private let micTask = TaskHandle()
    /// Bumped by every mic effect; `startMic` drops a start that a newer effect
    /// (stop / teardown) has already superseded. Internal because `startMic`
    /// lives in `VoiceStoreTransport.swift` and Swift's `private` is file-scoped.
    var micGeneration = 0

    // Latency instrumentation (plan 0.2): one id per spoken turn so a client
    // span can be lined up with the server's `latency` frames for the same turn.
    var turnID: String?
    var speechEndMs: Int?
    var firstAudioLogged = false

    var devicesAt = Date(timeIntervalSince1970: 0)
    var devicesFetching = false

    // MARK: - Init

    /// Every dependency is `nil`-defaulted and its production implementation is
    /// built in the body, not as a default argument: default argument
    /// expressions are evaluated in a NONISOLATED context and all of these are
    /// `@MainActor`.
    init(api: JarvisAPI = .shared,
         input: AudioInput? = nil,
         output: AudioOutput? = nil,
         recognizer: SpeechRecognizing? = nil,
         synthesizer: VoiceSynthesizing? = nil,
         audioSession: AudioSessionControlling? = nil,
         connector: VoiceSocketConnecting? = nil,
         clock: VoiceClock? = nil,
         keyValueStore: KeyValueStore = UserDefaults.standard,
         launch: VoiceLaunchRequesting? = nil,
         local: VoiceLocalLane? = nil) {
        let input = input ?? DefaultAudioInput()
        let output = output ?? DefaultAudioOutput()
        let audioSession = audioSession ?? DefaultAudioSessionControlling()
        let clock = clock ?? SystemVoiceClock()
        let connector = connector ?? URLSessionVoiceSocketConnector()

        self.voice = VoiceAPI(api: api)
        self.input = input
        self.recognizer = recognizer ?? DefaultSpeechRecognizing()
        self.synthesizer = synthesizer ?? DefaultVoiceSynthesizing()
        self.audioSession = audioSession
        self.clock = clock
        self.launch = launch
        self.local = local
        self.settings = VoiceSettings(store: keyValueStore)
        self.audio = AudioQueue(output: output, clock: clock)
        self.session = VoiceSession(voice: VoiceAPI(api: api), connector: connector)
        self.liveActivity = VoiceLiveActivityThrottle(clock: clock)
        self.machine = VoiceTurnMachine(mode: settings.mode)

        input.onFrame = { [weak self] chunk in self?.handleMicFrame(chunk) }
        audio.onIdle = { [weak self] in self?.raise(.playbackDrained) }
        audio.onPlaybackStart = { [weak self] in self?.raise(.playbackStarted) }
        audio.onAmplitude = { [weak self] a in self?.amplitude = a }
        audio.onClipStart = { [weak self] tag, ms in
            self?.reply.clipStarted(tag: tag, durationMs: ms)
        }
        audio.onPosition = { [weak self] tag, ms in
            self?.reply.clipPosition(tag: tag, positionMs: ms)
        }
        self.synthesizer.onPlaybackStart = { [weak self] in
            guard let self, self.isActive else { return }
            self.raise(.playbackStarted)
        }
        self.synthesizer.onSpeechPulse = { [weak self] level in
            guard let self, self.state == .speaking else { return }
            self.amplitude = level
        }
        self.synthesizer.onPlaybackEnd = { [weak self] in
            guard let self, self.isActive else { return }
            self.raise(.playbackDrained)
        }
        session.onFrame = { [weak self] frame in self?.handle(frame) }
        session.onLog = { [weak self] line in self?.note(line) }
        session.onClose = { [weak self] error in
            guard let self else { return }
            self.cancelThinkingWatchdog() // socket closed → stop reassuring
            guard self.machine.state.isActive else { return }
            // A DROPPED socket used to look exactly like the user pressing Stop,
            // so a broken tunnel silently ended the conversation.
            if let error {
                self.raise(.failed(JcLog.report(JcLog.voice, "voice socket closed", error)))
            } else {
                self.raise(.stopRequested)
            }
        }
        audioSession.onInterruption = { [weak self] event in
            guard let self, self.machine.state.isActive else { return }
            if event == .began {
                self.audioInterrupted = true
                self.captureReady = false
                self.amplitude = 0
                self.micHealthTimer?.cancel()
                // Supersede startup retries as well as a live engine. A retry
                // failing under Siri must not turn a resumable pause into error.
                self.perform(.stopMic)
                self.note("audio interrupted")
                return
            }
            self.audioInterrupted = false
            do {
                try self.audioSession.setActive(true)
                if self.foreground && self.wantsCapture {
                    self.note("audio resumed; restarting capture")
                    self.perform(.startMic)
                }
            } catch {
                self.raise(.failed(JcLog.report(JcLog.voice, "resume audio", error)))
            }
        }
    }

    /// `deinit` is nonisolated, which is why the per-turn work lives in
    /// `TaskHandle`s (they lock internally) rather than in bare `Task` properties.
    deinit {
        qualityTask.cancel()
        micTask.cancel()
    }

    // MARK: - Primary actions

    /// Quality mode: tap to talk, tap to send. Realtime: toggles the session.
    func primaryAction() async {
        if machine.mode == .quality {
            if machine.state == .listening {
                raise(.endOfSpeech)
            } else if !machine.state.isActive {
                guard await ensureMic() else { return }
                qualityPcm.removeAll()
                muted = false
                raise(.startRequested)
            }
            return
        }
        if machine.state.isActive {
            await stopAll()
        } else {
            guard await ensureMic() else { return }
            muted = false
            raise(.startRequested)
        }
    }

    /// The user explicitly signals end-of-speech (the "Done" button).
    func finishSpeaking() {
        guard machine.state == .listening else { return }
        raise(.endOfSpeech)
    }

    /// The user interrupts the assistant (the "Interrupt" button).
    func interrupt() { raise(.interruptRequested) }

    /// The voice session picker changed: forget the resolved session so the next
    /// conversation binds to the new target, ending a live one first.
    func sessionTargetChanged() {
        sessionID = nil
        boundSessionTarget = nil
        if machine.state.isActive { Task { await stopAll() } }
    }

    /// Stop everything and return to idle (the Stop button / a mode switch).
    func stopAll() async {
        raise(.stopRequested)
        await audio.stop()
    }

    func toggleMute() { muted.toggle() }

    func setMode(_ newMode: VoiceMode) async {
        guard newMode != machine.mode else { return }
        await stopAll()
        machine.mode = newMode
        settings.mode = newMode
    }

    /// True when mic permission is granted; the page shows the Settings dialog
    /// when this returns false.
    func ensureMic() async -> Bool {
        let granted = await input.requestPermission()
        if !granted { error = "Microphone access is off — turn it on in Settings." }
        return granted
    }

    func setWakeWordEnabled(_ on: Bool) { settings.wakeWordEnabled = on }

    /// Pick the TTS engine (and optionally a voice within it). Persisted, so the
    /// choice survives a relaunch.
    func selectEngine(_ id: String?, voice: String? = nil) {
        settings.selectEngine(id, voice: voice)
    }

    func loadEngines() async {
        do { engines = try await voice.listEngines() }
        catch let failure { error = apiErrorMessage(failure) }
    }

    /// The Siri / Control-Center / wake-word latch. Call from the page's
    /// `.onAppear` and on every `voiceLaunchGeneration` change.
    @discardableResult
    func consumeVoiceLaunch() async -> Bool {
        guard let launch, launch.consumeVoiceLaunch() else { return false }
        guard !machine.state.isActive else { return true }
        await primaryAction()
        return true
    }

    // MARK: - Backgrounding

    /// We behave like a phone call: KEEP the mic, the audio session, the socket
    /// and playback running (the app has the `audio` background mode, which lets
    /// an already-active recording session continue). We deliberately do NOT
    /// stop/restart the mic — that's what reconfigured the session, dropped the
    /// loud speaker route to the quiet earpiece, and eventually wedged playback.
    /// iOS also won't let us re-START a recording session from the background.
    func pauseForBackground() {
        foreground = false
        cancelThinkingWatchdog() // don't fire reassurance timers while backgrounded
        guard machine.mode == .realtime, machine.state.isActive else { return }
        armBgIdleTimeout()
    }

    /// Nothing was torn down — just re-assert the session is active in case iOS
    /// deactivated it while we were away.
    func resumeFromBackground() async {
        foreground = true
        bgIdleTimer?.cancel()
        bgIdleTimer = nil
        guard machine.state.isActive else { return }
        do {
            try audioSession.setActive(true)
            if wantsCapture && !audioInterrupted {
                if input.isRunning { monitorMic() }
                else { perform(.startMic) }
            }
        } catch { raise(.failed(JcLog.report(JcLog.voice, "re-activate on foreground", error))) }
    }

    // MARK: - FSM plumbing

    /// Raise one event and carry out whatever the machine asks for.
    func raise(_ event: VoiceTurnEvent) {
        let before = machine.state
        let effects = machine.apply(event)
        // Log the transition BEFORE the effects run: `.failed` performs
        // `.showError`, which logs too, and the cause has to read above it.
        if before != machine.state || !effects.isEmpty {
            note("\(VoiceDiagnostics.name(of: event)): \(before.rawValue)→\(machine.state.rawValue)")
        }
        for effect in effects { perform(effect) }
        pushLiveActivity()
    }

    private func perform(_ effect: VoiceTurnEffect) {
        switch effect {
        case .openTransport:
            Task { await openTransport() }
        case .startMic:
            let generation = nextMicGeneration()
            runMicEffect { [weak self] in await self?.startMic(generation: generation) }
        case .stopMic:
            micHealthTimer?.cancel()
            captureReady = false
            _ = nextMicGeneration()
            runMicEffect { [weak self] in await self?.input.stop() }
        case .sendEndTurn:
            sendTurnToServer()
        case .sendInterrupt:
            // The user cut in, so the previous local answer is no longer the
            // thing on screen — drop the stale "Try on server" offer.
            lastLocalTranscript = nil
            // A send into a socket that is already gone used to vanish; the turn
            // then waited for a reply that could never arrive.
            if !session.send(.interrupt) { raise(.failed(Self.connectionLostNotice)) }
        case .stopPlayback:
            synthesizer.stop()
            Task { await audio.stop() }
        case .restartRecognizer:
            Task { await startSpeechSession() }
        case .abortRecognizer:
            abortSpeechSession()
        case .scheduleResume:
            scheduleResume()
        case .cancelResume:
            resumeTimer?.cancel()
            resumeTimer = nil
        case .armThinkingWatchdog:
            armThinkingWatchdog()
        case .cancelThinkingWatchdog:
            cancelThinkingWatchdog()
        case .clearReply:
            reply.reset()
            userTranscript = ""
            toolStatus = nil
            error = nil
            pcmTag = nil
            segMp3.removeAll()
            // A new spoken turn supersedes the previous local answer, so the
            // "Try on server" offer for it is gone.
            lastLocalTranscript = nil
        case .finalizeSpoken:
            reply.finalizeSpoken()
        case .resetEndpointer:
            endpointer.reset()
            bargeRun = 0
            amplitude = 0
            loggedMicDrop = false
        case .newTurnEpoch:
            turnEpoch += 1
        case .markSpeechEnd:
            markSpeechEnd()
        case .teardown:
            lastLocalTranscript = nil
            pendingRetryText = nil
            Task { await teardown() }
        case .showError(let message):
            error = message
            note("error: \(message)")
        }
    }

    // MARK: - Try on server

    /// True while the last turn was answered ON-DEVICE and the user could still
    /// ask the server to redo it. Port of `canRetryOnServer`.
    var canRetryOnServer: Bool {
        guard let text = lastLocalTranscript, !text.isEmpty else { return false }
        return machine.state == .listening && !audio.isBusy
    }

    /// Re-run the last on-device voice turn on the SERVER. Sends the on-device
    /// transcript so the server skips its own STT and runs the agent; the reply
    /// streams and speaks through the normal path.
    ///
    /// One-shot, and only valid while listening right after a local reply — it
    /// rides the ordinary end-of-speech path (which clears the reply, bumps the
    /// epoch, marks the speech end and arms the watchdog) rather than opening a
    /// second way to start a turn.
    func retryLastOnServer() {
        guard canRetryOnServer, let text = lastLocalTranscript else { return }
        lastLocalTranscript = nil // one-shot
        abortSpeechSession()      // this turn's text is already decided
        pendingRetryText = text
        note("retry on server")
        raise(.endOfSpeech)
        // After `.clearReply`, so the line the user asked stays on screen.
        userTranscript = text
        pushLiveActivity()
    }

    // MARK: - Mic effects

    private func nextMicGeneration() -> Int {
        micGeneration += 1
        return micGeneration
    }

    /// Queue one mic effect behind the previous one. Start and stop must never
    /// run concurrently — `AVAudioEngine` is one object and the loser of that
    /// race decides whether the mic is live.
    private func runMicEffect(_ body: @escaping @MainActor () async -> Void) {
        let previous = micTask.current
        micTask.replace(Task { @MainActor in
            await previous?.value // `replace` cancelled it, so this is short
            await body()
        })
    }

    var wantsCapture: Bool {
        mode == .quality ? state == .listening : state.isActive && state != .connecting
    }

    /// Detect a stopped engine or stalled tap, independently of speech volume.
    /// Silence still delivers PCM, so a quiet user never trips this recovery.
    func monitorMic() {
        micHealthTimer?.cancel()
        micHealthTimer = clock.schedule(after: 3000) { [weak self] in
            guard let self, self.wantsCapture, !self.audioInterrupted else { return }
            guard self.foreground else { self.monitorMic(); return }
            if self.input.isRunning {
                self.monitorMic()
            } else if self.micRecoveryAttempts == 0 {
                self.micRecoveryAttempts += 1
                self.captureReady = false
                self.note("capture stalled; restarting input")
                self.perform(.startMic)
            } else {
                self.raise(.failed("Microphone audio stopped. Check your microphone or headphones, then tap to try again."))
            }
        }
    }

    // MARK: - Mic frames

    private func handleMicFrame(_ chunk: Data) {
        guard wantsCapture, !audioInterrupted, !chunk.isEmpty else { return }
        captureReady = true
        micRecoveryAttempts = 0
        let amp = voicePeakAmplitude(chunk)

        if machine.mode == .quality {
            guard machine.state == .listening else { return }
            amplitude = muted ? 0 : amp
            if !muted { qualityPcm.append(chunk) }
            return
        }

        // Drive the orb only while listening (playback drives it otherwise).
        if machine.state == .listening { amplitude = muted ? 0 : amp }
        if muted { return }

        // Barge-in: a loud frame during playback interrupts the assistant. Only
        // while foregrounded — backgrounded, the loud reply can leak past echo
        // cancellation and falsely trip the threshold.
        if machine.bargeInAllowed {
            if foreground, detectBargeIn(amp) { raise(.bargeIn) }
            return // don't stream our own playback back to STT
        }

        guard machine.state == .listening else { return }
        bargeRun = 0
        if session.send(pcm: chunk) {
            noteMicFrame(bytes: chunk.count)
        } else if !loggedMicDrop {
            // The socket went away under a live mic: the user keeps talking into
            // nothing. `onClose` normally raises `.failed`, but if it doesn't
            // this is the only trace that the audio never left the phone.
            loggedMicDrop = true
            note("ws→ pcm DROPPED (no socket)")
            raise(.failed(Self.connectionLostNotice))
            return
        }

        // The platform recognizer ends its own session after a stretch of silence
        // (a user who opens the voice screen and pauses). Re-arm it BETWEEN
        // utterances so the next one is still transcribed on-device — never
        // mid-utterance, which would throw away what it has already heard.
        if let running = speech, running.isDone, !endpointer.speaking {
            speech = nil
            Task { await startSpeechSession() }
        }
        // Feed the SAME frames to the recognizer, so its transcript is final the
        // moment the user stops (plan 4.1) instead of starting then.
        speech?.feed(chunk)

        // Adaptive endpointing (plan 1.1). Frame duration comes from the audio
        // itself, not a wall clock, so scheduler jitter can't skew the budget.
        let dtMs = Endpointer.frameMsForPcm16(byteLength: chunk.count, sampleRate: Self.micRate)
        let wasSpeaking = endpointer.speaking
        let endpoint = endpointer.update(amp, dtMs)
        if !wasSpeaking && endpointer.speaking {
            note("speech detected (peak=\(String(format: "%.3f", amp)))")
        }
        if endpoint == .endOfTurn {
            note("speech ended; submitting turn")
            raise(.endOfSpeech)
        }
    }

    func detectBargeIn(_ amp: Double) -> Bool {
        if amp > Self.bargeInThreshold {
            bargeRun = 0
            return true
        }
        bargeRun = amp > Self.bargeInSustainAmp ? bargeRun + 1 : 0
        if bargeRun >= Self.bargeInSustainFrames {
            bargeRun = 0
            return true
        }
        return false
    }

    // MARK: - Timers

    private func scheduleResume() {
        resumeTimer?.cancel()
        resumeTimer = clock.schedule(after: Self.resumeGraceMs) { [weak self] in
            guard let self else { return }
            self.resumeTimer = nil
            guard self.machine.mode == .realtime, self.machine.state.isActive else { return }
            if self.audio.isBusy { return } // a trailing segment is playing
            self.raise(.resumeGraceElapsed)
        }
    }

    private func armThinkingWatchdog() {
        thinkingWatchdog?.cancel()
        thinkingWatchdog = clock.schedule(after: Self.thinkingWatchdogMs) { [weak self] in
            guard let self else { return }
            self.thinkingWatchdog = nil
            guard self.machine.state == .thinking else { return }
            // Only fill a soft status if nothing else is showing — don't stomp a
            // real "Running <tool>" status.
            if self.toolStatus?.isEmpty ?? true {
                self.toolStatus = "Still working…"
                self.pushLiveActivity()
            }
            self.armThinkingWatchdog() // keep reassuring until the reply arrives
        }
    }

    private func cancelThinkingWatchdog() {
        thinkingWatchdog?.cancel()
        thinkingWatchdog = nil
    }

    private func armBgIdleTimeout() {
        bgIdleTimer?.cancel()
        bgIdleTimer = clock.schedule(after: Self.bgIdleTimeoutMs) { [weak self] in
            guard let self else { return }
            self.bgIdleTimer = nil
            if self.foreground || !self.machine.state.isActive { return }
            // Only end a genuinely IDLE backgrounded session: waiting for the
            // user to speak, nobody mid-utterance, no reply in flight. `muted`
            // counts as idle — while muted the VAD is bypassed so the endpointer
            // never clears, which would otherwise re-arm forever.
            if self.machine.state == .listening && (!self.endpointer.speaking || self.muted) {
                Task { await self.stopAll() }
            } else {
                self.armBgIdleTimeout() // busy now — re-check after another window
            }
        }
    }

    // MARK: - Latency spans (plan 0.2)

    private func markSpeechEnd() {
        turnID = "m-\(Int(clock.now.timeIntervalSince1970 * 1_000_000))"
        speechEndMs = nowMs()
        firstAudioLogged = false
    }

    /// First audible sample of the reply — the number the whole rehaul is judged
    /// on. Recorded once per turn, at the moment audio is handed to the player.
    func noteFirstAudio() {
        guard !firstAudioLogged, speechEndMs != nil else { return }
        firstAudioLogged = true
    }

    func nowMs() -> Int { Int(clock.now.timeIntervalSince1970 * 1000) }

    // MARK: - Teardown

    private func teardown() async {
        micHealthTimer?.cancel()
        micHealthTimer = nil
        captureReady = false
        audioInterrupted = false
        micRecoveryAttempts = 0
        abortSpeechSession()
        synthesizer.stop()
        qualityTask.cancel()
        // Every timer belongs to a turn. `stopRequested` only cancels the resume
        // and the watchdog, so the background-idle timer used to keep firing at
        // idle and re-arming itself for the rest of the launch.
        resumeTimer?.cancel()
        resumeTimer = nil
        cancelThinkingWatchdog()
        bgIdleTimer?.cancel()
        bgIdleTimer = nil
        // Supersede any mic start still retrying, then release the mic.
        _ = nextMicGeneration()
        micTask.cancel()
        await input.stop()
        session.close()
        await audio.stop()
        // Fully stopping → release the audio session so other apps' audio resumes.
        do { try audioSession.setActive(false) }
        catch { JcLog.dropped(JcLog.voice, "release audio session", error) }
        amplitude = 0
    }
}

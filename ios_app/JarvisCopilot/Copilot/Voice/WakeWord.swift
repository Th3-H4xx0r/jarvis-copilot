import Foundation

/// Foreground "Hey Jarvis" wake-word listener over on-device speech recognition.
/// Port of `voice/wake_word.dart`.
///
/// Experimental and deliberately constrained by iOS: there is no
/// background/always-on custom wake word for third-party apps, so this only runs
/// while the app is foregrounded and no voice turn is active. **The mic can't be
/// shared**, so the listener must be fully stopped before a recording turn starts
/// (`WakeService.suppress`) and it must be given its OWN `AudioInput` instance,
/// not the one `VoiceStore` uses — they both set `onFrame`.
///
/// Continuous recognition is battery-heavy, hence opt-in and off by default.
@MainActor
final class WakeWordListener {

    static let defaultPhrase = "jarvis"
    static let sampleRate = 16000
    /// Apple ends a recognition session after a pause; loop it.
    static let restartDelayMs = 400

    let phrase: String

    private let input: AudioInput
    private let recognizer: SpeechRecognizing
    private let clock: VoiceClock
    private let onWake: () -> Void

    private var session: SpeechSession?
    private var wantRunning = false
    private var restart: VoiceTimerToken?

    init(input: AudioInput,
         recognizer: SpeechRecognizing,
         clock: VoiceClock,
         phrase: String = WakeWordListener.defaultPhrase,
         onWake: @escaping () -> Void) {
        self.input = input
        self.recognizer = recognizer
        self.clock = clock
        self.phrase = phrase.lowercased()
        self.onWake = onWake
    }

    var isAvailable: Bool { recognizer.isAvailable }
    var isRunning: Bool { wantRunning }

    /// Begin (or resume) listening for the wake word.
    func start() async {
        guard !wantRunning else { return }
        wantRunning = true
        guard await input.requestPermission() else {
            wantRunning = false
            return
        }
        await listen()
    }

    /// Stop listening and release the mic (before a recording turn).
    func stop() async {
        wantRunning = false
        restart?.cancel()
        restart = nil
        let running = session
        session = nil
        running?.cancel()
        input.onFrame = nil
        await input.stop()
    }

    // MARK: - Private

    private func listen() async {
        guard wantRunning, session == nil else { return }
        // `prompt: true` — the user opted in explicitly by turning the wake word
        // on, so a Speech permission sheet here is expected.
        guard let running = await recognizer.startSession(sampleRate: Self.sampleRate,
                                                          prompt: true) else {
            wantRunning = false // no on-device recognizer: don't spin forever
            return
        }
        guard wantRunning else {
            running.cancel()
            return
        }
        running.onPartial = { [weak self] words in self?.heard(words, running) }
        session = running
        input.onFrame = { [weak self] chunk in self?.session?.feed(chunk) }
        do {
            try await input.start(sampleRate: Self.sampleRate)
        } catch {
            JcLog.dropped(JcLog.voice, "wake-word mic start", error)
            session = nil
            running.cancel()
            scheduleRestart()
            return
        }
        scheduleRestart()
    }

    private func heard(_ words: String, _ running: SpeechSession) {
        guard wantRunning, words.lowercased().contains(phrase) else { return }
        // Heard it — stop ourselves and hand the mic to the turn.
        wantRunning = false
        session = nil
        restart?.cancel()
        restart = nil
        running.cancel()
        input.onFrame = nil
        Task { await input.stop() }
        onWake()
    }

    /// Poll for a recognizer that ended itself and open a fresh one.
    private func scheduleRestart() {
        restart?.cancel()
        guard wantRunning else { return }
        restart = clock.schedule(after: Self.restartDelayMs) { [weak self] in
            guard let self else { return }
            self.restart = nil
            guard self.wantRunning else { return }
            if let running = self.session, !running.isDone {
                self.scheduleRestart()
                return
            }
            self.session?.cancel()
            self.session = nil
            Task { await self.listen() }
        }
    }
}

/// App-wide foreground "Hey Jarvis" wake word. Port of `voice/wake_service.dart`.
///
/// iOS can't run a custom wake word in the background or over other apps, so this
/// only listens while the app is foregrounded and no voice turn is active. On a
/// hit it asks the app to open Voice + start a realtime turn via `onWake` —
/// typically `AppRouter.shared.requestVoiceLaunch`, which `VoiceStore` then picks
/// up through `consumeVoiceLaunch()`.
@MainActor
@Observable
final class WakeService {

    /// Called when the wake word is heard.
    var onWake: (() -> Void)?

    private(set) var enabled: Bool
    /// True when this device can run on-device recognition at all.
    var isAvailable: Bool { recognizer.isAvailable }

    private let input: AudioInput
    private let recognizer: SpeechRecognizing
    private let clock: VoiceClock
    private let settings: VoiceSettings

    private var listener: WakeWordListener?
    private var foreground = true
    /// A voice turn currently owns the mic.
    private var suppressed = false

    /// `input` must be a SEPARATE `AudioInput` from the one `VoiceStore` holds —
    /// one mic tap, one `onFrame`.
    init(input: AudioInput,
         recognizer: SpeechRecognizing,
         clock: VoiceClock,
         settings: VoiceSettings) {
        self.input = input
        self.recognizer = recognizer
        self.clock = clock
        self.settings = settings
        self.enabled = settings.wakeWordEnabled
    }

    /// Toggle the wake word. Returns false if mic permission was denied (the
    /// caller should show the Settings dialog).
    @discardableResult
    func setEnabled(_ on: Bool) async -> Bool {
        guard on else {
            enabled = false
            settings.wakeWordEnabled = false
            await listener?.stop()
            return true
        }
        guard await input.requestPermission() else { return false }
        enabled = true
        settings.wakeWordEnabled = true
        await maybeListen()
        return true
    }

    /// A voice turn started — release the wake mic.
    func suppress() async {
        suppressed = true
        await listener?.stop()
    }

    /// A voice turn ended — resume listening if still enabled + foregrounded.
    func resume() async {
        suppressed = false
        await maybeListen()
    }

    func setForeground(_ isForeground: Bool) async {
        foreground = isForeground
        if isForeground {
            await maybeListen()
        } else {
            // iOS suspends the mic in the background anyway.
            await listener?.stop()
        }
    }

    private func maybeListen() async {
        guard enabled, foreground, !suppressed else { return }
        let running = listener ?? WakeWordListener(
            input: input, recognizer: recognizer, clock: clock
        ) { [weak self] in
            guard let self else { return }
            // The listener stopped itself; mark suppressed so we don't restart
            // before the turn grabs the mic, then ask the app to open Voice.
            self.suppressed = true
            self.onWake?()
        }
        listener = running
        await running.start()
    }
}

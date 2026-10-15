import AppKit
import AVFoundation
import Observation
import Speech

extension Notification.Name {
    /// Flow dictation took / gave back the microphone.
    static let jarvisDictationStarted = Notification.Name("jarvis.dictationStarted")
    static let jarvisDictationEnded = Notification.Name("jarvis.dictationEnded")
    /// The note-taker started or stopped recording a call.
    static let jarvisNoteRecordingChanged = Notification.Name("jarvis.noteRecordingChanged")
    /// The menu bar's Jarvis voice panel opened / closed (it holds the microphone while open).
    static let jarvisVoicePanelOpened = Notification.Name("jarvis.voicePanelOpened")
    static let jarvisVoicePanelClosed = Notification.Name("jarvis.voicePanelClosed")
}

/// "Hey Jarvis": an on-device wake spotter that opens the Jarvis voice panel.
/// Off by default (Settings → Voice). While on, the microphone is open but the
/// recognizer only runs while the energy VAD hears a voice, and nothing leaves
/// the Mac. It pauses while the screen is locked or asleep, in Low Power Mode,
/// while you dictate, while a call is being recorded and while the voice panel
/// itself is open; a wake heard while an approval/question waits, or while you
/// type in the island, is ignored.
///
/// Reliability (after coucou's VoiceEngine, github.com/Louis-CFM/coucou, MIT):
/// window backoff, a 2 s audio-stall watchdog, a deaf-recognizer check and
/// rate-limited pipeline rebuilds (Settings says so if it gives up).
@MainActor
@Observable
final class WakeWord {
    static let shared = WakeWord()

    private(set) var conditions = WakeConditions()
    /// Why the pipeline couldn't run, for Settings.
    private(set) var problem: String?
    var status: WakeStatus { conditions.status }

    /// Set by the app: what opens the voice panel.
    @ObservationIgnored var onWake: (() -> Void)?
    /// Set by the app: an approval/question waiting, or typing in the island.
    @ObservationIgnored var interaction: () -> (pending: Bool, typing: Bool) = { (false, false) }

    @ObservationIgnored private var audio: WakeAudio?
    @ObservationIgnored private var spotter: WakeSpotter?
    @ObservationIgnored private var voiceSegmentActive = false
    @ObservationIgnored private var backoff = WakeBackoff()
    @ObservationIgnored private var limiter = RebuildLimiter()
    @ObservationIgnored private var windowOpenedAt = Date.distantPast
    @ObservationIgnored private var pipelineStartedAt = Date.distantPast
    @ObservationIgnored private var errorStreak = 0
    @ObservationIgnored private var deafWindows = 0
    @ObservationIgnored private var windowLimitWork: DispatchWorkItem?
    @ObservationIgnored private var retryWork: DispatchWorkItem?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var voiceOpenFallback: DispatchWorkItem?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var dictations = 0

    private static let windowMax: TimeInterval = 20
    private static let stallTimeout: TimeInterval = 2

    private init() {}

    // MARK: control

    /// At launch: listens if it was left on (permissions are only read, never asked for here).
    func start() {
        guard !started else { return }
        started = true
        conditions.enabled = Prefs.wakeWord
        conditions.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        refreshPermissions()
        observeSystem()
        update()
    }

    /// The Settings toggle. Turning it on asks for the microphone and speech
    /// recognition the first time; a refusal shows in Settings and nothing runs.
    func setEnabled(_ on: Bool) {
        Prefs.wakeWord = on
        conditions.enabled = on
        problem = nil
        guard on else { update(); return }
        Task { @MainActor in
            await self.requestPermissions()
            self.update()
        }
    }

    func refreshPermissions() {
        conditions.micAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        conditions.speechAllowed = SFSpeechRecognizer.authorizationStatus() == .authorized
        conditions.recognizerAvailable = Self.recognizer() != nil
    }

    private func requestPermissions() async {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                SFSpeechRecognizer.requestAuthorization { _ in c.resume() }
            }
        }
        refreshPermissions()
    }

    private func update() {
        if conditions.shouldRun { startPipeline() } else { stopPipeline() }
    }

    /// The wake phrase is English: an en-US on-device recognizer, else the Mac's own language's.
    static func recognizer() -> SFSpeechRecognizer? {
        for locale in [Locale(identifier: "en-US"), Locale(identifier: "en-GB"), Locale.current] {
            if let r = SFSpeechRecognizer(locale: locale), r.supportsOnDeviceRecognition { return r }
        }
        return nil
    }

    // MARK: pipeline

    private func startPipeline() {
        guard audio == nil else { return }
        guard let recognizer = Self.recognizer() else {
            conditions.recognizerAvailable = false
            return
        }
        let a = WakeAudio()
        let s = WakeSpotter(recognizer: recognizer)
        s.onWake = { [weak self] in self?.woke() }
        s.onWindowEnded = { [weak self] wasError in self?.windowEnded(wasError: wasError) }
        a.onVoiceStart = { [weak self] in
            guard let self, self.audio === a else { return }
            self.voiceSegmentActive = true
            self.backoff.reset()
            self.errorStreak = 0
            self.openWindow()
        }
        a.onVoiceEnd = { [weak self] in
            guard let self, self.audio === a else { return }
            self.voiceSegmentActive = false
            self.windowLimitWork?.cancel()
            self.retryWork?.cancel()
            guard s.isActive else { return }
            let elapsed = Date().timeIntervalSince(self.windowOpenedAt)
            self.checkDeaf(s.endWindow(), elapsed: elapsed)
        }
        a.onConfigChange = { [weak self] in
            guard let self, Date().timeIntervalSince(self.pipelineStartedAt) > 1 else { return }
            self.rebuild("the audio device changed")
        }
        a.onBuffer = { [weak s] buffer in s?.feed(buffer) }
        do {
            try a.start()
        } catch {
            problem = String(localized: "The microphone didn't start: \(error.localizedDescription)")
            return
        }
        audio = a
        spotter = s
        pipelineStartedAt = Date()
        problem = nil
        startWatchdog()
    }

    private func stopPipeline() {
        windowLimitWork?.cancel(); windowLimitWork = nil
        retryWork?.cancel(); retryWork = nil
        watchdog?.cancel(); watchdog = nil
        spotter?.onWake = nil
        spotter?.onWindowEnded = nil
        spotter?.endWindow()
        audio?.stop()
        audio?.onVoiceStart = nil
        audio?.onVoiceEnd = nil
        audio?.onBuffer = nil
        audio?.onConfigChange = nil
        audio = nil
        spotter = nil
        voiceSegmentActive = false
        backoff.reset()
        errorStreak = 0
    }

    private func openWindow() {
        guard let audio, let spotter, !spotter.isActive else { return }
        if spotter.beginWindow(preroll: audio.drainPreroll()) {
            windowOpenedAt = Date()
            let item = DispatchWorkItem { [weak self] in
                // A 20 s window can be steady talk without the phrase: start a fresh one.
                guard let self, let s = self.spotter, s.isActive else { return }
                s.endWindow()
                self.openWindow()
            }
            windowLimitWork?.cancel()
            windowLimitWork = item
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.windowMax, execute: item)
        } else {
            // The recognizer is busy or not ready: try again shortly while the voice goes on.
            let item = DispatchWorkItem { [weak self] in
                guard let self, self.voiceSegmentActive else { return }
                self.openWindow()
            }
            retryWork?.cancel()
            retryWork = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: item)
        }
    }

    private func windowEnded(wasError: Bool) {
        guard voiceSegmentActive else { return }
        if wasError {
            errorStreak += 1
            if errorStreak >= 3 { rebuild("the recognizer kept failing"); return }
        } else {
            errorStreak = 0
        }
        switch backoff.windowEnded(elapsed: Date().timeIntervalSince(windowOpenedAt), wasError: wasError) {
        case .open: openWindow()
        case .delay(let d):
            let item = DispatchWorkItem { [weak self] in
                guard let self, self.voiceSegmentActive else { return }
                self.openWindow()
            }
            retryWork?.cancel()
            retryWork = item
            DispatchQueue.main.asyncAfter(deadline: .now() + d, execute: item)
        case .stop:
            break  // wait for the next burst of voice
        }
    }

    /// A voice was heard for a while but the recognizer gave nothing, twice: it's stuck.
    private func checkDeaf(_ stats: WakeSpotter.WindowStats, elapsed: TimeInterval) {
        if stats.partials > 0 { deafWindows = 0; return }
        guard elapsed >= 3 else { return }
        deafWindows += 1
        if deafWindows >= 2 {
            deafWindows = 0
            rebuild("the recognizer heard nothing")
        }
    }

    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500), tolerance: .milliseconds(400))
                guard let self, let audio = self.audio else { return }
                guard Date().timeIntervalSince(self.pipelineStartedAt) > Self.stallTimeout else { continue }
                if Date().timeIntervalSince(audio.lastBufferTime) > Self.stallTimeout {
                    self.rebuild("the microphone stopped sending sound")
                    return
                }
            }
        }
    }

    private func rebuild(_ reason: String) {
        guard limiter.allow(at: ProcessInfo.processInfo.systemUptime) else {
            problem = String(localized: "Voice recognition keeps stalling (\(reason)). Turn Hey Jarvis off and on again.")
            stopPipeline()
            return
        }
        NSLog("Jarvis wake: rebuilding the pipeline: \(reason)")
        stopPipeline()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.conditions.shouldRun else { return }
            self.startPipeline()
        }
    }

    // MARK: the wake

    private func woke() {
        guard conditions.shouldRun else { return }
        let now = interaction()
        if let reason = WakeFilter.blocked(pending: now.pending, typing: now.typing) {
            NSLog("Jarvis wake: ignored (\(reason))")
            return
        }
        // Give the microphone to the voice panel. It reports when it opens and
        // closes; if it never opens (no panel: the island toggled instead), listen again.
        // Scheduled before onWake: the panel's "opened" notice cancels it.
        conditions.voiceOpen = true
        update()
        let fallback = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.conditions.voiceOpen = false
            self.update()
        }
        voiceOpenFallback?.cancel()
        voiceOpenFallback = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: fallback)
        onWake?()
    }

    // MARK: system

    private func observeSystem() {
        let dc = DistributedNotificationCenter.default()
        dc.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.set(\.locked, true) }
        }
        dc.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.set(\.locked, false) }
        }
        let ws = NSWorkspace.shared.notificationCenter
        for (name, asleep) in [(NSWorkspace.willSleepNotification, true), (NSWorkspace.didWakeNotification, false),
                               (NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false)] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.set(\.asleep, asleep) }
            }
        }
        let nc = NotificationCenter.default
        nc.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.set(\.lowPower, ProcessInfo.processInfo.isLowPowerModeEnabled) }
        }
        nc.addObserver(forName: .jarvisDictationStarted, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.dictations += 1
                self.set(\.dictating, true)
            }
        }
        nc.addObserver(forName: .jarvisDictationEnded, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.dictations = max(0, self.dictations - 1)
                self.set(\.dictating, self.dictations > 0)
            }
        }
        nc.addObserver(forName: .jarvisNoteRecordingChanged, object: nil, queue: .main) { [weak self] note in
            let on = (note.object as? Bool) ?? false
            MainActor.assumeIsolated { self?.set(\.recordingNote, on) }
        }
        nc.addObserver(forName: .jarvisVoicePanelOpened, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.voiceOpenFallback?.cancel()
                self?.set(\.voiceOpen, true)
            }
        }
        nc.addObserver(forName: .jarvisVoicePanelClosed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.voiceOpenFallback?.cancel()
                self?.set(\.voiceOpen, false)
            }
        }
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            // Back from System Settings: a permission may have been granted.
            MainActor.assumeIsolated {
                guard let self, self.conditions.enabled else { return }
                self.refreshPermissions()
                self.update()
            }
        }
    }

    private func set(_ path: WritableKeyPath<WakeConditions, Bool>, _ value: Bool) {
        guard conditions[keyPath: path] != value else { return }
        conditions[keyPath: path] = value
        update()
    }
}

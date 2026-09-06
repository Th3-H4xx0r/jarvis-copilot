import Foundation
import Observation

/// The app-level view of `WakeService`, so the listener can be created lazily and
/// torn down again.
@MainActor
protocol WakeListening: AnyObject {
    var onWake: (() -> Void)? { get set }
    @discardableResult
    func setEnabled(_ on: Bool) async -> Bool
    /// A voice turn is taking the mic.
    func suppress() async
    /// The turn ended.
    func resume() async
    func setForeground(_ isForeground: Bool) async
}

extension WakeService: WakeListening {}

/// Owns the "Hey Jarvis" listener's lifetime.
///
/// `WakeService` was written but never instantiated; this is the piece that was
/// missing. Three rules, all of them about the microphone:
///
///  * **Create it only when the setting is on.** The listener holds its OWN
///    `AudioInput` (one mic tap, one `onFrame` — `VoiceStore` owns the other),
///    and an unused `AVAudioEngine` per launch is not free.
///  * **Foreground only.** iOS has no always-on custom wake word for third-party
///    apps, so the scene phase drives it.
///  * **Never fight a voice turn.** The mic cannot be shared: the listener is
///    fully stopped while a turn is active and resumed when it ends.
///
/// `@Observable` so the Voice toolbar's switch can reflect the live state rather
/// than only the persisted preference.
@MainActor
@Observable
final class WakeWordController {

    static let shared = WakeWordController()

    /// How long a forwarded wake has to turn into a live voice turn before the
    /// listener takes its own mic back. Long enough to cover opening Voice and a
    /// permission sheet, short enough that a launch that never happened doesn't
    /// cost the user the wake word until they relaunch the app.
    static let wakeHandoffMs = 8000

    /// Called when the wake word is heard; `AppServices` points this at
    /// `AppRouter.requestVoiceLaunch`.
    var onWake: (() -> Void)?

    /// True while a listener object exists (i.e. the setting is on).
    private(set) var isListening = false

    @ObservationIgnored private let settings: VoiceSettings
    @ObservationIgnored private let make: @MainActor (VoiceSettings) -> any WakeListening
    @ObservationIgnored private let clock: VoiceClock
    @ObservationIgnored private var service: (any WakeListening)?
    @ObservationIgnored private var foreground = true
    @ObservationIgnored private var voiceActive = false
    /// Non-nil between a forwarded wake and the turn that was supposed to follow.
    @ObservationIgnored private var wakeDeadline: VoiceTimerToken?

    /// `make` builds the listener on first use, and is handed THIS controller's
    /// `VoiceSettings` so the two can't disagree about whether the wake word is
    /// on (each `VoiceSettings` caches its own copy of the preference).
    /// `nil`-defaulted rather than defaulted to the production closure because a
    /// default argument expression is evaluated in a NONISOLATED context (which
    /// is also why `clock` is optional).
    init(settings: VoiceSettings? = nil,
         make: (@MainActor (VoiceSettings) -> any WakeListening)? = nil,
         clock: VoiceClock? = nil) {
        self.settings = settings ?? VoiceSettings()
        self.make = make ?? { WakeWordController.makeWakeService(settings: $0) }
        self.clock = clock ?? SystemVoiceClock()
    }

    /// The wake word gets its OWN `AudioInput` — one mic tap, one `onFrame`, and
    /// `VoiceStore` already owns the other one.
    private static func makeWakeService(settings: VoiceSettings) -> WakeService {
        WakeService(input: DefaultAudioInput(),
                    recognizer: DefaultSpeechRecognizing(),
                    clock: SystemVoiceClock(),
                    settings: settings)
    }

    /// Whether the user has the wake word switched on (the persisted value).
    var isEnabled: Bool { settings.wakeWordEnabled }

    // MARK: - Scene phase

    /// `WakeControlling`, called from `AppServices.setForeground`. This is also
    /// the app's first arming: on launch the scene phase fires `.active`, and if
    /// the setting was left on the listener is created right here.
    func setForeground(_ isForeground: Bool) async {
        foreground = isForeground
        guard isForeground else {
            await service?.setForeground(false)
            return
        }
        guard settings.wakeWordEnabled else { return }
        let running = ensureService()
        await running.setForeground(true)
        // A turn that was live when we backgrounded still owns the mic.
        if voiceActive {
            await running.suppress()
        } else if awaitingWakeHandoff {
            // A wake fired and no turn ever took the mic, so the service is
            // still latched `suppressed` — and `setForeground(true)` is refused
            // while it is. Coming back to the foreground is as good a signal as
            // the deadline that the hand-off is never happening.
            clearWakeHandoff()
            await running.resume()
        }
    }

    // MARK: - The toolbar switch

    /// Turn the wake word on or off *live*. Returns false when mic permission was
    /// refused, in which case nothing is listening and the caller must not leave
    /// the switch looking on.
    @discardableResult
    func setEnabled(_ on: Bool) async -> Bool {
        guard on else {
            await service?.setEnabled(false)
            service = nil
            isListening = false
            settings.wakeWordEnabled = false
            return true
        }
        let running = ensureService()
        guard await running.setEnabled(true) else {
            // Permission refused: don't keep a listener that can never listen.
            service = nil
            isListening = false
            return false
        }
        settings.wakeWordEnabled = true
        await running.setForeground(foreground)
        if voiceActive { await running.suppress() }
        return true
    }

    // MARK: - Voice turns

    /// Follows `VoiceStore.isActive`. The mic cannot be shared, so a turn taking
    /// it must fully stop the listener first — and a turn that ends must give it
    /// back, or the wake word is dead for the rest of the launch.
    func setVoiceActive(_ active: Bool) async {
        // The turn we were waiting for arrived (or the page told us there is no
        // turn) — either way the deadline has done its job.
        if active { clearWakeHandoff() }
        guard active != voiceActive else { return }
        voiceActive = active
        if active {
            await service?.suppress()
        } else {
            await service?.resume()
        }
    }

    // MARK: - Private

    private var awaitingWakeHandoff: Bool { wakeDeadline != nil }

    /// The wake word fired. `WakeService` latches `suppressed` at that instant so
    /// it can't grab the mic back from under the turn — but only `resume()`
    /// clears it, and `resume()` only arrives via `setVoiceActive(false)`. If no
    /// turn ever becomes active (the mic is refused in `ensureMic`, or `VoicePage`
    /// never enters the hierarchy to report it), the wake word is dead for the
    /// rest of the launch. So: forward the wake, then give the hand-off a
    /// deadline.
    private func handleWake() {
        onWake?()
        wakeDeadline?.cancel()
        wakeDeadline = clock.schedule(after: Self.wakeHandoffMs) { [weak self] in
            guard let self else { return }
            self.wakeDeadline = nil
            guard !self.voiceActive else { return }
            Task { await self.service?.resume() }
        }
    }

    private func clearWakeHandoff() {
        wakeDeadline?.cancel()
        wakeDeadline = nil
    }

    private func ensureService() -> any WakeListening {
        if let service { return service }
        let created = make(settings)
        // The controller sits in the middle of the callback rather than handing
        // the app's closure straight over, so it can time the hand-off.
        created.onWake = { [weak self] in self?.handleWake() }
        service = created
        isListening = true
        return created
    }
}

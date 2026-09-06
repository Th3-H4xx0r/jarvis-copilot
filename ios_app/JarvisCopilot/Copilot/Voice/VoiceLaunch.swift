import Foundation

/// The Siri / Control-Center / wake-word "start voice" latch, as the voice store
/// needs to see it.
///
/// The production implementation is `AppRouter` (`Copilot/Shell/AppRouter.swift`)
/// — it already exposes exactly these three members, so the conformance below is
/// all the wiring needed. `VoiceStore(launch: AppRouter.shared)` then starts a
/// turn whenever the latch fires.
///
/// A *latch*, not an event: on a cold launch the request arrives before any view
/// has mounted to hear it, so it has to survive until Voice consumes it.
@MainActor
protocol VoiceLaunchRequesting: AnyObject {
    var voiceLaunchRequested: Bool { get }
    /// Bumped on every request, so a view can `.onChange` even when a stale
    /// `true` is already sitting there.
    var voiceLaunchGeneration: Int { get }
    /// Takes the latch. The second call in a row is always false, so a re-render
    /// can't start two turns.
    @discardableResult
    func consumeVoiceLaunch() -> Bool
}

extension AppRouter: VoiceLaunchRequesting {}

/// Bridges the native side of the Flutter launch path to `AppRouter`.
///
/// `StartVoiceIntent` (Siri/Shortcuts) and `OpenJarvisVoiceIntent` (the Control
/// Center control) both set `jc_pending_voice` in `UserDefaults` — which covers a
/// cold launch, because the intent runs in our process before any UI exists — and
/// post `jcStartVoice`, which covers a warm one. Wire it once at app start:
///
/// ```swift
/// let bridge = VoiceLaunchBridge()
/// bridge.onRequest = { AppRouter.shared.requestVoiceLaunch() }
/// bridge.start()
/// ```
///
/// It also conforms to `VoiceLaunchRequesting`, so it can drive a `VoiceStore`
/// directly (in tests, or before the shell exists).
@MainActor
@Observable
final class VoiceLaunchBridge: VoiceLaunchRequesting {

    static let notificationName = Notification.Name("jcStartVoice")

    /// Called for every request — cold-launch flag included, once `start()` runs.
    var onRequest: (() -> Void)?

    private(set) var voiceLaunchRequested = false
    private(set) var voiceLaunchGeneration = 0

    private let store: KeyValueStore
    private let center: NotificationCenter
    /// `nonisolated(unsafe)`: `deinit` is nonisolated and has to release this.
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    init(store: KeyValueStore = UserDefaults.standard, center: NotificationCenter = .default) {
        self.store = store
        self.center = center
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Begin observing, and replay a cold-launch request if one is pending.
    func start() {
        // `queue: nil` = delivered synchronously on the poster's thread. The App
        // Intents post from the main actor, so the request lands in the same turn
        // instead of a run-loop hop later; anything else is hopped explicitly.
        observer = center.addObserver(forName: Self.notificationName, object: nil, queue: nil) { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.request() }
            } else {
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.request() } }
            }
        }
        if store.bool(VoiceSettings.pendingVoiceKey) == true { request() }
    }

    func request() {
        voiceLaunchRequested = true
        voiceLaunchGeneration += 1
        // Clearing the persisted flag here is what stops a relaunch from
        // starting a turn nobody asked for.
        store.set(nil, forKey: VoiceSettings.pendingVoiceKey)
        onRequest?()
    }

    @discardableResult
    func consumeVoiceLaunch() -> Bool {
        guard voiceLaunchRequested else { return false }
        voiceLaunchRequested = false
        return true
    }
}

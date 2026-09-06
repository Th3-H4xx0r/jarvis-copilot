import Foundation

// MARK: - Boundaries
//
// Every startup step is behind a protocol so `AppServicesTests` can assert the
// sequence — and the scene-phase fan-out — with fakes, rather than by booting a
// socket, a microphone and ActivityKit.

/// Registering the phone's own skills with the bridge.
@MainActor
protocol PhoneSkillInstalling: AnyObject {
    func installPhoneSkills()
}

/// The device bridge, as the app-level wiring uses it.
@MainActor
protocol AppBridging: AnyObject {
    var isPaired: Bool { get }
    /// The "stay connected in the background" master switch.
    var isBridgeEnabled: Bool { get }
    func connect()
    /// Re-advertise the skill catalogue over an already-open socket.
    func sendRegistration()
}

/// The foreground "Hey JARVIS" listener, as the app-level wiring uses it.
/// Production is `WakeWordController.shared`, which owns `WakeService`'s lifetime
/// (it is created only while the wake-word setting is on).
@MainActor
protocol WakeControlling: AnyObject {
    var onWake: (() -> Void)? { get set }
    func setForeground(_ isForeground: Bool) async
}

/// The Siri / Control Center / widget "start voice" latch.
@MainActor
protocol VoiceLaunchStarting: AnyObject {
    var onRequest: (() -> Void)? { get set }
    func start()
}

/// The bridge-connection watcher that posts "JARVIS disconnected / reconnected".
@MainActor
protocol ConnectionWatching: AnyObject {
    func start()
}

/// The Live Activity owner.
@MainActor
protocol LiveActivityCoordinating: AnyObject {
    func start()
    func onResume()
    func reportVoice(_ snapshot: VoiceLiveActivitySnapshot)
}

/// Opt-in background location history.
@MainActor
protocol BackgroundLocationStarting: AnyObject {
    /// Re-arm on launch when the user left tracking on.
    func startIfEnabled()
}

/// Running foreground-required actions that were deferred while backgrounded.
@MainActor
protocol PendingActionDraining: AnyObject {
    @discardableResult
    func drainPending() async -> Int
}

/// The one voice session, as the scene-phase hook and the Live Activity see it.
@MainActor
protocol VoiceLifecycle: AnyObject {
    func pauseForBackground()
    func resumeFromBackground() async
    /// Route this session's island snapshots somewhere (the coordinator).
    func attachLiveActivity(_ onPush: @escaping (VoiceLiveActivitySnapshot) -> Void)
    /// Send a one-shot prompt as a chat turn (the "Ask JARVIS" App Intent).
    func ask(_ prompt: String) async
}

/// On-device energy/CPU metrics.
@MainActor
protocol MetricsRegistering: AnyObject {
    func register()
}

// MARK: - Production conformances

extension BridgeClient: AppBridging {
    /// `enabled` under the boundary's name; the setter stays `BridgeClient`'s own.
    var isBridgeEnabled: Bool { enabled }
}

extension WakeWordController: WakeControlling {}
extension VoiceLaunchBridge: VoiceLaunchStarting {}
extension BridgeConnectionFeed: ConnectionWatching {}
extension LiveActivityCoordinator: LiveActivityCoordinating {}
extension BackgroundLocationService: BackgroundLocationStarting {}
extension InvokeRunner: PendingActionDraining {}
extension MetricKitReporter: MetricsRegistering {}

/// The phone skills installer, as a value the services can hold.
@MainActor
final class DefaultPhoneSkillInstaller: PhoneSkillInstalling {
    private let bridge: any AppBridging

    init(bridge: (any AppBridging)? = nil) {
        self.bridge = bridge ?? BridgeClient.shared
    }

    func installPhoneSkills() {
        PhoneSkills.install()
        // The socket may already be up (a warm relaunch reuses it), in which case
        // the server is holding a catalogue that predates these skills. Re-send.
        bridge.sendRegistration()
    }
}

/// `VoiceStore` behind `VoiceLifecycle`.
///
/// `main.dart` built its `VoiceController` lazily so the audio session was not
/// configured until Voice was opened. Here the store's `init` allocates objects
/// and installs one notification observer but configures NO audio session and
/// starts NO mic (see `DefaultAudioSessionControlling.configureForConversation`,
/// which is what actually claims the session), so resolving it at launch is
/// cheap — and resolving it eagerly is what makes the live-activity attach and
/// the background pause/resume actually reach the session.
@MainActor
final class SharedVoiceLifecycle: VoiceLifecycle {
    private let store: VoiceStore

    init(store: VoiceStore? = nil) {
        self.store = store ?? VoiceStore.shared
    }

    func pauseForBackground() { store.pauseForBackground() }

    func resumeFromBackground() async { await store.resumeFromBackground() }

    func attachLiveActivity(_ onPush: @escaping (VoiceLiveActivitySnapshot) -> Void) {
        store.liveActivity.onPush = onPush
    }

    func ask(_ prompt: String) async {
        // The Chat screen owns its own `ChatStore`, so there is no shared one to
        // push into; sending through a private store still persists the turn
        // server-side, and `ChatSyncBus` is what makes the open thread notice.
        // Whoever lands the Chat screen should replace this by registering
        // `ChatLaunchBus.shared.send`.
        let chat = ChatStore()
        await chat.send(prompt)
        ChatSyncBus.shared.sessionChanged(chat.sessionID)
    }
}

// MARK: - AppServices

/// The app's startup sequence and its scene-phase fan-out — everything
/// `main.dart` did before `runApp`, and everything its
/// `didChangeAppLifecycleState` did afterwards.
///
/// One place, called once, so the ordering constraints are visible: skills must
/// be registered before the socket advertises them; the notification delegate
/// must exist before iOS delivers a launch tap; the pending-action drain has to
/// run after `AppLifecycle.isForeground` is true or every action re-defers.
@MainActor
final class AppServices {

    static let shared = AppServices()

    private let skills: any PhoneSkillInstalling
    private let registry: SkillRegistry
    private let bridge: any AppBridging
    private let push: any PushStarting
    private let persona: any PersonaLoading
    private let wake: any WakeControlling
    private let voiceLaunch: any VoiceLaunchStarting
    private let connection: any ConnectionWatching
    private let liveActivity: any LiveActivityCoordinating
    private let location: any BackgroundLocationStarting
    private let runner: any PendingActionDraining
    private let voice: any VoiceLifecycle
    private let metrics: any MetricsRegistering
    private let lifecycle: AppLifecycle
    private let pending: PendingActions
    private let router: AppRouter
    private let deepLinks: AppDeepLinkRouter
    private let chatLaunch: ChatLaunchBus
    private let shortcuts: ShortcutResultBus

    private(set) var didStart = false
    /// True while the app is in the foreground, as this object last saw it.
    private(set) var isForeground = true

    /// Every dependency is `nil`-defaulted and built in the body rather than as a
    /// default argument: default argument expressions are evaluated in a
    /// NONISOLATED context, and all of these are `@MainActor`.
    init(skills: (any PhoneSkillInstalling)? = nil,
         registry: SkillRegistry? = nil,
         bridge: (any AppBridging)? = nil,
         push: (any PushStarting)? = nil,
         persona: (any PersonaLoading)? = nil,
         wake: (any WakeControlling)? = nil,
         voiceLaunch: (any VoiceLaunchStarting)? = nil,
         connection: (any ConnectionWatching)? = nil,
         liveActivity: (any LiveActivityCoordinating)? = nil,
         location: (any BackgroundLocationStarting)? = nil,
         runner: (any PendingActionDraining)? = nil,
         voice: (any VoiceLifecycle)? = nil,
         metrics: (any MetricsRegistering)? = nil,
         lifecycle: AppLifecycle = .shared,
         pending: PendingActions = .shared,
         router: AppRouter = .shared,
         deepLinks: AppDeepLinkRouter? = nil,
         chatLaunch: ChatLaunchBus = .shared,
         shortcuts: ShortcutResultBus = .shared) {
        self.skills = skills ?? DefaultPhoneSkillInstaller()
        self.registry = registry ?? .shared
        self.bridge = bridge ?? BridgeClient.shared
        self.push = push ?? PushHandler.shared
        self.persona = persona ?? DefaultPersonaLoader()
        self.wake = wake ?? WakeWordController.shared
        self.voiceLaunch = voiceLaunch ?? VoiceLaunchBridge()
        self.liveActivity = liveActivity ?? LiveActivityCoordinator.shared
        self.connection = connection ?? BridgeConnectionFeed(
            monitor: ConnectionMonitor(notifier: LocalConnectionNotifier()))
        self.location = location ?? BackgroundLocationService.shared
        self.runner = runner ?? InvokeRunner.shared
        self.voice = voice ?? SharedVoiceLifecycle()
        self.metrics = metrics ?? MetricKitReporter.shared
        self.lifecycle = lifecycle
        self.pending = pending
        self.router = router
        self.deepLinks = deepLinks ?? AppDeepLinkRouter(router: router)
        self.chatLaunch = chatLaunch
        self.shortcuts = shortcuts
    }

    // MARK: - Startup

    /// Called once, as early as possible, from `JarvisCopilotApp`.
    func start() {
        guard !didStart else { return }
        didStart = true

        // 1. Skills first: the socket advertises whatever the registry holds when
        //    it connects, so registering after `connect()` would race.
        skills.installPhoneSkills()

        // 1b. …and keep it advertised: switching a skill off in the Skills tab is
        //     a real ACL (it leaves the manifest), so the server has to be told
        //     while the app is still running. Installed AFTER the bulk register
        //     above so it fires once per user change, not once per skill.
        //     `sendRegistration` is a no-op when the socket is down; the next
        //     connect sends the current catalogue anyway.
        registry.onChanged = { [weak self] in self?.bridge.sendRegistration() }

        // 2. The live bridge. Unpaired means there is nothing to connect to, and
        //    bridge mode off means the user asked us not to.
        if bridge.isPaired && bridge.isBridgeEnabled { bridge.connect() }

        // 3. Push: the notification delegate, the Approve/Deny/Reply categories
        //    and the APNs registration. Early, because a tap that LAUNCHED the
        //    app is delivered as soon as a delegate exists.
        push.start()

        // 4. Wake word (opt-in, foreground only) → open Voice and start a turn.
        wake.onWake = { [weak self] in self?.router.requestVoiceLaunch() }

        // 5. Siri / Control Center / widget latch, incl. a cold-launch replay.
        voiceLaunch.onRequest = { [weak self] in self?.router.requestVoiceLaunch() }
        voiceLaunch.start()

        // 6. "JARVIS disconnected / reconnected" banners.
        connection.start()

        // 7. The single Live Activity owner, fed by the voice session.
        voice.attachLiveActivity { [weak self] snapshot in
            self?.liveActivity.reportVoice(snapshot)
        }
        liveActivity.start()

        // 8. Background location, if the user left it on.
        location.startIfEnabled()

        // 9. Field metrics + the home-screen quick actions.
        metrics.register()
        #if os(iOS)
        QuickAction.install()
        #endif

        // 10. "Ask JARVIS" from Siri, until the Chat screen registers its own.
        if chatLaunch.send == nil {
            chatLaunch.send = { [weak self] prompt in await self?.voice.ask(prompt) }
        }

        // 11. A tapped "tap to run" notification enqueues its action; run it
        //     immediately when we are already foregrounded (the tap can land just
        //     after the resume drain has run).
        pending.onChanged = { [weak self] in
            guard let self, self.lifecycle.isForeground else { return }
            Task { await self.runner.drainPending() }
        }
        Task { await runner.drainPending() }

        // 12. The server's active personality → the on-device model, so a locally
        //     answered turn sounds like the same assistant. Last because it is
        //     the only step that waits on the network.
        Task { [weak self] in await self?.persona.loadPersona() }
    }

    // MARK: - Scene phase

    /// The whole `didChangeAppLifecycleState` fan-out.
    ///
    /// `AppLifecycle.isForeground` is set FIRST: the invoke runner reads it to
    /// decide whether a foreground-required skill can run now, and the drain
    /// below would otherwise re-defer everything it just took off the queue.
    func setForeground(_ foreground: Bool) {
        isForeground = foreground
        lifecycle.isForeground = foreground
        if foreground {
            // Coming back: re-open the live bridge immediately rather than
            // waiting out its reconnect backoff, and flush whatever the server
            // queued while we were away.
            if bridge.isPaired && bridge.isBridgeEnabled { bridge.connect() }
            liveActivity.onResume()
            Task { [weak self] in
                guard let self else { return }
                await self.push.drainNow()
                await self.runner.drainPending()
                await self.wake.setForeground(true)
                await self.voice.resumeFromBackground()
            }
        } else {
            voice.pauseForBackground()
            Task { [weak self] in await self?.wake.setForeground(false) }
        }
    }

    // MARK: - URLs

    /// `.onOpenURL`. Shortcut callbacks come first — a `run_shortcut` is blocked
    /// on one and it is never a navigation. Returns true when the URL was ours.
    @discardableResult
    func open(url: URL) -> Bool {
        if shortcuts.deliver(url) { return true }
        return deepLinks.open(url: url)
    }

    /// A tapped home-screen quick action. Returns true when it was one of ours.
    @discardableResult
    func performQuickAction(type: String) -> Bool {
        guard let action = QuickAction.parse(type: type) else { return false }
        return deepLinks.open(action.link)
    }
}

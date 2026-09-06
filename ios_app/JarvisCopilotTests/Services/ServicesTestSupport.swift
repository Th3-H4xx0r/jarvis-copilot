import Foundation
import XCTest
@testable import JarvisCopilot

/// Ordered log of what the app-level wiring did, so `AppServicesTests` can assert
/// the startup SEQUENCE rather than just its effects — the ordering constraints
/// (skills before the socket, the notification delegate before a launch tap) are
/// the part that actually breaks.
@MainActor
final class ServiceRecorder {
    private(set) var calls: [String] = []
    func record(_ name: String) { calls.append(name) }
    func contains(_ name: String) -> Bool { calls.contains(name) }
    /// Index of the first occurrence, or -1. Used for "A before B" assertions.
    func index(_ name: String) -> Int { calls.firstIndex(of: name) ?? -1 }
}

@MainActor
final class FakeSkillInstaller: PhoneSkillInstalling {
    let log: ServiceRecorder
    init(_ log: ServiceRecorder) { self.log = log }
    func installPhoneSkills() { log.record("skills.install") }
}

@MainActor
final class FakeAppBridge: AppBridging {
    let log: ServiceRecorder
    var isPaired: Bool
    var isBridgeEnabled: Bool
    private(set) var connects = 0
    private(set) var registrations = 0

    init(_ log: ServiceRecorder, paired: Bool = true, enabled: Bool = true) {
        self.log = log
        self.isPaired = paired
        self.isBridgeEnabled = enabled
    }

    func connect() { connects += 1; log.record("bridge.connect") }
    func sendRegistration() { registrations += 1; log.record("bridge.register") }
}

@MainActor
final class FakePush: PushStarting {
    let log: ServiceRecorder
    private(set) var drains = 0
    init(_ log: ServiceRecorder) { self.log = log }
    func start() { log.record("push.start") }
    func drainNow() async { drains += 1; log.record("push.drain") }
}

@MainActor
final class FakePersonaLoader: PersonaLoading {
    let log: ServiceRecorder
    private(set) var loads = 0
    init(_ log: ServiceRecorder) { self.log = log }
    func loadPersona() async { loads += 1; log.record("persona.load") }
}

@MainActor
final class FakeWake: WakeControlling {
    let log: ServiceRecorder
    private(set) var foreground: [Bool] = []
    var onWake: (() -> Void)? { didSet { log.record("wake.onWake") } }
    init(_ log: ServiceRecorder) { self.log = log }
    func setForeground(_ isForeground: Bool) async {
        foreground.append(isForeground)
        log.record("wake.foreground=\(isForeground)")
    }
}

@MainActor
final class FakeVoiceLaunch: VoiceLaunchStarting {
    let log: ServiceRecorder
    var onRequest: (() -> Void)?
    init(_ log: ServiceRecorder) { self.log = log }
    func start() { log.record("voiceLaunch.start") }
    /// Simulate Siri / the widget firing.
    func fire() { onRequest?() }
}

@MainActor
final class FakeConnectionWatcher: ConnectionWatching {
    let log: ServiceRecorder
    init(_ log: ServiceRecorder) { self.log = log }
    func start() { log.record("connection.start") }
}

@MainActor
final class FakeLiveActivityCoordinator: LiveActivityCoordinating {
    let log: ServiceRecorder
    private(set) var voiceReports: [VoiceLiveActivitySnapshot] = []
    init(_ log: ServiceRecorder) { self.log = log }
    func start() { log.record("liveActivity.start") }
    func onResume() { log.record("liveActivity.resume") }
    func reportVoice(_ snapshot: VoiceLiveActivitySnapshot) {
        voiceReports.append(snapshot)
        log.record("liveActivity.voice")
    }
}

@MainActor
final class FakeBackgroundLocation: BackgroundLocationStarting {
    let log: ServiceRecorder
    init(_ log: ServiceRecorder) { self.log = log }
    func startIfEnabled() { log.record("location.startIfEnabled") }
}

@MainActor
final class FakePendingDrainer: PendingActionDraining {
    let log: ServiceRecorder
    private(set) var drains = 0
    /// Runs inside the drain, so a test can observe the world as the real runner
    /// would see it (notably `AppLifecycle.isForeground`).
    var observe: (() -> Void)?
    init(_ log: ServiceRecorder) { self.log = log }
    @discardableResult
    func drainPending() async -> Int {
        drains += 1
        observe?()
        log.record("runner.drain")
        return 0
    }
}

@MainActor
final class FakeVoiceLifecycle: VoiceLifecycle {
    let log: ServiceRecorder
    private(set) var asked: [String] = []
    var onPush: ((VoiceLiveActivitySnapshot) -> Void)?
    init(_ log: ServiceRecorder) { self.log = log }
    func pauseForBackground() { log.record("voice.pause") }
    func resumeFromBackground() async { log.record("voice.resume") }
    func attachLiveActivity(_ onPush: @escaping (VoiceLiveActivitySnapshot) -> Void) {
        self.onPush = onPush
        log.record("voice.attach")
    }
    func ask(_ prompt: String) async { asked.append(prompt); log.record("voice.ask") }
}

@MainActor
final class FakeMetrics: MetricsRegistering {
    let log: ServiceRecorder
    init(_ log: ServiceRecorder) { self.log = log }
    func register() { log.record("metrics.register") }
}

/// Records what the coordinator asked ActivityKit to do.
@MainActor
final class FakeActivityController: ActivityControlling {
    var onPushToken: ((String) -> Void)?
    var areActivitiesEnabled = true
    private(set) var updates: [LiveActivityState] = []
    private(set) var ends = 0

    func update(_ state: LiveActivityState) { updates.append(state) }
    func end() { ends += 1 }
    /// Pretend iOS handed us an activity push token.
    func emitToken(_ token: String) { onPushToken?(token) }
}

/// An `IslandDesignCache` that keeps payloads in memory.
final class RecordingIslandCache: IslandDesignCache, @unchecked Sendable {
    private let lock = NSLock()
    private var _cached: [JSONObject] = []
    private var _clears = 0

    var cached: [JSONObject] { lock.lock(); defer { lock.unlock() }; return _cached }
    var clears: Int { lock.lock(); defer { lock.unlock() }; return _clears }

    func cacheDesigns(_ payloads: [JSONObject]) async {
        lock.lock(); _cached.append(contentsOf: payloads); lock.unlock()
    }

    func clearCache() async { lock.lock(); _clears += 1; _cached = []; lock.unlock() }
}

/// A `LocationMonitoring` that never touches CoreLocation.
@MainActor
final class FakeLocationMonitor: LocationMonitoring {
    var onFix: ((LocationFix) -> Void)?
    var isAvailable = true
    var authorized = true
    private(set) var authorizationRequests = 0
    private(set) var starts = 0
    private(set) var stops = 0

    func requestAlwaysAuthorization() async -> Bool {
        authorizationRequests += 1
        return authorized
    }

    func startMonitoring() { starts += 1 }
    func stopMonitoring() { stops += 1 }
    /// Deliver a fix as CoreLocation would.
    func emit(_ fix: LocationFix) { onFix?(fix) }
}

/// Prefetcher that records URLs instead of downloading them.
final class RecordingImagePrefetcher: IslandImagePrefetching, @unchecked Sendable {
    private let lock = NSLock()
    private var _urls: [String] = []
    var urls: [String] { lock.lock(); defer { lock.unlock() }; return _urls }
    func prefetch(_ urls: [String]) { lock.lock(); _urls.append(contentsOf: urls); lock.unlock() }
}

/// Spin the run loop until `condition` holds, so a test can wait on work an
/// implementation kicked off in a detached `Task` without sleeping blindly.
/// Prefixed to avoid the module-wide name collisions other areas hit.
@MainActor
func servicesWaitUntil(timeout: TimeInterval = 2,
                       _ condition: @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

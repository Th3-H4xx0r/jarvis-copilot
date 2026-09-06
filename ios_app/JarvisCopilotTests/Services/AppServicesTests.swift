import Foundation
import XCTest
@testable import JarvisCopilot

/// The startup sequence and the scene-phase fan-out `main.dart` owned.
///
/// The ordering is the point: skills have to be in the registry before the socket
/// advertises them, and `AppLifecycle.isForeground` has to be true before the
/// pending drain runs or every recovered action immediately re-defers.
@MainActor
final class AppServicesTests: XCTestCase {

    private func makeServices(paired: Bool = true, bridgeEnabled: Bool = true)
    -> (AppServices, ServiceRecorder, Fakes) {
        let log = ServiceRecorder()
        let fakes = Fakes(log: log, paired: paired, bridgeEnabled: bridgeEnabled)
        let services = AppServices(
            skills: fakes.skills, registry: fakes.registry, bridge: fakes.bridge,
            push: fakes.push, persona: fakes.persona, wake: fakes.wake,
            voiceLaunch: fakes.voiceLaunch, connection: fakes.connection,
            liveActivity: fakes.liveActivity, location: fakes.location,
            runner: fakes.runner, voice: fakes.voice, metrics: fakes.metrics,
            lifecycle: fakes.lifecycle, pending: fakes.pending, router: fakes.router,
            deepLinks: AppDeepLinkRouter(router: fakes.router, targets: fakes.targets),
            chatLaunch: fakes.chatLaunch, shortcuts: fakes.shortcuts)
        return (services, log, fakes)
    }

    struct Fakes {
        let skills: FakeSkillInstaller
        let registry: SkillRegistry
        let bridge: FakeAppBridge
        let push: FakePush
        let persona: FakePersonaLoader
        let wake: FakeWake
        let voiceLaunch: FakeVoiceLaunch
        let connection: FakeConnectionWatcher
        let liveActivity: FakeLiveActivityCoordinator
        let location: FakeBackgroundLocation
        let runner: FakePendingDrainer
        let voice: FakeVoiceLifecycle
        let metrics: FakeMetrics
        let lifecycle: AppLifecycle
        let pending: PendingActions
        let router: AppRouter
        let targets: DeepLinkTargets
        let chatLaunch: ChatLaunchBus
        let shortcuts: ShortcutResultBus

        @MainActor
        init(log: ServiceRecorder, paired: Bool, bridgeEnabled: Bool) {
            skills = FakeSkillInstaller(log)
            // A registry of its own: the process-wide one is full of real skills
            // and shared with every other test in the suite.
            registry = SkillRegistry(store: MemoryKeyValueStore())
            bridge = FakeAppBridge(log, paired: paired, enabled: bridgeEnabled)
            push = FakePush(log)
            persona = FakePersonaLoader(log)
            wake = FakeWake(log)
            voiceLaunch = FakeVoiceLaunch(log)
            connection = FakeConnectionWatcher(log)
            liveActivity = FakeLiveActivityCoordinator(log)
            location = FakeBackgroundLocation(log)
            runner = FakePendingDrainer(log)
            voice = FakeVoiceLifecycle(log)
            metrics = FakeMetrics(log)
            lifecycle = AppLifecycle()
            pending = PendingActions()
            router = AppRouter()
            targets = DeepLinkTargets()
            chatLaunch = ChatLaunchBus()
            shortcuts = ShortcutResultBus()
        }
    }

    // MARK: Startup

    func testStartRunsEveryServiceInOrder() async {
        let (services, log, _) = makeServices()
        services.start()
        await servicesWaitUntil { log.contains("runner.drain") }

        XCTAssertEqual(log.calls.prefix(3).map { $0 },
                       ["skills.install", "bridge.connect", "push.start"],
                       "skills must be registered before the socket advertises them, "
                       + "and push before iOS can deliver a launch tap")
        for name in ["wake.onWake", "voiceLaunch.start", "connection.start",
                     "voice.attach", "liveActivity.start", "location.startIfEnabled",
                     "metrics.register", "runner.drain"] {
            XCTAssertTrue(log.contains(name), "missing \(name) — got \(log.calls)")
        }
        XCTAssertLessThan(log.index("voice.attach"), log.index("liveActivity.start"),
                          "the coordinator must be listening before it starts polling")
    }

    /// The local model has no idea who JARVIS is; without this a locally answered
    /// turn sounds like a different assistant mid-conversation.
    func testStartLoadsTheServersActivePersonality() async {
        let (services, log, fakes) = makeServices()
        services.start()
        await servicesWaitUntil { log.contains("persona.load") }
        XCTAssertEqual(fakes.persona.loads, 1)
    }

    /// Switching a skill off in the Skills tab is a real ACL — it leaves the
    /// bridge manifest — so the server has to be told while the app is running,
    /// not on the next reconnect.
    func testASkillToggleReAdvertisesTheCatalogue() async {
        let (services, _, fakes) = makeServices()
        services.start()
        let before = fakes.bridge.registrations

        fakes.registry.setEnabled(false, for: "open_url")
        XCTAssertEqual(fakes.bridge.registrations, before + 1)

        fakes.registry.setEnabled(true, for: "open_url")
        XCTAssertEqual(fakes.bridge.registrations, before + 2)
    }

    /// A no-op toggle changes no generation, so it must not churn the socket.
    func testAnUnchangedSkillToggleSendsNothing() async {
        let (services, _, fakes) = makeServices()
        services.start()
        let before = fakes.bridge.registrations
        fakes.registry.setEnabled(true, for: "open_url")   // already enabled
        XCTAssertEqual(fakes.bridge.registrations, before)
    }

    /// The bulk install registers ~30 skills; hooking up before it would send ~30
    /// register frames on every launch.
    func testInstallingTheCatalogueDoesNotStormTheSocket() async {
        let (services, _, fakes) = makeServices()
        fakes.registry.register(AnySkill(name: "a", description: "a") { _ in [:] })
        services.start()
        let after = fakes.bridge.registrations
        fakes.registry.register(AnySkill(name: "b", description: "b") { _ in [:] })
        XCTAssertEqual(fakes.bridge.registrations, after + 1,
                       "one frame per change, and nothing for the launch install")
    }

    func testStartIsIdempotent() async {
        let (services, log, _) = makeServices()
        services.start()
        services.start()
        await servicesWaitUntil { log.contains("runner.drain") }
        XCTAssertEqual(log.calls.filter { $0 == "skills.install" }.count, 1)
        XCTAssertTrue(services.didStart)
    }

    func testUnpairedDeviceNeverConnectsTheBridge() async {
        let (services, log, _) = makeServices(paired: false)
        services.start()
        await servicesWaitUntil { log.contains("metrics.register") }
        XCTAssertFalse(log.contains("bridge.connect"))
        XCTAssertTrue(log.contains("push.start"), "push still starts so a later pair can register")
    }

    func testBridgeModeOffNeverConnects() async {
        let (services, log, _) = makeServices(bridgeEnabled: false)
        services.start()
        await servicesWaitUntil { log.contains("metrics.register") }
        XCTAssertFalse(log.contains("bridge.connect"))
    }

    func testWakeWordAndVoiceLaunchBothRequestVoice() async {
        let (services, _, fakes) = makeServices()
        services.start()
        fakes.wake.onWake?()
        XCTAssertEqual(fakes.router.selectedTab, .voice)
        XCTAssertTrue(fakes.router.voiceLaunchRequested)

        fakes.router.consumeVoiceLaunch()
        fakes.voiceLaunch.fire()
        XCTAssertTrue(fakes.router.voiceLaunchRequested)
        XCTAssertEqual(fakes.router.voiceLaunchGeneration, 2)
    }

    func testVoiceSnapshotsAreForwardedToTheLiveActivityCoordinator() async {
        let (services, _, fakes) = makeServices()
        services.start()
        let snapshot = VoiceLiveActivitySnapshot(
            state: "listening", transcript: "hello", activity: "",
            connected: true, devices: ["phone"])
        fakes.voice.onPush?(snapshot)
        XCTAssertEqual(fakes.liveActivity.voiceReports, [snapshot])
    }

    func testAskJarvisFallsBackToTheVoiceLifecycleSender() async {
        let (services, log, fakes) = makeServices()
        services.start()
        fakes.chatLaunch.request("  what is my next meeting  ")
        await servicesWaitUntil { log.contains("voice.ask") }
        XCTAssertEqual(fakes.voice.asked, ["what is my next meeting"])
        XCTAssertEqual(fakes.router.selectedTab, .chat)
        XCTAssertNil(fakes.chatLaunch.pendingPrompt, "a dispatched prompt must not also latch")
    }

    func testAskJarvisLatchesWhenNoSenderIsRegistered() {
        let bus = ChatLaunchBus()
        bus.request("hello")
        XCTAssertEqual(bus.pendingPrompt, "hello")
        XCTAssertEqual(bus.consume(), "hello")
        XCTAssertNil(bus.consume(), "the latch is taken exactly once")
    }

    func testEmptyAskIsIgnored() {
        let bus = ChatLaunchBus()
        bus.request("   ")
        XCTAssertNil(bus.pendingPrompt)
        XCTAssertEqual(bus.generation, 0)
    }

    // MARK: Scene phase

    func testGoingToBackgroundPausesVoiceAndTheWakeWord() async {
        let (services, log, fakes) = makeServices()
        services.start()
        services.setForeground(false)
        await servicesWaitUntil { log.contains("wake.foreground=false") }

        XCTAssertFalse(fakes.lifecycle.isForeground)
        XCTAssertTrue(log.contains("voice.pause"))
        XCTAssertEqual(fakes.wake.foreground.last, false)
        XCTAssertFalse(services.isForeground)
    }

    func testReturningToForegroundReconnectsDrainsAndResumes() async {
        let (services, log, fakes) = makeServices()
        services.start()
        services.setForeground(false)
        await servicesWaitUntil { log.contains("wake.foreground=false") }
        let connectsBefore = fakes.bridge.connects

        services.setForeground(true)
        await servicesWaitUntil { log.contains("voice.resume") }

        XCTAssertTrue(fakes.lifecycle.isForeground)
        XCTAssertEqual(fakes.bridge.connects, connectsBefore + 1,
                       "don't wait out the reconnect backoff on resume")
        XCTAssertTrue(log.contains("liveActivity.resume"))
        XCTAssertEqual(fakes.push.drains, 1)
        XCTAssertEqual(fakes.wake.foreground.last, true)
    }

    func testForegroundDrainSeesTheLifecycleFlagAlreadySet() async {
        // The invoke runner reads `AppLifecycle.isForeground` to decide whether a
        // foreground-required skill can run; draining first would re-defer them all.
        let (services, log, fakes) = makeServices()
        services.start()
        services.setForeground(false)
        await servicesWaitUntil { log.contains("wake.foreground=false") }

        var flagWhenDrained: Bool?
        fakes.runner.observe = { flagWhenDrained = fakes.lifecycle.isForeground }
        services.setForeground(true)
        await servicesWaitUntil { log.contains("voice.resume") }
        XCTAssertEqual(flagWhenDrained, true)
    }

    // MARK: URLs and quick actions

    func testShortcutCallbacksAreDeliveredBeforeDeepLinkRouting() {
        let (services, _, fakes) = makeServices()
        services.start()
        let url = URL(string: "jarviscopilot://shortcut-result/sc123?result=42")!
        XCTAssertTrue(services.open(url: url))
        XCTAssertEqual(fakes.router.selectedTab, .chat, "a shortcut result is not navigation")
    }

    func testVoiceDeepLinkOpensVoice() {
        let (services, _, fakes) = makeServices()
        services.start()
        XCTAssertTrue(services.open(url: URL(string: "jarviscopilot://voice")!))
        XCTAssertEqual(fakes.router.selectedTab, .voice)
        XCTAssertTrue(fakes.router.voiceLaunchRequested)
    }

    func testForeignURLIsNotHandled() {
        let (services, _, _) = makeServices()
        services.start()
        XCTAssertFalse(services.open(url: URL(string: "https://example.com/voice")!))
    }

    func testQuickActionRoutesLikeItsDeepLink() {
        let (services, _, fakes) = makeServices()
        services.start()
        XCTAssertTrue(services.performQuickAction(type: QuickAction.coding.rawValue))
        XCTAssertEqual(fakes.router.selectedTab, .coding)
        XCTAssertFalse(services.performQuickAction(type: "com.example.nope"))
    }
}

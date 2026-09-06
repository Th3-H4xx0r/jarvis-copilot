import AVFoundation
import XCTest
@testable import JarvisCopilot

/// The keepalive half of the audio-session arbitration.
///
/// Companion to `BackgroundKeepaliveTests` (Services/), which covers the pure
/// arming decision. This file exercises the platform half through the two seams
/// `BackgroundKeepalive` now has — the `AudioSessionArbiter` and the
/// `KeepaliveAudioEngine` — so none of it needs real hardware or the
/// process-wide session. `BackgroundKeepalive.shared` is never touched here.
///
/// Named `…ArbiterTests` and not `BackgroundKeepaliveTests` because a class name
/// is module-wide in this test target and the Services file already owns that
/// one.
@MainActor
final class BackgroundKeepaliveArbiterTests: XCTestCase {

    private struct Rig {
        let keepalive: BackgroundKeepalive
        let arbiter: AudioSessionArbiter
        let applier: MockAudioSessionApplying
        let engine: MockKeepaliveEngine
        let center: NotificationCenter
    }

    private func makeRig() -> Rig {
        let applier = MockAudioSessionApplying()
        let arbiter = AudioSessionArbiter(session: applier)
        let engine = MockKeepaliveEngine()
        // A private centre: the real one would deliver system audio notifications
        // into the test and make it flaky.
        let center = NotificationCenter()
        let keepalive = BackgroundKeepalive(arbiter: arbiter, engine: engine, center: center)
        return Rig(keepalive: keepalive, arbiter: arbiter, applier: applier,
                   engine: engine, center: center)
    }

    // MARK: - Start / stop

    func testStartingClaimsPlaybackAndRunsTheSilentEngine() {
        let rig = makeRig()
        rig.keepalive.sync(active: true)

        XCTAssertTrue(rig.keepalive.isRunning)
        XCTAssertTrue(rig.arbiter.holds(.keepalive))
        XCTAssertEqual(rig.applier.category, .playback)
        XCTAssertTrue(rig.applier.isActive)
        XCTAssertEqual(rig.engine.startCount, 1)
    }

    func testASessionThatRefusesLeavesTheKeepaliveStopped() {
        let rig = makeRig()
        rig.applier.categoryError = VoiceAudioError.micUnavailable("refused")
        rig.keepalive.sync(active: true)

        XCTAssertFalse(rig.keepalive.isRunning)
        XCTAssertFalse(rig.arbiter.holds(.keepalive))
        XCTAssertEqual(rig.engine.startCount, 0, "no point playing silence into a dead session")
    }

    func testAnEngineThatWontStartReleasesTheSessionAgain() {
        let rig = makeRig()
        rig.engine.startSucceeds = false
        rig.keepalive.sync(active: true)

        XCTAssertFalse(rig.keepalive.isRunning)
        XCTAssertFalse(rig.arbiter.holds(.keepalive),
                       "holding a session we are not playing into buys nothing and costs battery")
        XCTAssertFalse(rig.applier.isActive)
    }

    func testStoppingReleasesTheSessionAndTheEngine() {
        let rig = makeRig()
        rig.keepalive.sync(active: true)
        rig.keepalive.sync(active: false)

        XCTAssertFalse(rig.keepalive.isRunning)
        XCTAssertFalse(rig.arbiter.holds(.keepalive))
        XCTAssertFalse(rig.applier.isActive)
        XCTAssertEqual(rig.engine.stopCount, 1)
    }

    func testStoppingSomethingThatNeverStartedTouchesNothing() {
        let rig = makeRig()
        rig.keepalive.sync(active: false)

        XCTAssertTrue(rig.applier.calls.isEmpty, "don't deactivate a session we never claimed")
    }

    func testStartingTwiceDoesNotRestartTheEngine() {
        let rig = makeRig()
        rig.keepalive.sync(active: true)
        rig.keepalive.sync(active: true)

        XCTAssertEqual(rig.engine.startCount, 1)
    }

    // MARK: - Living alongside a voice turn

    func testStoppingDuringAVoiceTurnKeepsTheRecordingSessionAlive() throws {
        let rig = makeRig()
        rig.keepalive.sync(active: true)
        try rig.arbiter.hold(.voice)

        rig.keepalive.sync(active: false)

        XCTAssertEqual(rig.applier.category, .playAndRecord, "the live turn keeps its mic")
        XCTAssertTrue(rig.applier.isActive)
    }

    /// The regression this whole change is about: a voice turn switches the
    /// category out from under the silent engine, which stops itself and posts
    /// `AVAudioEngineConfigurationChange`. If we don't restart it the app loses
    /// its background allowance the moment the turn ends.
    func testTheSilentEngineRestartsAfterACategorySwitch() throws {
        let rig = makeRig()
        rig.keepalive.sync(active: true)
        try rig.arbiter.hold(.voice) // .playback → .playAndRecord

        rig.engine.simulateStoppedByTheSystem()
        rig.center.post(name: .AVAudioEngineConfigurationChange, object: nil)

        XCTAssertEqual(rig.engine.startCount, 2)
        XCTAssertTrue(rig.engine.isRunning)
        XCTAssertEqual(rig.applier.category, .playAndRecord,
                       "restarting the silent engine must not steal the mic back")
    }

    func testAConfigurationChangeWithAHealthyEngineIsIgnored() {
        let rig = makeRig()
        rig.keepalive.sync(active: true)
        rig.center.post(name: .AVAudioEngineConfigurationChange, object: nil)

        XCTAssertEqual(rig.engine.startCount, 1, "nothing stopped; don't churn the engine")
    }

    func testAConfigurationChangeWhileStoppedIsIgnored() {
        let rig = makeRig()
        rig.center.post(name: .AVAudioEngineConfigurationChange, object: nil)

        XCTAssertEqual(rig.engine.startCount, 0)
        XCTAssertTrue(rig.applier.calls.isEmpty)
    }

    // MARK: - Interruptions

    func testAnEndedInterruptionReassertsTheSessionAndTheEngine() {
        let rig = makeRig()
        rig.keepalive.sync(active: true)
        rig.engine.simulateStoppedByTheSystem()

        rig.center.post(name: AVAudioSession.interruptionNotification, object: nil, userInfo: [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
        ])

        XCTAssertEqual(rig.engine.startCount, 2)
        XCTAssertEqual(rig.applier.calls.last, .active(true, []), "re-activated, not merely believed active")
    }

    func testABeginningInterruptionChangesNothing() {
        let rig = makeRig()
        rig.keepalive.sync(active: true)
        let after = rig.applier.calls.count

        rig.center.post(name: AVAudioSession.interruptionNotification, object: nil, userInfo: [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue,
        ])

        XCTAssertEqual(rig.applier.calls.count, after)
        XCTAssertEqual(rig.engine.startCount, 1)
    }

    func testAMediaServicesResetRebuildsEverything() {
        let rig = makeRig()
        rig.keepalive.sync(active: true)
        rig.engine.simulateStoppedByTheSystem()

        rig.center.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)

        XCTAssertEqual(rig.engine.startCount, 2)
        XCTAssertTrue(rig.keepalive.isRunning)
    }

    func testNotificationsAfterAStopAreIgnored() {
        let rig = makeRig()
        rig.keepalive.sync(active: true)
        rig.keepalive.sync(active: false)
        let after = rig.engine.startCount

        rig.center.post(name: .AVAudioEngineConfigurationChange, object: nil)
        rig.center.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)

        XCTAssertEqual(rig.engine.startCount, after, "a stopped keepalive stays stopped")
        XCTAssertFalse(rig.applier.isActive)
    }
}

// MARK: - Mock

/// The silent-audio engine boundary. The real one is an `AVAudioEngine` looping
/// a buffer of zeros; what matters to the keepalive is only whether it is
/// running and whether a restart succeeded.
@MainActor
final class MockKeepaliveEngine: KeepaliveAudioEngine {
    var startSucceeds = true
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var isRunning = false

    func start() -> Bool {
        startCount += 1
        isRunning = startSucceeds
        return startSucceeds
    }

    func stop() {
        stopCount += 1
        isRunning = false
    }

    /// What `AVAudioEngine` does on its own when the session category changes or
    /// media services restart: it stops, without anyone calling `stop()`.
    func simulateStoppedByTheSystem() { isRunning = false }
}

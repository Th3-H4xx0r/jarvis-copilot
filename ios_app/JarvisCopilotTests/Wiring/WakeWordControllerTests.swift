import XCTest
@testable import JarvisCopilot

/// A `WakeService` stand-in: records what the controller asked of it without
/// touching a microphone or the speech recognizer.
@MainActor
final class FakeWakeListener: WakeListening {
    var onWake: (() -> Void)?
    /// Make `setEnabled(true)` refuse, as a denied mic permission does.
    var permission = true

    private(set) var enabledCalls: [Bool] = []
    private(set) var foregroundCalls: [Bool] = []
    private(set) var suppressCount = 0
    private(set) var resumeCount = 0

    @discardableResult
    func setEnabled(_ on: Bool) async -> Bool {
        guard on else { enabledCalls.append(false); return true }
        guard permission else { return false }
        enabledCalls.append(true)
        return true
    }

    func suppress() async { suppressCount += 1 }
    func resume() async { resumeCount += 1 }
    func setForeground(_ isForeground: Bool) async { foregroundCalls.append(isForeground) }
}

/// `WakeService` existed but was never instantiated; this is the object that
/// owns its lifetime. Everything here is about the microphone: it is
/// single-owner, foreground-only, and expensive to hold when nobody asked for it.
@MainActor
final class WakeWordControllerTests: XCTestCase {

    private struct Rig {
        let controller: WakeWordController
        let settings: VoiceSettings
        let store: MemoryKeyValueStore
        let listeners: ListenerBox
        let clock: TestVoiceClock
    }

    /// Counts how many listeners were built, and hands back the latest.
    @MainActor
    final class ListenerBox {
        private(set) var made: [FakeWakeListener] = []
        var latest: FakeWakeListener? { made.last }
        func record(_ listener: FakeWakeListener) { made.append(listener) }
    }

    private func makeRig(wakeWordOn: Bool = false) -> Rig {
        let store = MemoryKeyValueStore()
        if wakeWordOn { store.set(true, forKey: VoiceSettings.wakeWordKey) }
        let settings = VoiceSettings(store: store)
        let box = ListenerBox()
        let clock = TestVoiceClock()
        let controller = WakeWordController(settings: settings, make: { _ in
            let listener = FakeWakeListener()
            box.record(listener)
            return listener
        }, clock: clock)
        return Rig(controller: controller, settings: settings, store: store, listeners: box,
                   clock: clock)
    }

    // MARK: Lazy creation

    /// The listener holds its own `AVAudioEngine`; building one for a user who
    /// never asked for the wake word is pure cost.
    func testNothingIsBuiltWhileTheSettingIsOff() async {
        let rig = makeRig(wakeWordOn: false)
        await rig.controller.setForeground(true)
        XCTAssertTrue(rig.listeners.made.isEmpty)
        XCTAssertFalse(rig.controller.isListening)
    }

    func testTheListenerIsArmedOnLaunchWhenTheSettingWasLeftOn() async {
        let rig = makeRig(wakeWordOn: true)
        await rig.controller.setForeground(true)
        XCTAssertEqual(rig.listeners.made.count, 1)
        XCTAssertEqual(rig.listeners.latest?.foregroundCalls, [true])
        XCTAssertTrue(rig.controller.isListening)
    }

    func testASecondForegroundDoesNotBuildASecondListener() async {
        let rig = makeRig(wakeWordOn: true)
        await rig.controller.setForeground(true)
        await rig.controller.setForeground(false)
        await rig.controller.setForeground(true)
        XCTAssertEqual(rig.listeners.made.count, 1, "one mic tap, one listener")
        XCTAssertEqual(rig.listeners.latest?.foregroundCalls, [true, false, true])
    }

    // MARK: The toolbar switch

    /// The point of the whole class: flipping the switch has to start listening
    /// NOW, not on the next launch.
    func testTurningItOnStartsListeningLive() async {
        let rig = makeRig(wakeWordOn: false)
        await rig.controller.setForeground(true)
        let ok = await rig.controller.setEnabled(true)

        XCTAssertTrue(ok)
        XCTAssertEqual(rig.listeners.made.count, 1)
        XCTAssertEqual(rig.listeners.latest?.enabledCalls, [true])
        XCTAssertEqual(rig.listeners.latest?.foregroundCalls, [true])
        XCTAssertEqual(rig.store.bool(VoiceSettings.wakeWordKey), true, "and it survives a relaunch")
    }

    func testTurningItOffReleasesTheListener() async {
        let rig = makeRig(wakeWordOn: true)
        await rig.controller.setForeground(true)
        let listener = rig.listeners.latest

        let ok = await rig.controller.setEnabled(false)

        XCTAssertTrue(ok)
        XCTAssertEqual(listener?.enabledCalls, [false])
        XCTAssertFalse(rig.controller.isListening)
        XCTAssertEqual(rig.store.bool(VoiceSettings.wakeWordKey), false)
    }

    /// A switch that reads "on" while nothing is listening is worse than one that
    /// snaps back.
    func testARefusedMicLeavesNothingListening() async {
        let rig = makeRig(wakeWordOn: false)
        let box = rig.listeners
        let controller = WakeWordController(settings: rig.settings) { _ in
            let listener = FakeWakeListener()
            listener.permission = false
            box.record(listener)
            return listener
        }

        let ok = await controller.setEnabled(true)

        XCTAssertFalse(ok)
        XCTAssertFalse(controller.isListening)
        XCTAssertNil(rig.store.bool(VoiceSettings.wakeWordKey),
                     "a refused permission must not persist as 'on'")
    }

    // MARK: Voice turns

    /// The mic cannot be shared: a turn taking it must fully stop the listener,
    /// and a turn ending must give it back or the wake word is dead until relaunch.
    func testAVoiceTurnSuppressesAndThenResumesTheListener() async {
        let rig = makeRig(wakeWordOn: true)
        await rig.controller.setForeground(true)

        await rig.controller.setVoiceActive(true)
        XCTAssertEqual(rig.listeners.latest?.suppressCount, 1)
        XCTAssertEqual(rig.listeners.latest?.resumeCount, 0)

        await rig.controller.setVoiceActive(false)
        XCTAssertEqual(rig.listeners.latest?.resumeCount, 1)
    }

    /// `onChange(initial: true)` fires on every re-render; only real transitions
    /// may touch the mic.
    func testRepeatingTheSameVoiceStateIsANoOp() async {
        let rig = makeRig(wakeWordOn: true)
        await rig.controller.setForeground(true)
        await rig.controller.setVoiceActive(true)
        await rig.controller.setVoiceActive(true)
        XCTAssertEqual(rig.listeners.latest?.suppressCount, 1)
    }

    /// Turning the wake word on mid-conversation must not steal the mic from the
    /// live turn.
    func testEnablingDuringALiveTurnStaysSuppressed() async {
        let rig = makeRig(wakeWordOn: false)
        await rig.controller.setForeground(true)
        await rig.controller.setVoiceActive(true)
        await rig.controller.setEnabled(true)
        XCTAssertEqual(rig.listeners.latest?.suppressCount, 1)
    }

    // MARK: onWake

    func testTheWakeCallbackReachesALaterBuiltListener() async {
        let rig = makeRig(wakeWordOn: true)
        var fired = 0
        rig.controller.onWake = { fired += 1 }
        await rig.controller.setForeground(true)

        rig.listeners.latest?.onWake?()
        XCTAssertEqual(fired, 1)
    }

    // MARK: A wake that never becomes a turn

    /// `WakeService` latches `suppressed` the instant the phrase is heard, and
    /// ONLY `resume()` clears it — which arrives via `setVoiceActive(false)`, i.e.
    /// only if a turn became active first. When one never does (the mic is refused
    /// in `ensureMic`, or `VoicePage` never enters the hierarchy to report the
    /// state) the wake word was dead for the rest of the launch: saying "Hey
    /// Jarvis" again did nothing at all, with no way for the user to notice why.
    func testAWakeThatNeverBecomesATurnGivesTheMicBack() async {
        let rig = makeRig(wakeWordOn: true)
        var fired = 0
        rig.controller.onWake = { fired += 1 }
        await rig.controller.setForeground(true)

        rig.listeners.latest?.onWake?()
        XCTAssertEqual(fired, 1, "the app still gets its wake, unchanged")
        XCTAssertEqual(rig.listeners.latest?.resumeCount, 0, "the turn still has time to start")

        rig.clock.advance(ms: WakeWordController.wakeHandoffMs + 1)
        await settleVoiceTasks()

        XCTAssertEqual(rig.listeners.latest?.resumeCount, 1,
                       "nothing took the mic, so the listener takes it back")
    }

    /// The normal path: the turn shows up, so the deadline must not fire and steal
    /// the mic back from under it.
    func testAWakeThatBecomesATurnIsNotResumedByTheDeadline() async {
        let rig = makeRig(wakeWordOn: true)
        await rig.controller.setForeground(true)

        rig.listeners.latest?.onWake?()
        await rig.controller.setVoiceActive(true)
        XCTAssertEqual(rig.listeners.latest?.suppressCount, 1)

        rig.clock.advance(ms: WakeWordController.wakeHandoffMs * 3)
        await settleVoiceTasks()

        XCTAssertEqual(rig.listeners.latest?.resumeCount, 0, "the live turn keeps the mic")
        XCTAssertEqual(rig.clock.pendingTimers, 0, "and the deadline was cancelled, not left armed")

        await rig.controller.setVoiceActive(false)
        XCTAssertEqual(rig.listeners.latest?.resumeCount, 1, "the turn ending still resumes it")
    }

    /// Re-entering the foreground is the other signal that the hand-off is never
    /// happening. `setForeground(true)` alone cannot fix it: `WakeService.maybeListen`
    /// is guarded by `!suppressed`, so the stale latch swallows it silently.
    func testComingBackToTheForegroundClearsAStaleWakeSuppression() async {
        let rig = makeRig(wakeWordOn: true)
        await rig.controller.setForeground(true)
        rig.listeners.latest?.onWake?()

        await rig.controller.setForeground(false)
        await rig.controller.setForeground(true)

        XCTAssertEqual(rig.listeners.latest?.resumeCount, 1)
        XCTAssertEqual(rig.listeners.latest?.foregroundCalls, [true, false, true])

        // The deadline went with it — one resume, not two.
        rig.clock.advance(ms: WakeWordController.wakeHandoffMs * 2)
        await settleVoiceTasks()
        XCTAssertEqual(rig.listeners.latest?.resumeCount, 1)
    }

    /// An ordinary foreground return with no wake pending must not poke the mic.
    func testAPlainForegroundReturnDoesNotResume() async {
        let rig = makeRig(wakeWordOn: true)
        await rig.controller.setForeground(true)
        await rig.controller.setForeground(false)
        await rig.controller.setForeground(true)
        XCTAssertEqual(rig.listeners.latest?.resumeCount, 0)
    }
}

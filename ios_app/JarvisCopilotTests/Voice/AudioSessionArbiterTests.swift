import AVFoundation
import XCTest
@testable import JarvisCopilot

/// `AVAudioSession` is process-wide and this app has two long-lived owners:
/// `BackgroundKeepalive` (silent audio, `.playback`, armed for the whole launch
/// on a paired phone) and the voice stack (`.playAndRecord`/`.videoChat`).
/// Before `AudioSessionArbiter` they wrote the session directly and clobbered
/// each other:
///
///  * keepalive winning → `.playback`, which cannot record: `AVAudioEngine`
///    reports no input route and every turn dies with "Could not start
///    recording: no input route";
///  * voice ending → `setActive(false)` under a keepalive whose silent engine is
///    still running, so the app quietly loses its background allowance.
///
/// These cases pin the union rule (voice wins the category, the session stays
/// active while ANY client holds it) at the one place that talks to CoreAudio.
@MainActor
final class AudioSessionArbiterTests: XCTestCase {

    private func makeArbiter() -> (AudioSessionArbiter, MockAudioSessionApplying) {
        let applier = MockAudioSessionApplying()
        return (AudioSessionArbiter(session: applier), applier)
    }

    // MARK: - The truth table (none / keepalive / voice / both)

    func testNobodyHoldingMeansTheSessionIsNotActive() {
        XCTAssertFalse(AudioSessionArbiter.plan(for: []).active)
    }

    func testKeepaliveAloneAsksForPlaybackThatMixes() {
        let plan = AudioSessionArbiter.plan(for: [.keepalive])
        XCTAssertEqual(plan.category, .playback)
        XCTAssertEqual(plan.mode, .default)
        XCTAssertEqual(plan.options, [.mixWithOthers])
        XCTAssertTrue(plan.active)
    }

    func testVoiceAloneAsksForSpeakerphoneRecording() {
        let plan = AudioSessionArbiter.plan(for: [.voice])
        XCTAssertEqual(plan.category, .playAndRecord)
        XCTAssertEqual(plan.mode, .videoChat, "echo cancellation, or the reply feeds back into the mic")
        XCTAssertTrue(plan.options.contains(.defaultToSpeaker))
        XCTAssertTrue(plan.options.contains(.allowBluetoothA2DP))
        XCTAssertTrue(plan.options.contains(.mixWithOthers),
                      "the keepalive's silent engine has to keep mixing under a voice turn")
        XCTAssertTrue(plan.active)
    }

    func testVoiceWinsWhenBothHold() {
        XCTAssertEqual(AudioSessionArbiter.plan(for: [.voice, .keepalive]),
                       AudioSessionArbiter.plan(for: [.voice]),
                       ".playAndRecord earns background audio too, so voice can simply win")
    }

    // MARK: - The third client: a `record_audio` clip

    func testRecordingAloneAsksForPlayAndRecordThatMixes() {
        let plan = AudioSessionArbiter.plan(for: [.recording])
        XCTAssertEqual(plan.category, .playAndRecord, "a clip cannot be captured under .playback")
        XCTAssertEqual(plan.mode, .default,
                       ".videoChat would run AEC over the very audio we were asked to capture")
        XCTAssertEqual(plan.options, [.mixWithOthers, .defaultToSpeaker])
        XCTAssertTrue(plan.active)
    }

    func testRecordingOutranksTheKeepalive() {
        XCTAssertEqual(AudioSessionArbiter.plan(for: [.recording, .keepalive]),
                       AudioSessionArbiter.plan(for: [.recording]),
                       ".playback has no input route, so a clip capture has to win over it")
    }

    /// The precedence that matters: a clip recorded DURING a turn must not drop
    /// the conversation's echo cancellation and speakerphone route.
    func testVoiceOutranksARecordingClip() {
        XCTAssertEqual(AudioSessionArbiter.plan(for: [.voice, .recording]),
                       AudioSessionArbiter.plan(for: [.voice]))
        XCTAssertEqual(AudioSessionArbiter.plan(for: [.voice, .recording, .keepalive]),
                       AudioSessionArbiter.plan(for: [.voice]))
    }

    /// The whole truth table over the three clients, so a fourth one cannot be
    /// added without deciding where it sits.
    func testEveryCombinationResolvesToTheStrongestClaim() {
        let expected: [(Set<AudioSessionClient>, AudioSessionPlan)] = [
            ([], .init(category: .playback, mode: .default, options: [.mixWithOthers], active: false)),
            ([.keepalive], AudioSessionArbiter.keepalivePlan),
            ([.recording], AudioSessionArbiter.recordingPlan),
            ([.voice], AudioSessionArbiter.voicePlan),
            ([.keepalive, .recording], AudioSessionArbiter.recordingPlan),
            ([.keepalive, .voice], AudioSessionArbiter.voicePlan),
            ([.recording, .voice], AudioSessionArbiter.voicePlan),
            ([.keepalive, .recording, .voice], AudioSessionArbiter.voicePlan),
        ]
        XCTAssertEqual(expected.count, 1 << AudioSessionClient.allCases.count,
                       "a client was added without a row here")
        for (holders, plan) in expected {
            XCTAssertEqual(AudioSessionArbiter.plan(for: holders), plan, "\(holders)")
        }
    }

    /// Applied against a live session: a clip taken while the keepalive is armed
    /// switches the category up and hands it straight back, still active.
    func testAClipCaptureUnderTheKeepaliveGivesTheCategoryBackWhenItEnds() throws {
        let (arbiter, applier) = makeArbiter()
        try arbiter.hold(.keepalive)
        try arbiter.hold(.recording)

        XCTAssertEqual(applier.category, .playAndRecord)
        XCTAssertEqual(applier.mode, .default)
        XCTAssertTrue(applier.isActive)

        try arbiter.release(.recording)
        XCTAssertEqual(applier.category, .playback, "the keepalive's category comes back")
        XCTAssertTrue(applier.isActive, "and it never loses the session")
        XCTAssertFalse(applier.calls.contains(.active(false, [.notifyOthersOnDeactivation])))
    }

    /// A clip ending under a LIVE turn must not pull the conversation's session
    /// out — the bug the arbiter exists to prevent, in its third shape.
    func testAClipEndingDoesNotDisturbALiveVoiceTurn() throws {
        let (arbiter, applier) = makeArbiter()
        try arbiter.hold(.voice)
        try arbiter.hold(.recording)
        let after = applier.calls.count
        try arbiter.release(.recording)

        XCTAssertEqual(applier.calls.count, after, "nothing to re-apply — voice still wins")
        XCTAssertEqual(applier.category, .playAndRecord)
        XCTAssertEqual(applier.mode, .videoChat)
        XCTAssertTrue(applier.isActive)
    }

    func testTheLastReleaseOfAClipDeactivatesTheSession() throws {
        let (arbiter, applier) = makeArbiter()
        try arbiter.hold(.recording)
        try arbiter.release(.recording)

        XCTAssertFalse(applier.isActive)
        XCTAssertEqual(applier.calls.last, .active(false, [.notifyOthersOnDeactivation]))
    }

    // MARK: - Applying the plan

    func testHoldingTheKeepaliveConfiguresAndActivatesPlayback() throws {
        let (arbiter, applier) = makeArbiter()
        try arbiter.hold(.keepalive)

        XCTAssertEqual(applier.calls, [.category(.playback, .default, [.mixWithOthers]),
                                       .active(true, [])])
        XCTAssertTrue(arbiter.holds(.keepalive))
    }

    func testHoldingIsIdempotentAgainstTheLiveSession() throws {
        let (arbiter, applier) = makeArbiter()
        try arbiter.hold(.keepalive)
        let after = applier.calls.count
        try arbiter.hold(.keepalive)

        XCTAssertEqual(applier.calls.count, after, "re-holding must not churn the route")
    }

    func testVoiceHoldSwitchesTheLiveSessionToRecording() throws {
        let (arbiter, applier) = makeArbiter()
        try arbiter.hold(.keepalive)
        try arbiter.hold(.voice)

        XCTAssertEqual(applier.category, .playAndRecord)
        XCTAssertEqual(applier.mode, .videoChat)
        XCTAssertTrue(applier.isActive)
        XCTAssertFalse(applier.calls.contains(.active(false, [.notifyOthersOnDeactivation])),
                       "no deactivation in the middle of a category switch")
    }

    // MARK: - The two bugs this class exists to prevent

    func testVoiceEndingDoesNotDeactivateASessionTheKeepaliveStillHolds() throws {
        let (arbiter, applier) = makeArbiter()
        try arbiter.hold(.keepalive)
        try arbiter.hold(.voice)
        try arbiter.release(.voice)

        XCTAssertTrue(applier.isActive, "the keepalive still needs the session")
        XCTAssertEqual(applier.category, .playback, "back down to the cheap category, still active")
        XCTAssertFalse(applier.calls.contains(.active(false, [.notifyOthersOnDeactivation])))
    }

    func testTheKeepaliveStoppingDoesNotDowngradeALiveVoiceTurn() throws {
        let (arbiter, applier) = makeArbiter()
        try arbiter.hold(.keepalive)
        try arbiter.hold(.voice)
        try arbiter.release(.keepalive)

        XCTAssertEqual(applier.category, .playAndRecord, "a live turn must keep its recording route")
        XCTAssertEqual(applier.mode, .videoChat)
        XCTAssertTrue(applier.isActive)
    }

    func testTheLastReleaseDeactivatesAndLetsOtherAppsResume() throws {
        let (arbiter, applier) = makeArbiter()
        try arbiter.hold(.voice)
        try arbiter.release(.voice)

        XCTAssertFalse(applier.isActive)
        XCTAssertEqual(applier.calls.last, .active(false, [.notifyOthersOnDeactivation]))
    }

    func testReleasingAClientThatNeverHeldChangesNothing() throws {
        let (arbiter, applier) = makeArbiter()
        try arbiter.hold(.keepalive)
        let after = applier.calls.count
        try arbiter.release(.voice)

        XCTAssertEqual(applier.calls.count, after)
        XCTAssertTrue(applier.isActive)
    }

    // MARK: - Failures and re-assertion

    func testAHoldThatTheSessionRefusesIsNotRecorded() {
        let (arbiter, applier) = makeArbiter()
        applier.categoryError = VoiceAudioError.micUnavailable("category refused")
        XCTAssertThrowsError(try arbiter.hold(.voice))
        XCTAssertFalse(arbiter.holds(.voice), "a claim we could not apply is not held")
    }

    func testAFailedVoiceClaimGivesTheKeepaliveItsCategoryBack() throws {
        let (arbiter, applier) = makeArbiter()
        try arbiter.hold(.keepalive)
        applier.activateError = VoiceAudioError.micUnavailable("session busy")

        // The category switch lands, the activation is refused (another app is
        // holding an exclusive route) — the half-applied case.
        XCTAssertThrowsError(try arbiter.hold(.voice, reassert: true))
        XCTAssertFalse(arbiter.holds(.voice))
        XCTAssertEqual(applier.category, .playback,
                       "a half-applied plan must not outlive the claim that asked for it")
        XCTAssertTrue(applier.isActive, "the keepalive never lost the session")
    }

    func testReassertingReactivatesEvenWhenWeBelieveItIsAlreadyActive() throws {
        let (arbiter, applier) = makeArbiter()
        try arbiter.hold(.keepalive)
        let after = applier.calls.count
        // iOS deactivated us under an interruption; our belief is stale.
        try arbiter.hold(.keepalive, reassert: true)

        XCTAssertEqual(applier.calls.count, after + 1, "activation only — the category still matches")
        XCTAssertEqual(applier.calls.last, .active(true, []))
    }

    func testAReassertRestoresACategoryThatMediaServicesThrewAway() throws {
        let (arbiter, applier) = makeArbiter()
        try arbiter.hold(.keepalive)
        applier.simulateMediaServicesReset() // back to .soloAmbient, inactive
        try arbiter.reassert()

        XCTAssertEqual(applier.category, .playback)
        XCTAssertTrue(applier.isActive)
    }

    func testReassertingWithNoHoldersTouchesNothing() throws {
        let (arbiter, applier) = makeArbiter()
        try arbiter.reassert()
        XCTAssertTrue(applier.calls.isEmpty)
    }

    func testAKeepaliveReassertUnderALiveVoiceTurnStaysOnTheVoicePlan() throws {
        let (arbiter, applier) = makeArbiter()
        try arbiter.hold(.keepalive)
        try arbiter.hold(.voice)
        try arbiter.hold(.keepalive, reassert: true)

        XCTAssertEqual(applier.category, .playAndRecord,
                       "the keepalive re-asserting must never steal the mic from a turn")
    }

    // MARK: - The voice controller routes through the arbiter

    func testTheVoiceControllerHoldsAndReleasesThroughTheArbiter() throws {
        let applier = MockAudioSessionApplying()
        let arbiter = AudioSessionArbiter(session: applier)
        let controller = DefaultAudioSessionControlling(center: NotificationCenter(), arbiter: arbiter)

        try controller.configureForConversation()
        try controller.setActive(true)
        XCTAssertEqual(applier.category, .playAndRecord)
        XCTAssertTrue(applier.isActive)
        XCTAssertTrue(arbiter.holds(.voice))

        try controller.setActive(false)
        XCTAssertFalse(arbiter.holds(.voice))
        XCTAssertFalse(applier.isActive)
    }

    func testTheVoiceControllerTeardownLeavesTheKeepalivesSessionAlone() throws {
        let applier = MockAudioSessionApplying()
        let arbiter = AudioSessionArbiter(session: applier)
        let controller = DefaultAudioSessionControlling(center: NotificationCenter(), arbiter: arbiter)
        try arbiter.hold(.keepalive)

        try controller.configureForConversation()
        try controller.setActive(false)

        XCTAssertTrue(applier.isActive, "voice teardown used to kill the background allowance")
        XCTAssertEqual(applier.category, .playback)
    }
}

// MARK: - Mock

/// The `AVAudioSession` boundary. Records the exact calls (category then
/// activation) so the tests can assert the ORDER, which is what CoreAudio cares
/// about.
@MainActor
final class MockAudioSessionApplying: AudioSessionApplying {
    enum Call: Equatable {
        case category(AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)
        case active(Bool, AVAudioSession.SetActiveOptions)
    }

    private(set) var calls: [Call] = []
    private(set) var category: AVAudioSession.Category = .soloAmbient
    private(set) var mode: AVAudioSession.Mode = .default
    private(set) var categoryOptions: AVAudioSession.CategoryOptions = []
    private(set) var isActive = false

    var categoryError: Error?
    var activateError: Error?

    func setCategory(_ category: AVAudioSession.Category,
                     mode: AVAudioSession.Mode,
                     options: AVAudioSession.CategoryOptions) throws {
        if let categoryError { throw categoryError }
        calls.append(.category(category, mode, options))
        self.category = category
        self.mode = mode
        self.categoryOptions = options
    }

    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
        if active, let activateError { throw activateError }
        calls.append(.active(active, options))
        isActive = active
    }

    /// The audio daemon restarted: every setting is back to the process default
    /// and the session is inactive, without anyone being told through us.
    func simulateMediaServicesReset() {
        category = .soloAmbient
        mode = .default
        categoryOptions = []
        isActive = false
    }
}

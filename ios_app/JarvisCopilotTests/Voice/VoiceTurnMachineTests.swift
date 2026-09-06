import XCTest
@testable import JarvisCopilot

/// The turn FSM: idle → listening → thinking → speaking → idle, plus barge-in,
/// interrupt, cancel and error. Extracted from `voice_controller.dart` for
/// exactly this reason — the transitions were previously only observable by
/// listening to the phone.
final class VoiceTurnMachineTests: XCTestCase {

    // MARK: - Realtime happy path

    func testRealtimeWalksIdleToListeningToThinkingToSpeakingAndBack() {
        var m = VoiceTurnMachine(mode: .realtime)
        XCTAssertEqual(m.state, .idle)

        let start = m.apply(.startRequested)
        XCTAssertEqual(m.state, .connecting)
        XCTAssertTrue(start.contains(.openTransport))
        XCTAssertTrue(start.contains(.clearReply))
        XCTAssertFalse(start.contains(.startMic), "the mic waits for the transport")

        let connected = m.apply(.connected)
        XCTAssertEqual(m.state, .listening)
        XCTAssertEqual(connected, [.startMic, .restartRecognizer])

        let ended = m.apply(.endOfSpeech)
        XCTAssertEqual(m.state, .thinking)
        XCTAssertTrue(ended.contains(.sendEndTurn))
        XCTAssertTrue(ended.contains(.armThinkingWatchdog))
        XCTAssertTrue(ended.contains(.markSpeechEnd))
        XCTAssertTrue(ended.contains(.clearReply), "a new turn supersedes the last reply")

        _ = m.apply(.serverOutput)
        XCTAssertEqual(m.state, .thinking)

        let playing = m.apply(.playbackStarted)
        XCTAssertEqual(m.state, .speaking)
        XCTAssertTrue(playing.contains(.cancelResume))
        XCTAssertTrue(playing.contains(.cancelThinkingWatchdog))

        // A drained queue while the server is still on the turn (an ack, or a
        // sentence before a long tool run) stays in thinking — no resume yet.
        let drained = m.apply(.playbackDrained)
        XCTAssertEqual(m.state, .thinking)
        XCTAssertEqual(drained, [.cancelResume, .armThinkingWatchdog])
        XCTAssertEqual(m.apply(.resumeGraceElapsed), [], "nothing was scheduled")
        XCTAssertEqual(m.state, .thinking)

        // The server's end-of-turn is what schedules the resume.
        let ended2 = m.apply(.turnEnded(reason: "done", producedReply: true))
        XCTAssertTrue(ended2.contains(.scheduleResume))

        let resumed = m.apply(.resumeGraceElapsed)
        XCTAssertEqual(m.state, .listening)
        XCTAssertTrue(resumed.contains(.finalizeSpoken))
        XCTAssertTrue(resumed.contains(.restartRecognizer))
    }

    func testStartIsIgnoredWhileASessionIsAlreadyRunning() {
        var m = VoiceTurnMachine(mode: .realtime)
        _ = m.apply(.startRequested)
        _ = m.apply(.connected)
        XCTAssertTrue(m.apply(.startRequested).isEmpty)
        XCTAssertEqual(m.state, .listening)
    }

    func testConnectedOutsideConnectingIsIgnored() {
        var m = VoiceTurnMachine(mode: .realtime)
        XCTAssertTrue(m.apply(.connected).isEmpty)
        XCTAssertEqual(m.state, .idle)
    }

    func testEndOfSpeechOnlyFiresFromListening() {
        var m = VoiceTurnMachine(mode: .realtime)
        _ = m.apply(.startRequested)
        XCTAssertTrue(m.apply(.endOfSpeech).isEmpty, "still connecting")
        _ = m.apply(.connected)
        _ = m.apply(.endOfSpeech)
        XCTAssertTrue(m.apply(.endOfSpeech).isEmpty, "already thinking")
    }

    // MARK: - Barge-in

    func testBargeInIsAllowedWhileSpeaking() {
        var m = listening()
        _ = m.apply(.endOfSpeech)
        _ = m.apply(.playbackStarted)
        XCTAssertTrue(m.bargeInAllowed)

        let effects = m.apply(.bargeIn)
        XCTAssertEqual(m.state, .listening)
        XCTAssertTrue(effects.contains(.sendInterrupt))
        XCTAssertTrue(effects.contains(.stopPlayback))
        XCTAssertTrue(effects.contains(.resetEndpointer))
        XCTAssertTrue(effects.contains(.restartRecognizer))
    }

    func testBargeInIsAllowedWhileThinkingOnlyAfterTheServerHasStartedAnswering() {
        var m = listening()
        _ = m.apply(.endOfSpeech)
        XCTAssertFalse(m.bargeInAllowed, "nothing to cut into yet")
        XCTAssertTrue(m.apply(.bargeIn).isEmpty)
        XCTAssertEqual(m.state, .thinking)

        _ = m.apply(.serverOutput) // reply mid-flight (gap between sentences)
        XCTAssertTrue(m.bargeInAllowed)
        XCTAssertFalse(m.apply(.bargeIn).isEmpty)
        XCTAssertEqual(m.state, .listening)
    }

    func testBargeInIsIgnoredWhileListening() {
        var m = listening()
        XCTAssertFalse(m.bargeInAllowed)
        XCTAssertTrue(m.apply(.bargeIn).isEmpty)
        XCTAssertEqual(m.state, .listening)
    }

    func testANewTurnClearsTheServerOutputFlag() {
        var m = listening()
        _ = m.apply(.endOfSpeech)
        _ = m.apply(.serverOutput)
        _ = m.apply(.playbackStarted)
        _ = m.apply(.playbackDrained)
        _ = m.apply(.resumeGraceElapsed)
        _ = m.apply(.endOfSpeech)
        XCTAssertFalse(m.serverProducedOutput, "the next turn starts with nothing said")
        XCTAssertFalse(m.bargeInAllowed)
    }

    // MARK: - Interrupt (the button)

    func testInterruptFromSpeakingReturnsToListening() {
        var m = listening()
        _ = m.apply(.endOfSpeech)
        _ = m.apply(.playbackStarted)

        let effects = m.apply(.interruptRequested)
        XCTAssertEqual(m.state, .listening)
        XCTAssertTrue(effects.contains(.sendInterrupt))
        XCTAssertTrue(effects.contains(.stopPlayback))
        XCTAssertTrue(effects.contains(.newTurnEpoch), "invalidate in-flight per-turn work")
        XCTAssertTrue(effects.contains(.cancelThinkingWatchdog))
    }

    func testInterruptWorksMidThinkingButNotWhileListeningOrIdle() {
        var thinking = listening()
        _ = thinking.apply(.endOfSpeech)
        XCTAssertFalse(thinking.apply(.interruptRequested).isEmpty)

        var idle = VoiceTurnMachine(mode: .realtime)
        XCTAssertTrue(idle.apply(.interruptRequested).isEmpty)

        var listeningOnly = listening()
        XCTAssertTrue(listeningOnly.apply(.interruptRequested).isEmpty)
    }

    // MARK: - Cancel / stop

    func testStopTearsDownAndReturnsToIdleWithoutFinalizing() {
        var m = listening()
        _ = m.apply(.endOfSpeech)
        _ = m.apply(.playbackStarted)

        let effects = m.apply(.stopRequested)
        XCTAssertEqual(m.state, .idle)
        XCTAssertTrue(effects.contains(.teardown))
        XCTAssertTrue(effects.contains(.stopPlayback))
        XCTAssertTrue(effects.contains(.newTurnEpoch))
        // Freeze the partial reply where it stopped — don't erase it and don't
        // pretend the rest was spoken.
        XCTAssertFalse(effects.contains(.clearReply))
        XCTAssertFalse(effects.contains(.finalizeSpoken))
    }

    func testStopFromErrorStaysInErrorSoTheMessageSurvives() {
        var m = listening()
        _ = m.apply(.failed("boom"))
        _ = m.apply(.stopRequested)
        XCTAssertEqual(m.state, .error)
    }

    func testResumeGraceDoesNothingOnceStopped() {
        var m = listening()
        _ = m.apply(.stopRequested)
        XCTAssertTrue(m.apply(.resumeGraceElapsed).isEmpty)
        XCTAssertEqual(m.state, .idle)
    }

    // MARK: - Errors

    func testFailureEntersErrorAndTearsDown() {
        var m = listening()
        let effects = m.apply(.failed("Could not start voice"))
        XCTAssertEqual(m.state, .error)
        XCTAssertTrue(effects.contains(.showError("Could not start voice")))
        XCTAssertTrue(effects.contains(.teardown))
        XCTAssertTrue(effects.contains(.stopPlayback))
        XCTAssertTrue(effects.contains(.abortRecognizer))
    }

    func testErrorIsRecoverableWithAFreshStart() {
        var m = listening()
        _ = m.apply(.failed("boom"))
        let start = m.apply(.startRequested)
        XCTAssertEqual(m.state, .connecting)
        XCTAssertTrue(start.contains(.clearReply))
    }

    func testAFailedTurnReasonSurfacesAMessageAndKeepsTheConversation() {
        var m = listening()
        _ = m.apply(.endOfSpeech)
        let effects = m.apply(.turnEnded(reason: "no_reply", producedReply: false))
        XCTAssertEqual(m.state, .thinking, "we stay in the conversation, not error")
        XCTAssertTrue(effects.contains(.showError("I didn't catch a reply — please try again.")))
        XCTAssertTrue(effects.contains(.scheduleResume))

        var other = listening()
        _ = other.apply(.endOfSpeech)
        let errorEffects = other.apply(.turnEnded(reason: "error", producedReply: false))
        XCTAssertTrue(errorEffects.contains(.showError("Something went wrong — please try again.")))
    }

    func testBenignTurnEndReasonsAreSilent() {
        for reason in ["", "no_speech", "empty", "interrupt", "ok"] {
            var m = listening()
            _ = m.apply(.endOfSpeech)
            let effects = m.apply(.turnEnded(reason: reason, producedReply: false))
            XCTAssertFalse(effects.contains(where: { if case .showError = $0 { return true }; return false }),
                           "reason \"\(reason)\" is benign")
            XCTAssertTrue(effects.contains(.scheduleResume))
        }
    }

    func testAFailureReasonIsNotSurfacedWhenTheTurnActuallyProducedAReply() {
        var m = listening()
        _ = m.apply(.endOfSpeech)
        let effects = m.apply(.turnEnded(reason: "error", producedReply: true))
        XCTAssertFalse(effects.contains(where: { if case .showError = $0 { return true }; return false }))
    }

    func testTurnEndedWhileIdleOnlyCancelsTheWatchdog() {
        var m = VoiceTurnMachine(mode: .realtime)
        XCTAssertEqual(m.apply(.turnEnded(reason: "error", producedReply: false)),
                       [.cancelThinkingWatchdog])
    }

    // MARK: - Push-to-talk (quality) mode

    func testQualityModeStartsListeningImmediatelyWithNoTransport() {
        var m = VoiceTurnMachine(mode: .quality)
        let start = m.apply(.startRequested)
        XCTAssertEqual(m.state, .listening)
        XCTAssertTrue(start.contains(.startMic))
        XCTAssertFalse(start.contains(.openTransport), "push-to-talk is one HTTP round trip")
    }

    func testQualityModeSendsOnTheSecondTapAndStopsTheMic() {
        var m = VoiceTurnMachine(mode: .quality)
        _ = m.apply(.startRequested)
        let send = m.apply(.endOfSpeech)
        XCTAssertEqual(m.state, .thinking)
        XCTAssertTrue(send.contains(.stopMic))
        XCTAssertTrue(send.contains(.sendEndTurn))
        XCTAssertFalse(send.contains(.clearReply), "quality clears at the start of the turn")
    }

    func testQualityModeGoesIdleWhenPlaybackDrainsInsteadOfResuming() {
        var m = VoiceTurnMachine(mode: .quality)
        _ = m.apply(.startRequested)
        _ = m.apply(.endOfSpeech)
        _ = m.apply(.playbackStarted)
        let drained = m.apply(.playbackDrained)
        XCTAssertEqual(m.state, .idle, "push-to-talk is one shot, not a conversation")
        XCTAssertEqual(drained, [.finalizeSpoken])
    }

    func testQualityStreamDoneSettlesToIdleOnlyWhenNothingIsPlaying() {
        var busy = VoiceTurnMachine(mode: .quality)
        _ = busy.apply(.startRequested)
        _ = busy.apply(.endOfSpeech)
        XCTAssertTrue(busy.apply(.qualityStreamDone(playbackBusy: true)).isEmpty)
        XCTAssertEqual(busy.state, .thinking)

        var quiet = VoiceTurnMachine(mode: .quality)
        _ = quiet.apply(.startRequested)
        _ = quiet.apply(.endOfSpeech)
        XCTAssertEqual(quiet.apply(.qualityStreamDone(playbackBusy: false)), [.finalizeSpoken])
        XCTAssertEqual(quiet.state, .idle)
    }

    func testQualityModeIgnoresRealtimeOnlyEvents() {
        var m = VoiceTurnMachine(mode: .quality)
        _ = m.apply(.startRequested)
        _ = m.apply(.endOfSpeech)
        _ = m.apply(.playbackStarted)
        XCTAssertTrue(m.apply(.interruptRequested).isEmpty)
        XCTAssertTrue(m.apply(.resumeGraceElapsed).isEmpty)
        XCTAssertEqual(m.state, .speaking)
    }

    func testRealtimeIgnoresQualityStreamDone() {
        var m = listening()
        _ = m.apply(.endOfSpeech)
        XCTAssertTrue(m.apply(.qualityStreamDone(playbackBusy: false)).isEmpty)
        XCTAssertEqual(m.state, .thinking)
    }

    // MARK: - Helper

    private func listening() -> VoiceTurnMachine {
        var m = VoiceTurnMachine(mode: .realtime)
        _ = m.apply(.startRequested)
        _ = m.apply(.connected)
        return m
    }

    func testAnAcknowledgementDoesNotResumeListeningMidTurn() {
        var m = VoiceTurnMachine(mode: .realtime)
        _ = m.apply(.startRequested); _ = m.apply(.connected); _ = m.apply(.endOfSpeech)
        // Server ack: "On it, sir." plays and drains long before the reply.
        _ = m.apply(.serverOutput); _ = m.apply(.playbackStarted)
        XCTAssertEqual(m.state, .speaking)
        _ = m.apply(.playbackDrained)
        XCTAssertEqual(m.state, .thinking, "still working — never back to listening yet")
        XCTAssertEqual(m.apply(.resumeGraceElapsed), [])
        // The real reply, then the server ends the turn while it is still playing.
        _ = m.apply(.serverOutput); _ = m.apply(.playbackStarted)
        let ended = m.apply(.turnEnded(reason: "done", producedReply: true))
        XCTAssertFalse(ended.contains(.scheduleResume), "tail of the reply is still playing")
        XCTAssertEqual(m.state, .speaking)
        let drained = m.apply(.playbackDrained)
        XCTAssertEqual(drained, [.scheduleResume])
        _ = m.apply(.resumeGraceElapsed)
        XCTAssertEqual(m.state, .listening)
    }
}

import Foundation

/// Everything that can move a voice turn along. The store raises these; the
/// machine decides the next state and what has to happen.
enum VoiceTurnEvent: Equatable, Sendable {
    /// The big button, in idle/error.
    case startRequested
    /// Transport open (realtime only) — the mic can go live.
    case connected
    /// The endpointer fired, or the user pressed "Done".
    case endOfSpeech
    /// The server produced SOMETHING for this turn (text, tool, or audio).
    case serverOutput
    /// A clip began playing.
    case playbackStarted
    /// The playback queue drained.
    case playbackDrained
    /// The resume-grace window elapsed with nothing playing.
    case resumeGraceElapsed
    /// A loud mic frame during playback.
    case bargeIn
    /// The user pressed "Interrupt".
    case interruptRequested
    /// `end_turn` from the server. `producedReply` is false when the turn made
    /// neither audio nor reply text — only then is a failure `reason` surfaced.
    case turnEnded(reason: String, producedReply: Bool)
    case failed(String)
    /// The Stop button, or a mode switch.
    case stopRequested
    /// The quality-mode NDJSON stream finished.
    case qualityStreamDone(playbackBusy: Bool)
}

/// What the store must actually do. Keeping these out of the machine is what
/// makes the FSM testable with no audio, no network and no timers.
enum VoiceTurnEffect: Equatable, Sendable {
    case openTransport
    case startMic
    case stopMic
    /// `end_turn` (realtime) / POST the recorded clip (quality).
    case sendEndTurn
    case sendInterrupt
    case stopPlayback
    /// Re-arm the on-device recognizer for the next utterance.
    case restartRecognizer
    case abortRecognizer
    case scheduleResume
    case cancelResume
    case armThinkingWatchdog
    case cancelThinkingWatchdog
    /// Clear the reply text + karaoke highlight (a new turn starts fresh).
    case clearReply
    /// Light up any words the position stream didn't reach.
    case finalizeSpoken
    case resetEndpointer
    /// Invalidate any in-flight per-turn async work.
    case newTurnEpoch
    /// Note the moment the user stopped talking (latency spans, plan 0.2).
    case markSpeechEnd
    /// Close the socket and release the mic + audio session.
    case teardown
    case showError(String)
}

/// The voice FSM, extracted from `voice_controller.dart` so the transitions can
/// be asserted directly. Pure value type: no timers, no I/O, no `Task`.
struct VoiceTurnMachine: Equatable {

    /// The server reports every turn outcome as `end_turn{reason}`; these two
    /// mean it failed. `no_speech`/`empty`/`interrupt` are benign — the user
    /// simply didn't say anything or barged in — so we stay silent there.
    static let failureReasons: Set<String> = ["error", "no_reply"]

    private(set) var state: VoiceState = .idle
    var mode: VoiceMode = .realtime
    /// Set as soon as the server produces ANYTHING for this turn. Barge-in
    /// during "thinking" is only allowed once this is true.
    private(set) var serverProducedOutput = false
    /// A server turn is in flight: `end_turn` was sent and the server hasn't
    /// answered with its own end-of-turn yet. While it's open, playback draining
    /// (the spoken acknowledgement, or a mid-turn sentence before a long tool
    /// run) must NOT resume listening — the model is still working.
    private(set) var serverTurnOpen = false

    init(mode: VoiceMode = .realtime) { self.mode = mode }

    /// Barge-in is allowed while speaking, and while thinking mid-reply (the gap
    /// between sentences / a tool call) once the server has started answering —
    /// the user shouldn't have to wait for the next sentence to cut in.
    var bargeInAllowed: Bool {
        state == .speaking || (state == .thinking && serverProducedOutput)
    }

    mutating func apply(_ event: VoiceTurnEvent) -> [VoiceTurnEffect] {
        switch event {

        case .startRequested:
            guard !state.isActive else { return [] }
            serverProducedOutput = false
            if mode == .realtime {
                state = .connecting
                return [.clearReply, .resetEndpointer, .newTurnEpoch, .stopPlayback, .openTransport]
            }
            state = .listening
            return [.clearReply, .resetEndpointer, .newTurnEpoch, .stopPlayback, .startMic]

        case .connected:
            guard state == .connecting else { return [] }
            state = .listening
            return [.startMic, .restartRecognizer]

        case .endOfSpeech:
            guard state == .listening else { return [] }
            serverProducedOutput = false
            if mode == .realtime {
                // A new user turn begins → clear the previous reply + highlight
                // so the incoming one starts fresh (within one realtime session
                // segments would otherwise accumulate across turns).
                state = .thinking
                serverTurnOpen = true
                return [.cancelResume, .resetEndpointer, .clearReply, .newTurnEpoch,
                        .markSpeechEnd, .sendEndTurn, .armThinkingWatchdog]
            }
            state = .thinking
            serverTurnOpen = true
            return [.stopMic, .markSpeechEnd, .sendEndTurn, .armThinkingWatchdog]

        case .serverOutput:
            serverProducedOutput = true
            let effects: [VoiceTurnEffect] = [.cancelResume, .cancelThinkingWatchdog]
            guard state.isActive else { return effects }
            // Keep the orb off "listening" while the reply is mid-flight;
            // playback is what flips us to speaking.
            if state != .speaking { state = .thinking }
            return effects

        case .playbackStarted:
            let effects: [VoiceTurnEffect] = [.cancelResume, .cancelThinkingWatchdog]
            guard state != .idle, state != .error else { return effects }
            if state != .speaking { state = .speaking }
            return effects

        case .playbackDrained:
            if mode == .realtime, state.isActive {
                // Don't resume listening immediately — a follow-up segment often
                // arrives within a beat. Show "thinking" and wait out the grace
                // window; a new clip cancels the resume.
                if state == .speaking { state = .thinking }
                // The server is still on this turn (an ack or a sentence played
                // before a long tool run): stay in thinking; `turnEnded` resumes.
                if serverTurnOpen { return [.cancelResume, .armThinkingWatchdog] }
                return [.scheduleResume]
            }
            if mode == .quality, state == .speaking {
                state = .idle
                return [.finalizeSpoken]
            }
            return []

        case .resumeGraceElapsed:
            guard mode == .realtime, state.isActive else { return [] }
            state = .listening
            return [.finalizeSpoken, .resetEndpointer, .restartRecognizer]

        case .bargeIn:
            guard bargeInAllowed else { return [] }
            serverTurnOpen = false
            state = .listening
            return [.sendInterrupt, .stopPlayback, .cancelResume, .resetEndpointer,
                    .abortRecognizer, .restartRecognizer]

        case .interruptRequested:
            guard mode == .realtime, state == .speaking || state == .thinking else { return [] }
            serverTurnOpen = false
            state = .listening
            return [.cancelResume, .cancelThinkingWatchdog, .newTurnEpoch, .sendInterrupt,
                    .stopPlayback, .resetEndpointer, .abortRecognizer, .restartRecognizer]

        case .turnEnded(let reason, let producedReply):
            serverTurnOpen = false
            var effects: [VoiceTurnEffect] = [.cancelThinkingWatchdog]
            guard state.isActive else { return effects }
            if Self.failureReasons.contains(reason) && !producedReply {
                // Surface real failures instead of silently resuming: a failed
                // turn used to look identical to a normal one ("thinking →
                // listening, nothing spoken"). Stay in the conversation so the
                // user can just retry.
                effects.append(.showError(reason == "no_reply"
                    ? "I didn't catch a reply — please try again."
                    : "Something went wrong — please try again."))
            }
            // Still speaking the tail of the reply: `playbackDrained` will
            // schedule the resume once the audio is out.
            if state != .speaking { effects.append(.scheduleResume) }
            return effects

        case .failed(let message):
            serverTurnOpen = false
            state = .error
            return [.cancelResume, .cancelThinkingWatchdog, .abortRecognizer,
                    .teardown, .stopPlayback, .showError(message)]

        case .stopRequested:
            serverTurnOpen = false
            let wasError = state == .error
            state = wasError ? .error : .idle
            // Keep the reply on screen after Stop — DON'T erase it and DON'T
            // finalize. Freezing it where it stopped is honest about how far it
            // got; the next turn clears it.
            return [.cancelResume, .cancelThinkingWatchdog, .newTurnEpoch,
                    .abortRecognizer, .teardown, .stopPlayback]

        case .qualityStreamDone(let playbackBusy):
            guard mode == .quality, state != .error, !playbackBusy else { return [] }
            state = .idle
            return [.finalizeSpoken]
        }
    }
}

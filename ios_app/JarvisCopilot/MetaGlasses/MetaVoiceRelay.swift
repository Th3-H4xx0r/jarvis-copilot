import Foundation

/// Mirrors one glasses voice turn from the phone's voice engine back to the glasses: what
/// Jarvis heard, the answer as it streams, speaking on/off, and when the turn is over.
///
/// Pure value logic over successive `MetaVoiceSnapshot`s — the session polls `VoiceStore`
/// every 100 ms (the `InmoAIChannel` cadence) and sends the frames this returns. The rules are
/// INMO's, plus guards against text left over from an earlier chat:
/// - the transcript goes out when it changes, and once more marked final when Jarvis starts
///   thinking or speaking;
/// - the answer counts only after the question went final AND the reply text changed since —
///   so a stale reply still in `VoiceStore` is never shown as this turn's answer;
/// - the turn is finished once a turn ended (completion generation moved since the latest
///   question) and the engine is back to listening/idle, i.e. playback has drained;
/// - a barge-in or new question resets the per-question state;
/// - a new error, or the engine going idle mid-turn, fails the turn.
struct MetaVoiceRelay {
    enum Outcome: Equatable, Sendable {
        case running
        case finished
        case failed(String)
    }

    struct Step: Equatable {
        var frames: [GlassesFrame] = []
        var outcome: Outcome = .running
    }

    /// The engine left idle at least once this turn (connecting counts).
    private(set) var seenActive = false

    private let baselineError: String?
    private var completionBaseline: Int
    private var questionBaseline: Int
    private var interruptionBaseline: Int
    private var lastHeard: String
    private var finalSent = false
    /// The reply text at the moment the question went final; the answer is this turn's only
    /// once the text moves away from it.
    private var answerAtQuestion: String?
    private var answerIsThisTurn = false
    private var lastAnswer = ""
    private var speaking = false
    private var settled: Outcome?

    init(baseline: MetaVoiceSnapshot) {
        baselineError = baseline.error
        completionBaseline = baseline.completionGeneration
        questionBaseline = baseline.questionGeneration
        interruptionBaseline = baseline.interruptionGeneration
        // A transcript left from an earlier chat is not this turn's.
        lastHeard = baseline.heard
        speaking = baseline.state == .speaking
    }

    mutating func step(_ next: MetaVoiceSnapshot) -> Step {
        if let settled { return Step(outcome: settled) }
        var step = Step()
        if next.state != .idle { seenActive = true }

        // A barge-in or a new utterance starts the question over (InmoAIChannel does the same).
        if next.questionGeneration != questionBaseline || next.interruptionGeneration != interruptionBaseline {
            questionBaseline = next.questionGeneration
            interruptionBaseline = next.interruptionGeneration
            completionBaseline = next.completionGeneration
            lastHeard = ""
            finalSent = false
            answerAtQuestion = nil
            answerIsThisTurn = false
            lastAnswer = ""
        }

        // Transcript: on change, and once more as final when Jarvis takes over.
        let isFinal = next.state == .thinking || next.state == .speaking
        if !next.heard.isEmpty, next.heard != lastHeard || (isFinal && !finalSent) {
            lastHeard = next.heard
            if isFinal { finalSent = true }
            step.frames.append(.showTranscript(text: next.heard, isFinal: isFinal))
        }

        // Answer: only after the question is final, and only once the reply text has moved.
        if finalSent {
            if answerAtQuestion == nil { answerAtQuestion = next.answer }
            if !answerIsThisTurn, next.answer != answerAtQuestion { answerIsThisTurn = true }
            if answerIsThisTurn, !next.answer.isEmpty, next.answer != lastAnswer {
                lastAnswer = next.answer
                step.frames.append(.showAnswer(text: next.answer, isFinal: false))
            }
        }

        let nowSpeaking = next.state == .speaking
        if nowSpeaking != speaking {
            speaking = nowSpeaking
            step.frames.append(.setSpeaking(nowSpeaking))
        }

        if let error = next.error, error != baselineError {
            return settle(step, .failed(error))
        }
        let turnEnded = next.completionGeneration != completionBaseline
        if turnEnded, next.state == .listening || next.state == .idle {
            if answerIsThisTurn, !next.answer.isEmpty {
                step.frames.append(.showAnswer(text: next.answer, isFinal: true))
            }
            return settle(step, .finished)
        }
        if seenActive, next.state == .idle {
            return settle(step, .failed("Jarvis voice stopped"))
        }
        return step
    }

    private mutating func settle(_ step: Step, _ outcome: Outcome) -> Step {
        settled = outcome
        var step = step
        step.outcome = outcome
        return step
    }
}

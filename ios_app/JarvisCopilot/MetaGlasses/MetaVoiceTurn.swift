import Foundation

/// The slice of `VoiceStore` a glasses turn needs. Abstracted so the wake→turn logic can be
/// unit-tested with a fake, and so this module never has to touch `VoiceStore` in a test
/// (which would pull in real audio/engine state).
///
/// The production implementation (`VoiceStoreTurnController`) forwards verbatim to
/// `VoiceStore.shared.useExternalInput` / `beginExternalTurn` — exactly the INMO discipline
/// (see `InmoAIChannel`). It is never invoked in production because the device is not registered.
@MainActor
protocol MetaVoiceTurnController: AnyObject {
    /// Hand a glasses-only audio source to the voice engine, or clear it with `nil`.
    func useExternalInput(_ input: AudioInput?, isCurrent: @escaping () -> Bool) async
    /// Begin a realtime external turn (the phone mic is never opened).
    func beginExternalTurn(isCurrent: @escaping () -> Bool) async
    /// What the voice engine is doing right now — read by `MetaVoiceRelay` to mirror the turn
    /// (heard text, answer, speaking, done) back to the glasses. Read-only.
    func snapshot() -> MetaVoiceSnapshot
}

/// A read-only copy of the `VoiceStore` fields a glasses turn mirrors — the same ones
/// `InmoAIChannel` polls. A value type so the relay logic is testable without a live engine.
struct MetaVoiceSnapshot: Equatable, Sendable {
    var state: VoiceState
    /// What the engine heard: the live partial while listening, else the last final transcript.
    var heard: String
    /// The assistant's reply text so far.
    var answer: String
    /// A server turn is open (Jarvis is thinking or still streaming).
    var thinking: Bool
    /// Bumped when a turn ends (`VoiceStore.responseCompletionGeneration`).
    var completionGeneration: Int
    /// Bumped at each end-of-speech (`VoiceStore.questionGeneration`).
    var questionGeneration: Int
    /// Bumped on barge-in (`VoiceStore.interruptionGeneration`).
    var interruptionGeneration: Int
    var error: String?

    static let idle = MetaVoiceSnapshot(state: .idle, heard: "", answer: "", thinking: false,
                                        completionGeneration: 0, questionGeneration: 0,
                                        interruptionGeneration: 0, error: nil)
}

/// Production adapter. Forwards to the one audio-session/voice owner. Behaviour is identical to
/// what `InmoAIChannel` does today; nothing here runs unless the device is wired in.
@MainActor
final class VoiceStoreTurnController: MetaVoiceTurnController {
    static let shared = VoiceStoreTurnController()
    func useExternalInput(_ input: AudioInput?, isCurrent: @escaping () -> Bool) async {
        await VoiceStore.shared.useExternalInput(input, isCurrent: isCurrent)
    }
    func beginExternalTurn(isCurrent: @escaping () -> Bool) async {
        await VoiceStore.shared.beginExternalTurn(isCurrent: isCurrent)
    }
    func snapshot() -> MetaVoiceSnapshot {
        let voice = VoiceStore.shared
        return MetaVoiceSnapshot(
            state: voice.state,
            heard: voice.livePartial.isEmpty ? voice.userTranscript : voice.livePartial,
            answer: voice.assistantText,
            thinking: voice.responsePending,
            completionGeneration: voice.responseCompletionGeneration,
            questionGeneration: voice.questionGeneration,
            interruptionGeneration: voice.interruptionGeneration,
            error: voice.error)
    }
}

/// Receives only Meta glasses PCM. A missing stream stays missing; it can never open the phone
/// microphone (the `InmoAudioInput` discipline, plan §6.3). The glasses' voice audio rides the
/// L2CAP session, so it never appears on the AVAudioSession route and never claims HFP.
@MainActor
final class MetaGlassesAudioInput: AudioInput {
    var onFrame: ((Data) -> Void)?
    private(set) var isRunning = false
    /// Frames fed in before the engine started, so the first word is not lost.
    private var pending: [Data] = []
    private let maxPendingBytes = 96_000

    func requestPermission() async -> Bool { true }

    func start(sampleRate: Int) async throws {
        guard sampleRate == 16_000 else {
            throw MetaGlassesError.transportUnavailable("unsupported sample rate \(sampleRate)")
        }
        isRunning = true
        let queued = pending
        pending.removeAll()
        for frame in queued { onFrame?(frame) }
    }

    func stop() async {
        isRunning = false
        pending.removeAll()
    }

    /// Feed one PCM frame from the glasses. Buffered until `start`, dropped past the cap.
    func receive(_ pcm: Data) {
        if isRunning { onFrame?(pcm) }
        else if pending.reduce(0, { $0 + $1.count }) < maxPendingBytes { pending.append(pcm) }
    }
}

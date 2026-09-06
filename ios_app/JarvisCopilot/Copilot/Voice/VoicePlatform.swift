import Foundation

// Every platform boundary the voice stack touches, behind a protocol. Each has a
// `Default…` production implementation (AVAudioEngine / SFSpeechRecognizer /
// AVSpeechSynthesizer / AVAudioSession / URLSessionWebSocketTask) and a mock in
// `JarvisCopilotTests/Voice/VoiceMocks.swift`, so the whole turn machine runs
// in a unit test with no audio hardware.

// MARK: - Clock

/// Cancellable handle for a scheduled callback.
protocol VoiceTimerToken: AnyObject {
    func cancel()
}

/// Time and timers behind a protocol so grace windows / watchdogs are testable.
///
/// Named `VoiceClock`, not `Clock`: the stdlib already has a `Clock` protocol and
/// declaring another in this module would shadow it for every other file.
@MainActor
protocol VoiceClock: AnyObject {
    var now: Date { get }
    /// Run `body` on the main actor after `ms`. Cancelling the token guarantees
    /// `body` never runs.
    func schedule(after ms: Int, _ body: @escaping @MainActor () -> Void) -> VoiceTimerToken
}

/// `Timer` on the main run loop. `Task.sleep` would be finer-grained but a
/// cancelled `Task` can still resume once before it notices, which is exactly
/// the "stale resume fired after barge-in" class of bug this stack has to avoid.
@MainActor
final class SystemVoiceClock: VoiceClock {
    var now: Date { Date() }

    func schedule(after ms: Int, _ body: @escaping @MainActor () -> Void) -> VoiceTimerToken {
        let timer = Timer(timeInterval: Double(ms) / 1000, repeats: false) { _ in
            MainActor.assumeIsolated { body() }
        }
        // `.common`, NOT `Timer.scheduledTimer`'s implicit `.default`: while the
        // user drags anything the main run loop is in `.tracking`, and a
        // `.default`-only timer does not fire there. Every timing decision in a
        // turn rides this clock — the 1.6 s resume grace, the thinking watchdog,
        // the on-device STT deadline — so a finger resting on the reply used to
        // hold the conversation in "thinking" until the drag ended.
        RunLoop.main.add(timer, forMode: .common)
        return Token(timer)
    }

    private final class Token: VoiceTimerToken {
        private var timer: Timer?
        init(_ timer: Timer) { self.timer = timer }
        func cancel() { timer?.invalidate(); timer = nil }
    }
}

// MARK: - Errors

enum VoiceAudioError: LocalizedError, Equatable {
    case micUnavailable(String)
    case formatUnsupported
    case notPaired

    var errorDescription: String? {
        switch self {
        case .micUnavailable(let why): return "Could not start recording: \(why)"
        case .formatUnsupported: return "This device can't record 16 kHz mono audio"
        case .notPaired: return "Not paired with a Jarvis server"
        }
    }
}

// MARK: - Mic

/// The mic tap: mono PCM16 little-endian frames at the requested sample rate.
@MainActor
protocol AudioInput: AnyObject {
    /// Frames arrive here, in order, on the main actor.
    var onFrame: ((Data) -> Void)? { get set }
    var isRunning: Bool { get }
    /// Ask for (or check) mic permission.
    func requestPermission() async -> Bool
    func start(sampleRate: Int) async throws
    func stop() async
}

// MARK: - Playback

/// Two playback paths, matching what the voice backend sends:
///
///  • a continuous PCM render stream for realtime replies — every arriving chunk
///    is appended to ONE stream so chunk seams are inaudible (plan 1.7);
///  • one-shot encoded clips (MP3 from quality mode and from server TTS).
@MainActor
protocol AudioOutput: AnyObject {
    /// False when the render stream can't run here; `AudioQueue` then falls back
    /// to cutting PCM into WAV clips.
    var isStreamAvailable: Bool { get }

    /// Open one continuous render stream. False = refused; don't retry.
    func startStream(sampleRate: Int) async -> Bool
    func feed(_ pcm: Data) async
    /// Drop queued audio, keep the stream open (barge-in).
    func flushStream() async
    func stopStream() async

    /// Fired when the clip started by `play` finishes on its own.
    var onClipComplete: (() -> Void)? { get set }
    /// Fired periodically with the current clip's playhead.
    var onClipPosition: ((TimeInterval) -> Void)? { get set }
    /// Fired once the real decoded duration of the current clip is known — MP3
    /// duration is not reliable at play() time.
    var onClipDuration: ((TimeInterval) -> Void)? { get set }

    /// Start one encoded clip. `fileExtension` is the container hint ("mp3"/"wav").
    func play(_ bytes: Data, fileExtension: String) async -> Bool
    func stopClip() async
}

// MARK: - Speech recognition (on-device STT)

/// Live recognition running DURING speech, fed the same mic frames we stream to
/// the server, so the final transcript is ready ~0 ms after the endpointer fires
/// and `end_turn` can carry `text` (the server then skips its own STT).
@MainActor
protocol SpeechSession: AnyObject {
    var onPartial: ((String) -> Void)? { get set }
    /// True once the recognizer ended its own session — Apple stops after a
    /// stretch of silence, so the caller re-arms BETWEEN utterances.
    var isDone: Bool { get }
    func feed(_ pcm: Data)
    /// End audio and resolve the final transcript ("" when nothing was heard).
    func stop() async -> String
    func cancel()
}

@MainActor
protocol SpeechRecognizing: AnyObject {
    var isAvailable: Bool { get }
    /// `prompt` false = only take a session when permission was already granted,
    /// so a user who never opted in is never surprised by a permission sheet.
    func startSession(sampleRate: Int, prompt: Bool) async -> SpeechSession?
}

// MARK: - Local synthesizer

/// The phone's OWN voice — not the JARVIS voice, the sub-100 ms one. It exists
/// so a local action can be acknowledged out loud without a round-trip to
/// `/api/voice/synthesize`.
@MainActor
protocol VoiceSynthesizing: AnyObject {
    var isAvailable: Bool { get }
    /// Speak now, interrupting anything still being said (an ack is only ever
    /// about the turn happening right now). False when we couldn't say it.
    @discardableResult
    func speak(_ text: String, rate: Float) async -> Bool
    func stop()
}

// MARK: - Audio session

enum AudioInterruption: Equatable, Sendable { case began, ended }

/// The single owner of `AVAudioSession` for the whole conversation. Past
/// regressions all came from a second owner reconfiguring it mid-turn.
@MainActor
protocol AudioSessionControlling: AnyObject {
    /// `.playAndRecord` + `.videoChat`: speakerphone route AND echo cancellation,
    /// which is how calling apps get full volume with a live mic.
    func configureForConversation() throws
    func setActive(_ active: Bool) throws
    var onInterruption: ((AudioInterruption) -> Void)? { get set }
}

// MARK: - Realtime socket

enum VoiceSocketFrame: Equatable, Sendable {
    case text(String)
    case binary(Data)
}

@MainActor
protocol VoiceSocket: AnyObject {
    var onFrame: ((VoiceSocketFrame) -> Void)? { get set }
    var onClose: ((Error?) -> Void)? { get set }
    func send(text: String)
    func send(data: Data)
    func close()
}

@MainActor
protocol VoiceSocketConnecting: AnyObject {
    func connect(url: URL, headers: [String: String]) async throws -> VoiceSocket
}

import AVFoundation
import Foundation
import Speech

/// Streaming on-device speech recognition (plan 4.1). Adapted from the Flutter
/// app's `ios/Runner/SpeechStreamBridge.swift`.
///
/// A batch transcribe can only start once the user has STOPPED talking, so its
/// 300–800 ms lands entirely inside their wait. This instead consumes the SAME
/// mic frames we're already streaming to the server, so the final transcript is
/// ready ~0 ms after the endpointer fires and `end_turn` can carry `text` (the
/// server then skips its own STT).
///
/// Privacy: recognition is forced ON-DEVICE (`requiresOnDeviceRecognition`). If
/// the device can't do that we report unavailable and the caller falls back to
/// server STT. Recognized text is never logged.
///
/// Needs `NSSpeechRecognitionUsageDescription` in Info.plist.
@MainActor
final class DefaultSpeechRecognizing: SpeechRecognizing {

    var isAvailable: Bool {
        guard let recognizer = SFSpeechRecognizer() else { return false }
        return recognizer.isAvailable && recognizer.supportsOnDeviceRecognition
    }

    func startSession(sampleRate: Int, prompt: Bool) async -> SpeechSession? {
        guard await authorize(prompt: prompt) else { return nil }
        guard let recognizer = SFSpeechRecognizer(),
              recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Double(sampleRate),
                                         channels: 1, interleaved: false)
        else { return nil }
        return DefaultSpeechSession(recognizer: recognizer, format: format)
    }

    /// `prompt` false = only take a session when permission was already granted,
    /// so a user who never opted into on-device AI is never surprised by a sheet.
    private func authorize(prompt: Bool) async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined where prompt:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        default:
            return false
        }
    }
}

/// One live recognition session.
@MainActor
final class DefaultSpeechSession: SpeechSession {

    var onPartial: ((String) -> Void)?
    private(set) var isDone = false

    private let format: AVAudioFormat
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var latest = ""
    /// Resolves a pending `stop`. Fires at most once — the recognition callback
    /// and a teardown can both try to resolve the same wait.
    private var pendingFinal: CheckedContinuation<String, Never>?

    init(recognizer: SFSpeechRecognizer, format: AVAudioFormat) {
        self.format = format
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        // Dictation is the closest hint to short spoken commands; harmless on OS
        // versions that ignore it.
        request.taskHint = .dictation
        self.request = request
        // Deliver callbacks on the main queue explicitly. Without this SFSpeech
        // picks its own queue and the `MainActor.assumeIsolated` below is a
        // promise the framework never made.
        recognizer.queue = .main
        self.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let result {
                    self.latest = result.bestTranscription.formattedString
                    self.onPartial?(self.latest)
                    if result.isFinal { self.finish(self.latest) }
                } else if error != nil {
                    // Deliver whatever we heard; "" makes the caller fall back.
                    self.finish(self.latest)
                }
            }
        }
    }

    func feed(_ pcm: Data) {
        guard let request, !isDone,
              let buffer = Self.makeBuffer(pcm: pcm, format: format) else { return }
        request.append(buffer)
    }

    /// End audio and wait for the final transcript. The caller applies its own
    /// timeout, so a recognizer that never answers can't hold the turn — but we
    /// also resolve immediately once already done.
    func stop() async -> String {
        if isDone { return latest }
        request?.endAudio()
        return await withCheckedContinuation { continuation in
            if isDone {
                continuation.resume(returning: latest)
            } else {
                pendingFinal = continuation
            }
        }
    }

    func cancel() {
        guard !isDone else { return }
        finish("")
    }

    private func finish(_ text: String) {
        guard !isDone else { return }
        isDone = true
        task?.cancel()
        task = nil
        request = nil
        let continuation = pendingFinal
        pendingFinal = nil
        continuation?.resume(returning: text)
    }

    /// PCM16 mono LE bytes → the Float32 buffer the request wants.
    private static func makeBuffer(pcm: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = pcm.count / 2
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frames)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        // Copy into an aligned array first: `Data`'s bytes aren't guaranteed to
        // be 2-byte aligned, so binding them in place would be undefined.
        var samples = [Int16](repeating: 0, count: frames)
        _ = samples.withUnsafeMutableBytes { pcm.copyBytes(to: $0, count: frames * 2) }
        for i in 0..<frames { channel[i] = Float(Int16(littleEndian: samples[i])) / 32768.0 }
        return buffer
    }
}

/// `session.stop()`, but never longer than `ms`.
///
/// `DefaultSpeechSession.stop()` parks on a continuation that only SFSpeech's
/// final/error callback resumes — and that callback is not guaranteed. When it
/// never lands the turn sits in `thinking` forever and the continuation leaks,
/// so on the deadline we cancel the session (which resolves its own wait) and
/// answer with "", i.e. "let the server do STT".
@MainActor
func voiceStopWithDeadline(_ session: SpeechSession,
                           after ms: Int,
                           clock: VoiceClock) async -> String {
    let gate = VoiceStopGate()
    return await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
        gate.continuation = continuation
        let deadline = clock.schedule(after: ms) {
            guard gate.continuation != nil else { return }
            session.cancel() // releases the recognizer AND its pending `stop()`
            gate.settle("")
        }
        Task { @MainActor in
            let text = await session.stop()
            deadline.cancel()
            gate.settle(text)
        }
    }
}

/// Resolves a `voiceStopWithDeadline` exactly once — the recognizer and the
/// deadline both race to answer it.
@MainActor
private final class VoiceStopGate {
    var continuation: CheckedContinuation<String, Never>?

    func settle(_ text: String) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: text)
    }
}

/// The phone's own synthesizer, for local acks (plan 4.4). Adapted from the
/// Flutter app's `ios/Runner/LocalTtsBridge.swift`.
///
/// A device action handled locally ("flashlight on") must be confirmed out loud
/// in the same breath. Going to `/api/voice/synthesize` for that would add a
/// whole tunnel round-trip to an action that already finished. Real replies still
/// use the JARVIS voice from the server.
@MainActor
final class DefaultVoiceSynthesizing: NSObject, VoiceSynthesizing, AVSpeechSynthesizerDelegate {

    /// Dart's default. Sits just above Apple's, which reads short confirmations
    /// naturally.
    static let defaultRate: Float = 0.52

    private let synthesizer = AVSpeechSynthesizer()
    private var currentUtterance: AVSpeechUtterance?
    private var pulseTimer: Timer?
    var onPlaybackStart: (() -> Void)?
    var onPlaybackEnd: (() -> Void)?
    var onSpeechPulse: ((Double) -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isAvailable: Bool { true }

    @discardableResult
    func speak(_ text: String, rate: Float = defaultRate) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // An ack is only ever about the turn happening right now — anything
        // still being said is stale.
        stop()
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.rate = min(max(rate, AVSpeechUtteranceMinimumSpeechRate),
                             AVSpeechUtteranceMaximumSpeechRate)
        utterance.voice = Self.preferredVoice()
        currentUtterance = utterance
        synthesizer.speak(utterance)
        return true
    }

    func stop() {
        currentUtterance = nil
        pulseTimer?.invalidate()
        pulseTimer = nil
        onSpeechPulse?(0)
        synthesizer.stopSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didStart utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.currentUtterance === utterance else { return }
            self.onPlaybackStart?()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       willSpeakRangeOfSpeechString range: NSRange,
                                       utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.currentUtterance === utterance else { return }
            // AVSpeechSynthesizer owns its render graph. Its actual word timing
            // gives local confirmations a pulse without changing the low-latency
            // playback path or pretending a fixed level is measured audio.
            self.onSpeechPulse?(0.08 + Double(min(range.length, 12)) * 0.01)
            self.pulseTimer?.invalidate()
            let timer = Timer(timeInterval: 0.12, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.onSpeechPulse?(0) }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.pulseTimer = timer
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        finish(utterance)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        finish(utterance)
    }

    private nonisolated func finish(_ utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.currentUtterance === utterance else { return }
            self.currentUtterance = nil
            self.pulseTimer?.invalidate()
            self.pulseTimer = nil
            self.onSpeechPulse?(0)
            self.onPlaybackEnd?()
        }
    }

    /// Prefer an enhanced/premium voice for the user's own locale — the compact
    /// default sounds noticeably more robotic than the server voice, and these
    /// ship on-device with no download when present.
    private static func preferredVoice() -> AVSpeechSynthesisVoice? {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == language }
        if let premium = candidates.first(where: { $0.quality == .premium }) { return premium }
        if let enhanced = candidates.first(where: { $0.quality == .enhanced }) { return enhanced }
        return AVSpeechSynthesisVoice(language: language) ?? candidates.first
    }
}

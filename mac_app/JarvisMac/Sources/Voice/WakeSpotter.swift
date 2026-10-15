import AVFoundation
import Speech

/// One on-device recognition window listening for "Hey Jarvis". Opened when the
/// VAD hears a voice, closed when it goes quiet (or after 20 s). Never sends audio
/// off the Mac: a recognizer that can't run on-device is refused.
///
/// Threads: `beginWindow` / `endWindow` on main; `feed` from the audio thread;
/// the recognizer calls back on its own thread. Shared state sits behind one lock,
/// and every task carries a generation so a closed window's late callbacks are
/// dropped. Callbacks are delivered on the main thread.
/// After coucou's WakeSpotter (github.com/Louis-CFM/coucou, MIT).
final class WakeSpotter: @unchecked Sendable {
    /// The phrase was heard.
    var onWake: (() -> Void)?
    /// The window ended without it; `true` when it ended on a real error.
    var onWindowEnded: ((Bool) -> Void)?

    struct WindowStats { let partials: Int }

    private let lock = NSLock()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var active = false
    private var partials = 0
    private var gen = SpotterGeneration()

    var isActive: Bool { lock.withLock { active } }

    init(recognizer: SFSpeechRecognizer) {
        self.recognizer = recognizer
    }

    @discardableResult
    func beginWindow(preroll: [AVAudioPCMBuffer]) -> Bool {
        var taskGen = 0
        let req: SFSpeechAudioBufferRecognitionRequest? = lock.withLock {
            guard !active, let r = recognizer, r.supportsOnDeviceRecognition, r.isAvailable else { return nil }
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            req.requiresOnDeviceRecognition = true
            req.taskHint = .search
            req.contextualStrings = ["Jarvis", "Hey Jarvis", "OK Jarvis"]
            preroll.forEach { req.append($0) }
            request = req
            active = true
            partials = 0
            taskGen = gen.bump()
            return req
        }
        guard let req, let r = lock.withLock({ recognizer }) else { return false }
        let t = r.recognitionTask(with: req) { [weak self] result, error in
            self?.handle(result, error: error, expectedGen: taskGen)
        }
        lock.withLock { task = t }
        return true
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { request }?.append(buffer)
    }

    @discardableResult
    func endWindow() -> WindowStats {
        lock.withLock {
            let stats = WindowStats(partials: partials)
            request?.endAudio()
            task?.cancel()
            request = nil
            task = nil
            active = false
            partials = 0
            gen.bump()
            return stats
        }
    }

    private enum Outcome { case woke, ended(Bool) }

    private func handle(_ result: SFSpeechRecognitionResult?, error: Error?, expectedGen: Int) {
        let outcome: Outcome? = lock.withLock {
            guard active, gen.isValid(expectedGen) else { return nil }
            if let heard = result?.bestTranscription.formattedString {
                partials += 1
                if WakePhrase.matches(heard) {
                    request?.endAudio()
                    task?.cancel()
                    request = nil
                    task = nil
                    active = false
                    gen.bump()
                    return .woke
                }
            }
            guard result?.isFinal == true || error != nil else { return nil }
            request = nil
            task = nil
            active = false
            return .ended(error.map { !Self.isExpected($0) } ?? false)
        }
        switch outcome {
        case .woke: DispatchQueue.main.async { [weak self] in self?.onWake?() }
        case .ended(let wasError): DispatchQueue.main.async { [weak self] in self?.onWindowEnded?(wasError) }
        case nil: break
        }
    }

    /// "No speech detected" and cancellations are normal ends, not failures.
    static func isExpected(_ error: Error) -> Bool {
        let e = error as NSError
        if e.domain == "kAFAssistantErrorDomain" && (e.code == 1110 || e.code == 216 || e.code == 203) { return true }
        return e.code == NSUserCancelledError
    }
}

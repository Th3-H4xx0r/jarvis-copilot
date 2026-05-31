import AVFoundation
import Foundation
import Speech

/// Live, programmatically-started speech recognition for the watch.
///
/// watchOS will NOT open the system dictation sheet without a real tap on a
/// TextField, so we can't auto-start that. Instead we drive SFSpeechRecognizer +
/// AVAudioEngine ourselves: tapping the orb (or opening the listen complication)
/// starts the mic immediately — no text box, no second tap. Recognition ends on
/// a short trailing silence (or an explicit stop), then the final transcript is
/// handed back for submission.
@MainActor
final class SpeechRecognizer: ObservableObject {
    @Published var transcript: String = ""
    @Published var isListening: Bool = false

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var onFinal: ((String) -> Void)?

    /// Trailing silence (s) after the last partial result before we auto-submit.
    private let silenceTimeout: TimeInterval = 1.6

    /// Ask for mic + speech-recognition permission. Completion is on the main actor.
    static func requestPermission(_ done: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { speechAuth in
            AVAudioSession.sharedInstance().requestRecordPermission { micOK in
                DispatchQueue.main.async {
                    done(speechAuth == .authorized && micOK)
                }
            }
        }
    }

    static var isAuthorized: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    /// Begin listening. `onFinal` fires once with the transcript when the user
    /// stops talking (silence) or `stop()` is called. No-op if already running
    /// or the recognizer is unavailable.
    func start(onFinal: @escaping (String) -> Void) {
        guard !isListening, let recognizer, recognizer.isAvailable else {
            onFinal("")
            return
        }
        self.onFinal = onFinal
        transcript = ""

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            finish(submit: false)
            onFinal("")
            return
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true  // private + offline-capable
        }
        request = req

        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            self?.request?.append(buf)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            finish(submit: false)
            onFinal("")
            return
        }

        isListening = true
        armSilenceTimer()
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                self.transcript = result.bestTranscription.formattedString
                self.armSilenceTimer()  // reset the silence countdown on each partial
                if result.isFinal { self.finish(submit: true) }
            }
            if error != nil { self.finish(submit: true) }
        }
    }

    /// Stop listening now and submit whatever was transcribed.
    func stop() { finish(submit: true) }

    /// Cancel without submitting.
    func cancel() { finish(submit: false) }

    private func armSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finish(submit: true) }
        }
    }

    private func finish(submit: Bool) {
        guard isListening || task != nil || engine.isRunning else { return }
        silenceTimer?.invalidate(); silenceTimer = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isListening = false
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let cb = onFinal
        onFinal = nil
        if submit, let cb { cb(text) }
    }
}

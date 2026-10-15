import AppKit
import AVFoundation
import Speech

/// Why a dictation couldn't start.
enum DictationFailure: Error, Equatable {
    case micDenied
    case speechDenied
    case unavailable(String)
    case micFailed(String)

    var message: String {
        switch self {
        case .micDenied: return String(localized: "Microphone access is off for Jarvis.")
        case .speechDenied: return String(localized: "Speech recognition is off for Jarvis.")
        case .unavailable(let why), .micFailed(let why): return why
        }
    }

    /// The System Settings pane that fixes it.
    var settingsURL: URL? {
        switch self {
        case .micDenied: return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case .speechDenied: return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
        case .unavailable: return URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
        case .micFailed: return nil
        }
    }
}

/// Microphone and speech-recognition permissions, asked for only when a feature
/// the user turned on needs them.
enum SpeechPermissions {
    static var micAllowed: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    static var speechAllowed: Bool { SFSpeechRecognizer.authorizationStatus() == .authorized }

    /// Asks once (the system remembers); nil when everything needed is allowed.
    static func ensure(speech: Bool = true) async -> DictationFailure? {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        guard micAllowed else { return .micDenied }
        guard speech else { return nil }
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                SFSpeechRecognizer.requestAuthorization { _ in c.resume() }
            }
        }
        return speechAllowed ? nil : .speechDenied
    }

    static func open(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }
}

/// One dictation: the microphone open from `start` to `finish`.
@MainActor
protocol DictationSession: AnyObject {
    var isRecording: Bool { get }
    func start() async -> DictationFailure?
    /// Stops listening and returns everything heard.
    func finish() async -> String
    /// Stops without waiting; the words are dropped.
    func cancel()
}

/// Makes the session for the chosen engine: Apple's SpeechAnalyzer on macOS 26
/// when the Mac has it (and its model for the language is installed), else the
/// on-device SFSpeechRecognizer. Audio never leaves the Mac either way.
@MainActor
enum DictationEngines {
    static func make(_ engine: FlowEngine, words: [String], bands: FlowAudioBands?) async -> DictationSession {
        if engine == .automatic, #available(macOS 26, *), let locale = await AnalyzerDictation.readyLocale() {
            return AnalyzerDictation(locale: locale, words: words, bands: bands)
        }
        return ClassicDictation(words: words, bands: bands)
    }

    /// What Settings shows about the engine in use.
    static func describe(_ engine: FlowEngine) async -> String {
        if engine == .automatic, #available(macOS 26, *) {
            if !SpeechTranscriber.isAvailable { return String(localized: "This Mac uses the on-device recognizer.") }
            if await AnalyzerDictation.readyLocale() != nil { return String(localized: "Using Apple's SpeechAnalyzer, on this Mac.") }
            return String(localized: "Apple's SpeechAnalyzer model is downloading; the on-device recognizer is used meanwhile.")
        }
        return String(localized: "Using the on-device recognizer.")
    }
}

// MARK: - the on-device SFSpeechRecognizer

/// Dictation with SFSpeechRecognizer, on-device only (a language without an
/// on-device model is refused rather than sent to Apple's servers).
@MainActor
final class ClassicDictation: DictationSession {
    private let engine = AVAudioEngine()
    private let words: [String]
    private let bands: FlowAudioBands?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var transcript = DictationTranscript()
    private var done = false
    private var finishing: CheckedContinuation<Void, Never>?
    private var tapInstalled = false
    private(set) var isRecording = false

    init(words: [String], bands: FlowAudioBands?) {
        self.words = words
        self.bands = bands
    }

    static func recognizer() -> SFSpeechRecognizer? {
        for locale in [Locale.current, Locale(identifier: "en-US")] {
            if let r = SFSpeechRecognizer(locale: locale), r.isAvailable, r.supportsOnDeviceRecognition { return r }
        }
        return nil
    }

    func start() async -> DictationFailure? {
        if let failure = await SpeechPermissions.ensure() { return failure }
        guard let recognizer = Self.recognizer() else {
            return .unavailable(String(localized: "On-device speech recognition isn't installed for your language. Turn on Dictation in System Settings → Keyboard."))
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true
        req.addsPunctuation = true
        req.taskHint = .dictation
        req.contextualStrings = Array(words.prefix(100))
        request = req
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return .micFailed(String(localized: "No microphone is connected.")) }
        Self.installTap(on: input, format: format, request: req, bands: bands)
        tapInstalled = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            stopEngine()
            return .micFailed(String(localized: "The microphone didn't start: \(error.localizedDescription)"))
        }
        isRecording = true
        task = Self.recognize(req, with: recognizer) { [weak self] words, pieces, final in
            Task { @MainActor in self?.update(words, pieces: pieces, final: final) }
        }
        return nil
    }

    // Built off the main actor: the audio tap and the recognizer call back on their own threads.
    nonisolated private static func installTap(on input: AVAudioInputNode, format: AVAudioFormat,
                                               request: SFSpeechAudioBufferRecognitionRequest, bands: FlowAudioBands?) {
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
            bands?.consume(buffer)
        }
    }

    nonisolated private static func recognize(
        _ request: SFSpeechAudioBufferRecognitionRequest, with recognizer: SFSpeechRecognizer,
        report: @escaping @Sendable (String?, [DictationTranscript.Piece], Bool) -> Void
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            let words = result?.bestTranscription.formattedString
            let pieces = (result?.bestTranscription.segments ?? []).map {
                DictationTranscript.Piece(start: $0.timestamp, end: $0.timestamp + $0.duration, text: $0.substring)
            }
            report(words, pieces, (result?.isFinal ?? false) || error != nil)
        }
    }

    private func update(_ words: String?, pieces: [DictationTranscript.Piece], final: Bool) {
        if let words { transcript.absorb(words, pieces: pieces) }
        if final {
            done = true
            finishing?.resume()
            finishing = nil
        }
    }

    func finish() async -> String {
        guard isRecording else { return transcript.text }
        stopEngine()
        request?.endAudio()
        if !done {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                finishing = c
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(1500))
                    self?.finishing?.resume()
                    self?.finishing = nil
                }
            }
        }
        tearDown()
        return transcript.text
    }

    func cancel() {
        tearDown()
    }

    private func stopEngine() {
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
        tapInstalled = false
    }

    private func tearDown() {
        stopEngine()
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        isRecording = false
        finishing?.resume()
        finishing = nil
    }
}

// MARK: - SpeechAnalyzer (macOS 26)

/// Dictation with Apple's SpeechAnalyzer + SpeechTranscriber (macOS 26), on-device.
@available(macOS 26, *)
@MainActor
final class AnalyzerDictation: DictationSession {
    private let locale: Locale
    private let words: [String]
    private let bands: FlowAudioBands?
    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Never>?
    private var finalText = ""
    private var volatileText = ""
    private var tapInstalled = false
    private(set) var isRecording = false
    private static var installing = false

    init(locale: Locale, words: [String], bands: FlowAudioBands?) {
        self.locale = locale
        self.words = words
        self.bands = bands
    }

    /// The locale to use, when SpeechTranscriber runs on this Mac and its model is
    /// installed. Otherwise nil — and the model's download starts in the
    /// background so the next dictation can use it.
    static func readyLocale() async -> Locale? {
        guard SpeechTranscriber.isAvailable else { return nil }
        var found = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
        if found == nil { found = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) }
        guard let locale = found else { return nil }
        let installed = await SpeechTranscriber.installedLocales
        if installed.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) { return locale }
        if !installing {
            installing = true
            Task.detached {
                let module = SpeechTranscriber(locale: locale, preset: .transcription)
                do {
                    if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                        try await request.downloadAndInstall()
                    }
                } catch {
                    NSLog("Jarvis Flow: the speech model didn't install: \(error.localizedDescription)")
                }
                await MainActor.run { installing = false }
            }
        }
        return nil
    }

    func start() async -> DictationFailure? {
        if let failure = await SpeechPermissions.ensure() { return failure }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults], attributeOptions: [])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            return .unavailable(String(localized: "Apple's speech model isn't ready on this Mac."))
        }
        do {
            try await analyzer.prepareToAnalyze(in: format)
            if !words.isEmpty {
                let context = AnalysisContext()
                context.contextualStrings[.general] = Array(words.prefix(100))
                try await analyzer.setContext(context)
            }
        } catch {
            return .unavailable(String(localized: "Apple's speech model didn't start: \(error.localizedDescription)"))
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        input = continuation
        self.analyzer = analyzer
        results = Task { @MainActor [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    guard let self else { return }
                    if result.isFinal {
                        self.finalText = Self.join(self.finalText, text)
                        self.volatileText = ""
                    } else {
                        self.volatileText = text
                    }
                }
            } catch {
                NSLog("Jarvis Flow: transcriber stopped: \(error.localizedDescription)")
            }
        }
        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            cancel()
            return .unavailable(String(localized: "Apple's speech model didn't start: \(error.localizedDescription)"))
        }
        let mic = engine.inputNode
        let micFormat = mic.outputFormat(forBus: 0)
        guard micFormat.sampleRate > 0, let converter = AVAudioConverter(from: micFormat, to: format) else {
            cancel()
            return .micFailed(String(localized: "No microphone is connected."))
        }
        converter.downmix = true
        Self.installTap(on: mic, format: micFormat, converter: converter, target: format,
                        into: continuation, bands: bands)
        tapInstalled = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            cancel()
            return .micFailed(String(localized: "The microphone didn't start: \(error.localizedDescription)"))
        }
        isRecording = true
        return nil
    }

    func finish() async -> String {
        guard isRecording, let analyzer else { return Self.join(finalText, volatileText) }
        stopEngine()
        input?.finish()
        input = nil
        // The last words are finalized here; give it a moment, never forever.
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce(c)
            Task { try? await analyzer.finalizeAndFinishThroughEndOfInput(); once.resume() }
            Task { try? await Task.sleep(for: .seconds(2)); once.resume() }
        }
        try? await Task.sleep(for: .milliseconds(60))
        results?.cancel()
        results = nil
        isRecording = false
        self.analyzer = nil
        return Self.join(finalText, volatileText).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() {
        stopEngine()
        input?.finish()
        input = nil
        results?.cancel()
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        analyzer = nil
        isRecording = false
    }

    private func stopEngine() {
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
        tapInstalled = false
    }

    nonisolated private static func installTap(on mic: AVAudioInputNode, format: AVAudioFormat,
                                               converter: AVAudioConverter, target: AVAudioFormat,
                                               into continuation: AsyncStream<AnalyzerInput>.Continuation,
                                               bands: FlowAudioBands?) {
        mic.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            bands?.consume(buffer)
            if let converted = convert(buffer, with: converter, to: target) {
                continuation.yield(AnalyzerInput(buffer: converted))
            }
        }
    }

    nonisolated private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter,
                                            to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if fed { inputStatus.pointee = .noDataNow; return nil }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, out.frameLength > 0 else { return nil }
        return out
    }

    private static func join(_ a: String, _ b: String) -> String {
        let a = a.trimmingCharacters(in: .whitespaces), b = b.trimmingCharacters(in: .whitespaces)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }
}

/// Resumes a continuation the first time, whichever path gets there first.
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ c: CheckedContinuation<Void, Never>) { continuation = c }

    func resume() {
        let c: CheckedContinuation<Void, Never>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        c?.resume()
    }
}

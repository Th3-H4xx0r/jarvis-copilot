import AVFoundation
import Foundation
import Speech

/// Apple's current on-device transcriber (iOS 26 / macOS 26), behind the same
/// `SpeechSession` the voice store already drives. Older systems use the
/// `SFSpeechRecognizer` session in `SpeechServices.swift`.
///
/// Chosen for accuracy: it is the model behind live transcription in Notes and
/// Voice Memos, a clear step up from `SFSpeechRecognizer`'s on-device mode, and
/// the reason on-device transcription is worth offering over the server's.
///
/// It needs NO speech-recognition permission — verified: with authorization
/// never requested and no `NSSpeechRecognitionUsageDescription`, it downloads
/// its model and transcribes. Only the microphone is gated, and the mic is
/// already asked for before a turn starts. The language model is NOT
/// preinstalled; `prepare` downloads it, reporting progress.
@available(iOS 26.0, macOS 26.0, *)
@MainActor
final class AnalyzerSpeechEngine {
    private var locale: Locale?
    private var format: AVAudioFormat?

    /// Whether `prepare` has succeeded, so a session can be made immediately.
    var isPrepared: Bool { locale != nil && format != nil }

    func prepare(onProgress: @escaping @MainActor (Double) -> Void) async -> SpeechReadiness {
        // Cheap once done: every start re-checks readiness, and a re-download
        // check per turn would put the status line through "preparing" each time.
        if isPrepared { return .ready }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
            return .unsupportedLanguage(SpeechReadiness.currentLanguageName)
        }
        let probe = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
                let progress = request.progress
                let ticker = Task { @MainActor in
                    while !Task.isCancelled {
                        onProgress(progress.fractionCompleted)
                        try? await Task.sleep(nanoseconds: 250_000_000)
                    }
                }
                defer { ticker.cancel() }
                try await request.downloadAndInstall()
            }
        } catch {
            JcLog.dropped(JcLog.voice, "speech model download", error)
            return .downloadFailed
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [probe]) else {
            return .unavailable
        }
        self.locale = locale
        self.format = format
        onProgress(1)
        return .ready
    }

    /// A session for one utterance. Nil until `prepare` has succeeded.
    func makeSession(sampleRate: Int) -> SpeechSession? {
        guard let locale, let format,
              let source = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(sampleRate),
                                         channels: 1, interleaved: true)
        else { return nil }
        return AnalyzerSpeechSession(locale: locale, source: source, target: format)
    }
}

/// One utterance through `SpeechAnalyzer`.
@available(iOS 26.0, macOS 26.0, *)
@MainActor
final class AnalyzerSpeechSession: SpeechSession {
    var onPartial: ((String) -> Void)?
    /// Only on stop, cancel or a failed analyzer. Unlike `SFSpeechRecognizer`
    /// this engine does not end itself after a stretch of silence, so the
    /// store's between-utterances re-arm check never fires for it.
    private(set) var isDone = false

    private let source: AVAudioFormat
    private let target: AVAudioFormat
    private let converter: AVAudioConverter?
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private var startTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    /// Text the engine has committed. Final results arrive in pieces, one per
    /// stretch of audio; volatile results are the guess for the stretch still
    /// being heard, and replace each other.
    private var finalized = ""

    init(locale: Locale, source: AVAudioFormat, target: AVAudioFormat) {
        self.source = source
        self.target = target
        converter = source == target ? nil : AVAudioConverter(from: source, to: target)
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        // Created HERE, synchronously: frames the store feeds before the
        // analyzer has finished starting are buffered by the stream, not lost.
        // The first word of an utterance usually arrives in exactly that gap.
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        input = continuation
        resultsTask = Task { @MainActor [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters)
                    if result.isFinal {
                        self.finalized = Self.join(self.finalized, text)
                        self.onPartial?(self.finalized)
                    } else {
                        self.onPartial?(Self.join(self.finalized, text))
                    }
                }
            } catch {
                JcLog.dropped(JcLog.voice, "speech results", error)
            }
        }
        startTask = Task {
            do {
                try await analyzer.start(inputSequence: stream)
            } catch {
                JcLog.dropped(JcLog.voice, "speech analyzer start", error)
            }
        }
    }

    func feed(_ pcm: Data) {
        guard !isDone, let buffer = convert(pcm) else { return }
        input.yield(AnalyzerInput(buffer: buffer))
    }

    /// End the audio and hand back everything the engine committed. The
    /// caller's deadline bounds this, so a stuck analyzer cannot hold a turn.
    func stop() async -> String {
        guard !isDone else { return finalized }
        input.finish()
        // `start` must have begun before there is an analysis to finalize.
        await startTask?.value
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            JcLog.dropped(JcLog.voice, "speech finalize", error)
        }
        await resultsTask?.value
        isDone = true
        return finalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() {
        guard !isDone else { return }
        isDone = true
        input.finish()
        resultsTask?.cancel()
        let analyzer = self.analyzer
        Task { await analyzer.cancelAndFinishNow() }
    }

    private static func join(_ head: String, _ tail: String) -> String {
        let tail = tail.trimmingCharacters(in: .whitespaces)
        guard !tail.isEmpty else { return head }
        return head.isEmpty ? tail : head + " " + tail
    }

    /// 16 kHz mono Int16 LE — the frames the mic path produces — into whatever
    /// format the analyzer asked for.
    private func convert(_ pcm: Data) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(pcm.count / 2)
        guard frames > 0, let raw = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: frames) else {
            return nil
        }
        raw.frameLength = frames
        pcm.withUnsafeBytes { bytes in
            if let dst = raw.int16ChannelData?[0], let src = bytes.baseAddress {
                memcpy(dst, src, Int(frames) * MemoryLayout<Int16>.size)
            }
        }
        guard let converter else { return raw }
        let ratio = target.sampleRate / source.sampleRate
        guard let out = AVAudioPCMBuffer(pcmFormat: target,
                                         frameCapacity: AVAudioFrameCount(Double(frames) * ratio) + 64)
        else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return raw
        }
        guard status != .error, out.frameLength > 0 else { return nil }
        return out
    }
}

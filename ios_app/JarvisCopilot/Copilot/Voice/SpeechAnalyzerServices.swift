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
///
/// ## What this framework can and cannot do about language
///
/// `SpeechTranscriber` takes ONE `Locale`. There is no multi-language
/// transcriber and no language-identification module in the iOS 26/27 Speech
/// framework — `SpeechTranscriber.init` has exactly two forms and both take a
/// single `locale:`. So hearing more than one language means running more than
/// one recogniser over the same audio (`MultiLocaleSpeechSession` below), and
/// the cost is linear in the number of languages. Nothing here guesses a
/// language it was not asked to listen for.
@available(iOS 26.0, macOS 26.0, *)
@MainActor
final class AnalyzerSpeechEngine {

    /// One language this engine has a model for: the locale `SpeechTranscriber`
    /// actually matched (which is not always the one asked for — `en_GB@rg=uszzzz`
    /// resolves to `en-GB`), and the audio format its analyzer wants.
    private struct Prepared {
        let locale: Locale
        let format: AVAudioFormat
    }

    /// Keyed by RESOLVED BCP-47 identifier.
    private var prepared: [String: Prepared] = [:]
    /// Requested identifier → resolved identifier, so asking twice for the same
    /// language does not repeat `supportedLocale(equivalentTo:)`.
    private var resolvedKeys: [String: String] = [:]
    /// The device-language entry. The voice turn uses this one and only this one.
    private var defaultKey = ""

    /// Live's preset, built explicitly rather than taken from
    /// `.progressiveTranscription`, for one reason: `transcriptionConfidence`.
    /// With more than one language running over the same audio, the engine's own
    /// confidence is what picks the winner. Without it, choosing would be a guess
    /// wearing detection's clothes.
    ///
    /// The voice turn deliberately keeps `.progressiveTranscription` — it has one
    /// language and no reason to take the change.
    static let livePreset = SpeechTranscriber.Preset(
        transcriptionOptions: [],
        reportingOptions: [.volatileResults],
        attributeOptions: [.audioTimeRange, .transcriptionConfidence])

    /// Whether the device language is ready, so a voice turn can start at once.
    var isPrepared: Bool { !defaultKey.isEmpty && prepared[defaultKey] != nil }

    /// The languages a model is installed for, as BCP-47 identifiers.
    var preparedLanguages: [String] { Array(prepared.keys) }

    func prepare(onProgress: @escaping @MainActor (Double) -> Void) async -> SpeechReadiness {
        // Cheap once done: every start re-checks readiness, and a re-download
        // check per turn would put the status line through "preparing" each time.
        if isPrepared { return .ready }
        let outcome = await install(.current, onProgress: onProgress)
        if outcome == .ready { defaultKey = resolvedKeys[Locale.current.identifier] ?? "" }
        return outcome
    }

    /// Prepare every language the user says might be spoken.
    ///
    /// Ready when AT LEAST ONE of them is. Refusing the whole session because the
    /// third language has no model would take transcription away entirely, which
    /// is a far worse outcome than hearing two of the three.
    @discardableResult
    func prepare(locales: [Locale],
                 onProgress: @escaping @MainActor (Double) -> Void) async -> SpeechReadiness {
        guard !locales.isEmpty else { return await prepare(onProgress: onProgress) }
        var outcome: SpeechReadiness = .unavailable
        for locale in locales {
            let one = await install(locale, onProgress: onProgress)
            if one == .ready { outcome = .ready }
            // Keep the most informative refusal seen so far, so the panel can say
            // "that language isn't supported" rather than a flat "unavailable".
            else if outcome != .ready, outcome == .unavailable { outcome = one }
        }
        return outcome
    }

    private func install(_ locale: Locale,
                         onProgress: @escaping @MainActor (Double) -> Void) async -> SpeechReadiness {
        if let key = resolvedKeys[locale.identifier], prepared[key] != nil { return .ready }
        guard let match = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            let name = Locale.current.localizedString(forIdentifier: locale.identifier)
                ?? locale.identifier
            return .unsupportedLanguage(name)
        }
        let key = match.identifier(.bcp47)
        if prepared[key] != nil {
            resolvedKeys[locale.identifier] = key
            return .ready
        }
        let probe = SpeechTranscriber(locale: match, preset: .progressiveTranscription)
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
        prepared[key] = Prepared(locale: match, format: format)
        resolvedKeys[locale.identifier] = key
        onProgress(1)
        return .ready
    }

    /// A session for one utterance in the device's language. Nil until `prepare`
    /// has succeeded.
    func makeSession(sampleRate: Int) -> SpeechSession? {
        guard let entry = prepared[defaultKey] else { return nil }
        return session(entry, sampleRate: sampleRate, preset: .progressiveTranscription)
    }

    /// A session for one utterance that might be in any of `locales`.
    ///
    /// One recogniser per language, all fed the same frames, the winner chosen on
    /// confidence when the engine reports it. Costs roughly N× the transcription
    /// work of one language — see `MultiLocaleSpeechSession`.
    ///
    /// Falls back to the device language when none of the requested languages is
    /// prepared, so a typo in the settings cannot silence the transcript.
    func makeSession(sampleRate: Int, locales: [Locale]) -> SpeechSession? {
        var seen = Set<String>()
        let entries = locales.compactMap { locale -> Prepared? in
            let key = resolvedKeys[locale.identifier] ?? locale.identifier
            guard let entry = prepared[key], seen.insert(entry.locale.identifier(.bcp47)).inserted
            else { return nil }
            return entry
        }
        guard !entries.isEmpty else { return makeSession(sampleRate: sampleRate) }
        let made = entries.compactMap { session($0, sampleRate: sampleRate, preset: Self.livePreset) }
        guard let first = made.first else { return nil }
        guard made.count > 1 else { return first }
        return MultiLocaleSpeechSession(children: made)
    }

    private func session(_ entry: Prepared, sampleRate: Int,
                         preset: SpeechTranscriber.Preset) -> AnalyzerSpeechSession? {
        guard let source = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: Double(sampleRate),
                                         channels: 1, interleaved: true)
        else { return nil }
        return AnalyzerSpeechSession(locale: entry.locale, source: source,
                                     target: entry.format, preset: preset)
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

    let locale: Locale

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

    /// The union of the audio time ranges of the FINAL results, in ms from the
    /// first buffer fed. Volatile results are excluded: they cover the stretch
    /// still being heard and their range moves.
    private var rangeStartMs: Int?
    private var rangeEndMs: Int?

    /// Confidence, weighted by how much text each run covers, so a long
    /// well-recognised sentence outranks one confident word.
    private var confidenceSum = 0.0
    private var confidenceChars = 0

    init(locale: Locale, source: AVAudioFormat, target: AVAudioFormat,
         preset: SpeechTranscriber.Preset = .progressiveTranscription) {
        self.locale = locale
        self.source = source
        self.target = target
        converter = source == target ? nil : AVAudioConverter(from: source, to: target)
        let transcriber = SpeechTranscriber(locale: locale, preset: preset)
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
                        self.note(range: result.range)
                        self.note(confidenceOf: result.text)
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

    /// Where the words actually were. See `SpeechSession.transcribedRangeMs`.
    var transcribedRangeMs: ClosedRange<Int>? {
        guard let start = rangeStartMs, let end = rangeEndMs, end > start else { return nil }
        return start...end
    }

    var resolvedLanguage: String? { locale.identifier(.bcp47) }

    /// Mean confidence over the committed text, or nil when the engine reported
    /// none — the preset has to ask for it, and the voice turn's does not.
    var meanConfidence: Double? {
        confidenceChars > 0 ? confidenceSum / Double(confidenceChars) : nil
    }

    /// What `stop()` resolved to, for a wrapper that already awaited it.
    var finalText: String { finalized.trimmingCharacters(in: .whitespacesAndNewlines) }

    func feed(_ pcm: Data) {
        guard !isDone, let buffer = convert(pcm) else { return }
        input.yield(AnalyzerInput(buffer: buffer))
    }

    /// End the audio and hand back everything the engine committed. The
    /// caller's deadline bounds this, so a stuck analyzer cannot hold a turn.
    func stop() async -> String {
        guard !isDone else { return finalText }
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
        return finalText
    }

    func cancel() {
        guard !isDone else { return }
        isDone = true
        input.finish()
        resultsTask?.cancel()
        let analyzer = self.analyzer
        Task { await analyzer.cancelAndFinishNow() }
    }

    /// `SpeechTranscriber.Result.range` is relative to the analyzer's input
    /// timeline, and this session's timeline starts at its first buffer — so
    /// these are ms from the start of the audio the caller fed, which is what
    /// the caller can anchor to its own audio clock.
    private func note(range: CMTimeRange) {
        let start = range.start.seconds
        let end = range.end.seconds
        guard start.isFinite, end.isFinite, start >= 0, end > start else { return }
        let startMs = Int((start * 1000).rounded())
        let endMs = Int((end * 1000).rounded())
        rangeStartMs = min(rangeStartMs ?? startMs, startMs)
        rangeEndMs = max(rangeEndMs ?? endMs, endMs)
    }

    private func note(confidenceOf text: AttributedString) {
        for run in text.runs {
            guard let confidence = run.transcriptionConfidence else { continue }
            let characters = text[run.range].characters.count
            guard characters > 0 else { continue }
            confidenceSum += confidence * Double(characters)
            confidenceChars += characters
        }
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

/// One utterance heard by several recognisers at once, one per language.
///
/// The framework has no multi-language transcriber and no language identifier,
/// so this is what "the room might be speaking Spanish" costs: every selected
/// language runs its own `SpeechAnalyzer` over the same frames. Two languages is
/// about twice the transcription CPU and twice the model resident in memory;
/// three is three times. On a recorder that listens continuously that is real
/// battery, which is why the set is the user's explicit choice and why the
/// settings screen says so out loud.
///
/// Nothing here detects a language. It reports which of the recognisers the user
/// asked for produced the best-scoring text, and `resolvedLanguage` is that
/// recogniser's locale — which is what the transcript row is then labelled with,
/// because the server's auto-translate keys on exactly that field.
@available(iOS 26.0, macOS 26.0, *)
@MainActor
final class MultiLocaleSpeechSession: SpeechSession {
    var onPartial: ((String) -> Void)?
    private(set) var isDone = false

    private let children: [AnalyzerSpeechSession]
    private var winner: AnalyzerSpeechSession?

    init(children: [AnalyzerSpeechSession]) {
        self.children = children
        // Live text comes from the FIRST language only. Interleaving several
        // recognisers' guesses would make the in-progress line flicker between
        // languages mid-sentence; the choice is made once, at the end, on the
        // committed text.
        children.first?.onPartial = { [weak self] text in self?.onPartial?(text) }
    }

    func feed(_ pcm: Data) {
        guard !isDone else { return }
        for child in children { child.feed(pcm) }
    }

    func stop() async -> String {
        guard !isDone else { return winner?.finalText ?? "" }
        var heard: [AnalyzerSpeechSession] = []
        for child in children where !(await child.stop()).isEmpty { heard.append(child) }
        isDone = true
        guard let first = heard.first else { return "" }
        // Confidence decides ONLY when every candidate reported one. A mix would
        // be comparing a number against an invention, so the fallback is the
        // order the user listed their languages in — a rule they can see on the
        // settings screen and change, rather than a guess about the audio.
        let scored = heard.allSatisfy { $0.meanConfidence != nil } && heard.count > 1
        winner = scored
            ? (heard.max { ($0.meanConfidence ?? 0) < ($1.meanConfidence ?? 0) } ?? first)
            : first
        return winner?.finalText ?? ""
    }

    func cancel() {
        guard !isDone else { return }
        isDone = true
        for child in children { child.cancel() }
    }

    var transcribedRangeMs: ClosedRange<Int>? { winner?.transcribedRangeMs }
    var resolvedLanguage: String? { winner?.resolvedLanguage }
}

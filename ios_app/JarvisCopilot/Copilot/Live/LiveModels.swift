import Foundation
import NaturalLanguage
#if canImport(FluidAudio)
import FluidAudio
#endif

/// What an on-device transcriber made of one utterance: the words, and the
/// language they are in.
struct OnDeviceHeard: Equatable, Sendable {
    var text: String
    /// Primary BCP-47 subtag (`es`), or "" when nothing could tell.
    var language: String
    var confidence: Double
}

/// Something that re-hears a finished utterance on the phone. A protocol so the
/// store's choice between it and Apple's recogniser is testable without CoreML.
protocol OnDeviceTranscribing: AnyObject, Sendable {
    func transcribe(pcm16: Data) async -> OnDeviceHeard?
}

/// The models Live can download and run on the phone.
///
/// Apple's recogniser takes ONE locale, so Spanish spoken into an English phone
/// comes out spelled phonetically ("Hola, Como Stas") and labelled English —
/// which is why it was never translated, and why the server's Whisper had to
/// re-hear every line (~3 s a foreign line). Measured on his own recordings,
/// Parakeet v3 heard the same audio as "Hola, ¿cómo estás?" in ~50 ms, and
/// SenseVoice is the only one of the three that read his friend's Mandarin.
enum LiveModelKind: String, CaseIterable, Identifiable, Sendable {
    case parakeet
    case senseVoice

    var id: String { rawValue }

    var title: String {
        switch self {
        case .parakeet: return "Any-language transcription"
        case .senseVoice: return "Chinese, Japanese & Korean"
        }
    }

    var detail: String {
        switch self {
        case .parakeet:
            return "Parakeet v3 · 25 European languages. Re-hears each line on the phone "
                 + "and corrects the ones spoken in another language."
        case .senseVoice:
            return "SenseVoice · Mandarin, Cantonese, Japanese, Korean. Used only for "
                 + "lines Parakeet cannot place."
        }
    }

    /// As downloaded, for the confirmation and the settings row.
    var approxBytes: Int64 {
        switch self {
        case .parakeet: return 469_000_000
        case .senseVoice: return 453_000_000
        }
    }

    /// The languages it transcribes well enough to relabel a line with.
    var languages: Set<String> {
        switch self {
        case .parakeet:
            return ["bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu",
                    "it", "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk"]
        case .senseVoice:
            return ["zh", "yue", "ja", "ko"]
        }
    }
}

enum LiveModelState: Equatable, Sendable {
    case absent
    case downloading(fraction: Double, phase: String)
    /// On disk and being loaded into memory — the first load compiles for this
    /// phone's Neural Engine and takes seconds.
    case preparing
    case ready
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .downloading, .preparing: return true
        default: return false
        }
    }
}

/// The phone's downloadable models: what is on disk, what is downloading, and
/// the transcriber built from whichever the user has.
@MainActor
@Observable
final class LiveModels {
    static let shared = LiveModels()

    private(set) var states: [LiveModelKind: LiveModelState] = [:]
    /// Set when a download finishes, so the popup can say so before it goes.
    private(set) var justFinished: LiveModelKind?

    private var tasks: [LiveModelKind: Task<Void, Never>] = [:]
    private var engine: OnDeviceTranscriber?

    init() { refresh() }

    func state(_ kind: LiveModelKind) -> LiveModelState { states[kind] ?? .absent }

    /// The model the popup should talk about: whatever is downloading or loading.
    var busy: (kind: LiveModelKind, state: LiveModelState)? {
        for kind in LiveModelKind.allCases where state(kind).isBusy { return (kind, state(kind)) }
        return nil
    }

    /// Re-read what is on disk. Leaves an in-flight download, and a failure the
    /// user has not acted on, alone.
    func refresh() {
        for kind in LiveModelKind.allCases where !state(kind).isBusy {
            if Self.onDisk(kind) { states[kind] = .ready }
            else if case .failed = state(kind) { continue }
            else { states[kind] = .absent }
        }
    }

    func download(_ kind: LiveModelKind) {
        guard tasks[kind] == nil else { return }
        states[kind] = .downloading(fraction: 0, phase: "Starting")
        justFinished = nil
        tasks[kind] = Task { [weak self] in
            do {
                try await Self.fetch(kind) { progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.state(kind).isBusy else { return }
                        self.states[kind] = .downloading(fraction: progress.fraction,
                                                          phase: progress.phase)
                    }
                }
                guard let self, !Task.isCancelled else { return }
                self.states[kind] = .ready
                self.engine = nil          // rebuilt with the new model next time
                self.justFinished = kind
            } catch {
                guard let self else { return }
                self.states[kind] = Task.isCancelled ? .absent : .failed(error.localizedDescription)
            }
            self?.tasks[kind] = nil
        }
    }

    func cancel(_ kind: LiveModelKind) {
        tasks[kind]?.cancel()
        tasks[kind] = nil
        states[kind] = Self.onDisk(kind) ? .ready : .absent
    }

    func remove(_ kind: LiveModelKind) {
        cancel(kind)
        if let folder = Self.folder(kind) { try? FileManager.default.removeItem(at: folder) }
        engine = nil
        states[kind] = .absent
    }

    func dismissFinished() { justFinished = nil }

    /// The transcriber for a recording, built from the models on disk — or nil
    /// when there are none, and Apple's recogniser stands alone as before.
    func transcriber() async -> OnDeviceTranscribing? {
        if let engine { return engine }
        let wanted = LiveModelKind.allCases.filter { Self.onDisk($0) }
        guard !wanted.isEmpty else { return nil }
        for kind in wanted { states[kind] = .preparing }
        let made = await OnDeviceTranscriber.load(wanted)
        for kind in wanted {
            states[kind] = made?.has(kind) == true ? .ready : .failed("It would not load on this iPhone.")
        }
        engine = made
        return made
    }

    // MARK: - Disk

    struct Progress: Sendable { var fraction: Double; var phase: String }

    nonisolated static func onDisk(_ kind: LiveModelKind) -> Bool {
        #if canImport(FluidAudio)
        guard let folder = folder(kind) else { return false }
        switch kind {
        case .parakeet: return AsrModels.modelsExist(at: folder, version: .v3)
        case .senseVoice: return SenseVoiceModels.modelsExist(at: folder)
        }
        #else
        return false
        #endif
    }

    /// Where FluidAudio keeps each model. SenseVoice's own helper is private, but
    /// both live side by side under FluidAudio's `Models/` folder.
    nonisolated static func folder(_ kind: LiveModelKind) -> URL? {
        #if canImport(FluidAudio)
        let parakeet = AsrModels.defaultCacheDirectory(for: .v3)
        switch kind {
        case .parakeet: return parakeet
        case .senseVoice:
            return parakeet.deletingLastPathComponent().appendingPathComponent("sensevoice-small",
                                                                                isDirectory: true)
        }
        #else
        return nil
        #endif
    }

    nonisolated private static func fetch(_ kind: LiveModelKind,
                                          progress: @escaping @Sendable (Progress) -> Void) async throws {
        #if canImport(FluidAudio)
        let handler: ProgressHandler = { update in
            let phase: String
            switch update.phase {
            case .listing: phase = "Finding files"
            case .downloading: phase = "Downloading"
            case .compiling: phase = "Preparing for this iPhone"
            }
            progress(Progress(fraction: update.fractionCompleted, phase: phase))
        }
        switch kind {
        case .parakeet: _ = try await AsrModels.download(version: .v3, progressHandler: handler)
        case .senseVoice: _ = try await SenseVoiceModels.download(progressHandler: handler)
        }
        #endif
    }
}

/// Parakeet first, SenseVoice for what Parakeet cannot place.
final class OnDeviceTranscriber: OnDeviceTranscribing, @unchecked Sendable {
    #if canImport(FluidAudio)
    private let parakeet: AsrManager?
    private let senseVoice: SenseVoiceManager?

    private init(parakeet: AsrManager?, senseVoice: SenseVoiceManager?) {
        self.parakeet = parakeet
        self.senseVoice = senseVoice
    }

    func has(_ kind: LiveModelKind) -> Bool {
        kind == .parakeet ? parakeet != nil : senseVoice != nil
    }

    static func load(_ kinds: [LiveModelKind]) async -> OnDeviceTranscriber? {
        var parakeet: AsrManager?
        var senseVoice: SenseVoiceManager?
        if kinds.contains(.parakeet), let folder = LiveModels.folder(.parakeet) {
            do {
                let models = try await AsrModels.load(from: folder, version: .v3)
                let manager = AsrManager(config: .default)
                try await manager.loadModels(models)
                parakeet = manager
            } catch {
                JcLog.dropped(JcLog.voice, "load Parakeet", error)
            }
        }
        if kinds.contains(.senseVoice) {
            do { senseVoice = try await SenseVoiceManager.load() } catch {
                JcLog.dropped(JcLog.voice, "load SenseVoice", error)
            }
        }
        guard parakeet != nil || senseVoice != nil else { return nil }
        return OnDeviceTranscriber(parakeet: parakeet, senseVoice: senseVoice)
    }

    func transcribe(pcm16: Data) async -> OnDeviceHeard? {
        let samples = pcm16.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32768 }
        }
        guard samples.count >= 16_000 / 2 else { return nil }
        // Only a confident answer in a language the model really transcribes:
        // on his Telugu, Parakeet wrote "Okati plus Okati is Modu." and the
        // text read as Turkish at 0.90 — a guess, not a language to relabel with.
        if let parakeet {
            var state = TdtDecoderState.make()
            if let text = try? await parakeet.transcribe(samples, decoderState: &state).text {
                let heard = Self.label(text)
                if heard.confidence >= 0.9, LiveModelKind.parakeet.languages.contains(heard.language) {
                    return heard
                }
            }
        }
        if let senseVoice, let text = try? await senseVoice.transcribe(audio: samples) {
            let heard = Self.label(text)
            if heard.confidence >= 0.9, LiveModelKind.senseVoice.languages.contains(heard.language) {
                return heard
            }
        }
        return nil
    }
    #else
    func has(_ kind: LiveModelKind) -> Bool { false }
    static func load(_ kinds: [LiveModelKind]) async -> OnDeviceTranscriber? { nil }
    func transcribe(pcm16: Data) async -> OnDeviceHeard? { nil }
    #endif

    /// The language of some text, by Apple's NaturalLanguage — reliable on real
    /// words ("Hola, ¿cómo estás?" → es 0.99) and honestly unsure about phonetic
    /// spellings, which is exactly the signal wanted here.
    static func label(_ text: String) -> OnDeviceHeard {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let recogniser = NLLanguageRecognizer()
        recogniser.processString(clean)
        guard let top = recogniser.languageHypotheses(withMaximum: 1).first else {
            return OnDeviceHeard(text: clean, language: "", confidence: 0)
        }
        let code = top.key.rawValue.lowercased().split(separator: "-").first.map(String.init) ?? ""
        return OnDeviceHeard(text: clean, language: code, confidence: top.value)
    }
}

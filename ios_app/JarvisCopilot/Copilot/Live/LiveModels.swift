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
        case .parakeet: return "Parakeet (European languages)"
        case .senseVoice: return "SenseVoice (Chinese, Japanese & Korean)"
        }
    }

    var shortName: String {
        switch self {
        case .parakeet: return "Parakeet"
        case .senseVoice: return "SenseVoice"
        }
    }

    var detail: String {
        switch self {
        case .parakeet:
            return "Re-hears lines in 25 European languages."
        case .senseVoice:
            return "Re-hears Mandarin, Cantonese, Japanese and Korean, for the lines "
                 + "Parakeet cannot place."
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

/// Who re-hears a line spoken in a language other than the primary one: the
/// server's Whisper, a few seconds later, or a model on this phone at once.
///
/// One choice rather than a switch per model, because that is the decision the
/// user is actually making, and SenseVoice without Parakeet is not a useful
/// combination: SenseVoice only speaks when Parakeet cannot place a line.
enum LiveHearing: String, CaseIterable, Identifiable, Sendable {
    case server
    case phone
    case phoneAll

    var id: String { rawValue }

    /// The models this choice runs, in the order they are tried.
    var kinds: [LiveModelKind] {
        switch self {
        case .server: return []
        case .phone: return [.parakeet]
        case .phoneAll: return [.parakeet, .senseVoice]
        }
    }

    var title: String {
        switch self {
        case .server: return "Server"
        case .phone: return "This phone"
        case .phoneAll: return "This phone, plus Chinese, Japanese & Korean"
        }
    }

    var detail: String {
        switch self {
        case .server: return "Nothing to download. Lines are corrected a few seconds later."
        case .phone: return "25 European languages, corrected as each line ends."
        case .phoneAll: return "Adds Mandarin, Cantonese, Japanese and Korean."
        }
    }

    /// What picking it would still download.
    var bytesToGet: Int64 {
        kinds.filter { !LiveModels.onDisk($0) }.reduce(0) { $0 + $1.approxBytes }
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

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
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
    /// The models `engine` was built from, so a changed choice rebuilds it.
    private var engineKinds: [LiveModelKind] = []

    static let hearingKey = "jc_live_hearing"
    private let defaults: KeyValueStore

    /// Who re-hears other languages. Per phone: the models are on THIS phone.
    private(set) var hearing: LiveHearing

    init(defaults: KeyValueStore = UserDefaults.standard) {
        self.defaults = defaults
        // Nothing chosen yet: whatever is already downloaded is what was meant
        // (models fetched before this choice existed were all in use).
        hearing = defaults.string(Self.hearingKey).flatMap(LiveHearing.init(rawValue:))
            ?? (Self.onDisk(.senseVoice) ? .phoneAll : Self.onDisk(.parakeet) ? .phone : .server)
        refresh()
    }

    /// Pick who re-hears other languages, fetching whatever that needs.
    ///
    /// A download the new choice no longer needs is stopped; a model already
    /// on disk stays there, since picking Server for a day should not cost a
    /// 469 MB download to come back. Removing it is Downloads' job.
    func choose(_ choice: LiveHearing) {
        hearing = choice
        defaults.set(choice.rawValue, forKey: Self.hearingKey)
        for kind in LiveModelKind.allCases where !choice.kinds.contains(kind) {
            if case .downloading = state(kind) { cancel(kind) }
        }
        for kind in choice.kinds where !Self.onDisk(kind) { download(kind) }
    }

    /// What the downloaded models take on this phone.
    var bytesOnDisk: Int64 {
        LiveModelKind.allCases.filter { Self.onDisk($0) }.reduce(0) { $0 + $1.approxBytes }
    }

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
        // The choice follows what is left, rather than naming a model that is
        // gone — which would read as "This phone" while the server did the work.
        if hearing.kinds.contains(kind) {
            let left: LiveHearing = kind == .senseVoice && Self.onDisk(.parakeet) ? .phone : .server
            hearing = left
            defaults.set(left.rawValue, forKey: Self.hearingKey)
        }
    }

    func dismissFinished() { justFinished = nil }

    /// The transcriber for a recording, built from the models the user chose
    /// that are on disk — or nil, and Apple's recogniser stands alone as before.
    /// Cheap when nothing changed, so the store asks again after every line and
    /// a finished download or a changed choice is picked up mid-recording.
    func transcriber() async -> OnDeviceTranscribing? {
        let wanted = hearing.kinds.filter { Self.onDisk($0) }
        if let engine, engineKinds == wanted { return engine }
        engine = nil
        engineKinds = wanted
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

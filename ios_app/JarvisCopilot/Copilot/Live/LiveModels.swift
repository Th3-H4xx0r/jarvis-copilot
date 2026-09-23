import CoreML
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
    /// Sortformer: who is speaking, frame by frame — not a transcriber.
    case speakers

    var id: String { rawValue }

    var title: String {
        switch self {
        case .parakeet: return "Parakeet (European languages)"
        case .senseVoice: return "SenseVoice (Chinese, Japanese & Korean)"
        case .speakers: return "Sortformer (overlapping voices)"
        }
    }

    var shortName: String {
        switch self {
        case .parakeet: return "Parakeet"
        case .senseVoice: return "SenseVoice"
        case .speakers: return "Sortformer"
        }
    }

    var detail: String {
        switch self {
        case .parakeet:
            return "Re-hears lines in 25 European languages."
        case .senseVoice:
            return "Re-hears Mandarin, Cantonese, Japanese and Korean, for the lines "
                 + "Parakeet cannot place."
        case .speakers:
            return "Tells voices apart while they overlap, and splits a line where the "
                 + "speaker changes."
        }
    }

    /// As downloaded, for the confirmation and the settings row.
    var approxBytes: Int64 {
        switch self {
        case .parakeet: return 469_000_000
        case .senseVoice: return 453_000_000
        // The palettized build: 106 MB against 469 MB, and on his overlap
        // clip it found the same second voice at the same frames.
        case .speakers: return 106_000_000
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
        case .speakers:
            return []
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

    /// Each model loaded onto the Neural Engine, kept for the life of the app.
    /// Loaded one at a time and only when Record was pressed, the slow one
    /// (SenseVoice, ~7 s on every launch, measured on the Mac) held Parakeet
    /// (0.1-0.2 s) back with it, into the recording, under a popup that said
    /// "Getting Parakeet ready" the whole time.
    private var loaded: [LiveModelKind: LiveLoadedModel] = [:]
    private var loading: [LiveModelKind: Task<Void, Never>] = [:]
    /// How long each took to load this launch, shown in Downloads.
    private(set) var loadSeconds: [LiveModelKind: Double] = [:]

    static let hearingKey = "jc_live_hearing"
    private let defaults: KeyValueStore

    /// Who re-hears other languages. Per phone: the models are on THIS phone.
    private(set) var hearing: LiveHearing

    static let splitsSpeakersKey = "jc_live_split_speakers"
    /// Whether this phone tells overlapping voices apart (Sortformer) and
    /// splits a line where the speaker changes.
    private(set) var splitsSpeakers: Bool

    /// Every model the current choices run.
    private var wanted: [LiveModelKind] { hearing.kinds + (splitsSpeakers ? [.speakers] : []) }

    init(defaults: KeyValueStore = UserDefaults.standard) {
        self.defaults = defaults
        // Nothing chosen yet: whatever is already downloaded is what was meant
        // (models fetched before this choice existed were all in use).
        hearing = defaults.string(Self.hearingKey).flatMap(LiveHearing.init(rawValue:))
            ?? (Self.onDisk(.senseVoice) ? .phoneAll : Self.onDisk(.parakeet) ? .phone : .server)
        splitsSpeakers = defaults.bool(Self.splitsSpeakersKey) ?? false
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
        for kind in LiveModelKind.allCases where !wanted.contains(kind) {
            if case .downloading = state(kind) { cancel(kind) }
            unload(kind)
        }
        for kind in choice.kinds where !Self.onDisk(kind) { download(kind) }
        prepare()
    }

    /// Turn overlapping-voice splitting on or off, fetching Sortformer if needed.
    func setSplitsSpeakers(_ on: Bool) {
        splitsSpeakers = on
        defaults.set(on, forKey: Self.splitsSpeakersKey)
        if on {
            if !Self.onDisk(.speakers) { download(.speakers) }
            prepare()
        } else {
            if case .downloading = state(.speakers) { cancel(.speakers) }
            unload(.speakers)
        }
    }

    /// A fresh speaker tracker for one recording — nil until Sortformer is
    /// loaded, or when splitting is off. Fresh because its voice slots belong
    /// to the audio it has heard.
    func speakerTracker() -> LiveSpeakerTracking? {
        prepare()
        #if canImport(FluidAudio)
        guard splitsSpeakers, let models = loaded[.speakers]?.sortformer else { return nil }
        return SortformerSpeakerTracker(models: models)
        #else
        return nil
        #endif
    }

    /// Start loading every chosen model that is on disk and not loaded yet —
    /// all at once, and without anyone waiting on it. Called when the Live tab
    /// shows and when a download lands, so a recording finds them ready.
    func prepare() {
        for kind in wanted
        where Self.onDisk(kind) && loaded[kind] == nil && loading[kind] == nil && !state(kind).isBusy {
            states[kind] = .preparing
            let started = Date()
            loading[kind] = Task { [weak self] in
                let model = await LiveLoadedModel.load(kind)
                guard let self else { return }
                self.loading[kind] = nil
                guard !Task.isCancelled, self.wanted.contains(kind) else {
                    if self.state(kind) == .preparing { self.states[kind] = .ready }
                    return
                }
                if let model {
                    let seconds = Date().timeIntervalSince(started)
                    self.loaded[kind] = model
                    self.loadSeconds[kind] = seconds
                    self.states[kind] = .ready
                    JcLog.voice.info("live: \(kind.rawValue, privacy: .public) loaded in \(seconds, format: .fixed(precision: 2)) s")
                } else {
                    self.states[kind] = .failed("It would not load on this iPhone.")
                }
            }
        }
    }

    /// Let go of a model the choice no longer uses — each holds hundreds of MB.
    private func unload(_ kind: LiveModelKind) {
        loading[kind]?.cancel()
        loading[kind] = nil
        loaded[kind] = nil
        loadSeconds[kind] = nil
        if state(kind) == .preparing { states[kind] = Self.onDisk(kind) ? .ready : .absent }
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
                self.justFinished = kind
                self.tasks[kind] = nil
                // Onto the Neural Engine now, not when Record is next pressed.
                self.prepare()
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
        unload(kind)
        if let folder = Self.folder(kind) { try? FileManager.default.removeItem(at: folder) }
        states[kind] = .absent
        // The choice follows what is left, rather than naming a model that is
        // gone — which would read as "This phone" while the server did the work.
        if hearing.kinds.contains(kind) {
            let left: LiveHearing = kind == .senseVoice && Self.onDisk(.parakeet) ? .phone : .server
            hearing = left
            defaults.set(left.rawValue, forKey: Self.hearingKey)
        }
        if kind == .speakers, splitsSpeakers {
            splitsSpeakers = false
            defaults.set(false, forKey: Self.splitsSpeakersKey)
        }
    }

    func dismissFinished() { justFinished = nil }

    /// The transcriber for a recording, from the chosen models that are loaded
    /// RIGHT NOW — or nil, and Apple's recogniser stands alone as before. It
    /// never waits for a load: it starts any that are missing and answers with
    /// what is ready, and the store asks again after every line, so Parakeet
    /// is used the moment it is loaded whatever SenseVoice is doing.
    func transcriber() async -> OnDeviceTranscribing? {
        prepare()
        let ready = hearing.kinds.filter { loaded[$0] != nil }
        if let engine, engineKinds == ready { return engine }
        engineKinds = ready
        engine = ready.isEmpty ? nil : OnDeviceTranscriber(ready.compactMap { loaded[$0] })
        return engine
    }

    // MARK: - Disk

    struct Progress: Sendable { var fraction: Double; var phase: String }

    nonisolated static func onDisk(_ kind: LiveModelKind) -> Bool {
        #if canImport(FluidAudio)
        guard let folder = folder(kind) else { return false }
        switch kind {
        case .parakeet: return AsrModels.modelsExist(at: folder, version: .v3)
        case .senseVoice: return SenseVoiceModels.modelsExist(at: folder)
        case .speakers:
            guard let bundle = ModelNames.Sortformer.bundle(for: SortformerSpeakerTracker.config)
            else { return false }
            return FileManager.default.fileExists(
                atPath: folder.appendingPathComponent(bundle).appendingPathComponent("coremldata.bin").path)
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
        case .speakers:
            return parakeet.deletingLastPathComponent().appendingPathComponent("sortformer",
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
        case .speakers:
            _ = try await SortformerModels.loadFromHuggingFace(config: SortformerSpeakerTracker.config,
                                                               progressHandler: handler)
        }
        #endif
    }
}

/// One downloaded model, loaded onto the Neural Engine.
final class LiveLoadedModel: @unchecked Sendable {
    let kind: LiveModelKind
    #if canImport(FluidAudio)
    fileprivate let parakeet: AsrManager?
    fileprivate let senseVoice: SenseVoiceManager?
    let sortformer: SortformerModels?

    private init(kind: LiveModelKind, parakeet: AsrManager? = nil,
                 senseVoice: SenseVoiceManager? = nil, sortformer: SortformerModels? = nil) {
        self.kind = kind
        self.parakeet = parakeet
        self.senseVoice = senseVoice
        self.sortformer = sortformer
    }

    static func load(_ kind: LiveModelKind) async -> LiveLoadedModel? {
        switch kind {
        case .parakeet:
            guard let folder = LiveModels.folder(.parakeet) else { return nil }
            do {
                let models = try await AsrModels.load(from: folder, version: .v3)
                let manager = AsrManager(config: .default)
                try await manager.loadModels(models)
                return LiveLoadedModel(kind: kind, parakeet: manager)
            } catch {
                JcLog.dropped(JcLog.voice, "load Parakeet", error)
                return nil
            }
        case .senseVoice:
            do { return LiveLoadedModel(kind: kind, senseVoice: try loadSenseVoiceOnCPU()) }
            catch {
                JcLog.dropped(JcLog.voice, "load SenseVoice", error)
                return nil
            }
        case .speakers:
            do {
                let models = try await SortformerModels.loadFromHuggingFace(
                    config: SortformerSpeakerTracker.config)
                return LiveLoadedModel(kind: kind, sortformer: models)
            } catch {
                JcLog.dropped(JcLog.voice, "load Sortformer", error)
                return nil
            }
        }
    }

    /// SenseVoice on the CPU, not FluidAudio's default of the Neural Engine.
    /// Measured on the Mac with his Mandarin clips: the Neural Engine build
    /// is never cached, so it took 7.3-7.6 s on EVERY load, and it was slower
    /// per line too (131-256 ms against 40-76 ms on the CPU, same words). The
    /// CPU loads in under a second and keeps working with the phone locked.
    private static func loadSenseVoiceOnCPU() throws -> SenseVoiceManager {
        guard let folder = LiveModels.folder(.senseVoice) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let cpu = MLModelConfiguration()
        cpu.computeUnits = .cpuOnly
        let preprocessor = try MLModel(
            contentsOf: folder.appendingPathComponent("SenseVoicePreprocessor.mlmodelc"),
            configuration: cpu)
        let encoder = try MLModel(
            contentsOf: folder.appendingPathComponent("SenseVoiceSmall.mlmodelc"), configuration: cpu)
        let data = try Data(contentsOf: folder.appendingPathComponent("vocab.json"))
        // FluidAudio's own loader accepts an array or an id-keyed object.
        var vocabulary: [Int: String] = [:]
        if let tokens = try JSONSerialization.jsonObject(with: data) as? [String] {
            for (id, token) in tokens.enumerated() { vocabulary[id] = token }
        } else if let byID = try JSONSerialization.jsonObject(with: data) as? [String: String] {
            for (key, token) in byID { if let id = Int(key) { vocabulary[id] = token } }
        }
        guard !vocabulary.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        return SenseVoiceManager(models: SenseVoiceModels(preprocessor: preprocessor, encoder: encoder,
                                                          vocabulary: vocabulary))
    }
    #else
    private init(kind: LiveModelKind) { self.kind = kind }
    static func load(_ kind: LiveModelKind) async -> LiveLoadedModel? { nil }
    #endif
}

/// Parakeet first, SenseVoice for what Parakeet cannot place — from whichever
/// of them are loaded.
final class OnDeviceTranscriber: OnDeviceTranscribing, @unchecked Sendable {
    #if canImport(FluidAudio)
    private let parakeet: AsrManager?
    private let senseVoice: SenseVoiceManager?

    init(_ models: [LiveLoadedModel]) {
        parakeet = models.lazy.compactMap(\.parakeet).first
        senseVoice = models.lazy.compactMap(\.senseVoice).first
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
    init(_ models: [LiveLoadedModel]) {}
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

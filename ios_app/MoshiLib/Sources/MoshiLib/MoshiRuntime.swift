import Darwin
import Foundation
import Hub
import MLX
import MLXNN

/// Moshi 1B + Mimi, loaded from the Hugging Face hub and stepped one 80 ms
/// audio frame at a time. Everything here mirrors the loading recipe in
/// Kyutai's demo app (`Moshi/ContentView.swift`); the API is narrowed to what
/// a phone UI needs: load with progress, then `step(pcm:)` in a loop.
///
/// Not thread-safe: call `load` once, then `step`/`reset` from a single worker
/// thread. `MLX` work is synchronous and heavy — never call `step` on the main
/// thread.
public final class MoshiRuntime {
    /// Mimi runs at 24 kHz and consumes/produces 1920-sample (80 ms) frames.
    public static let sampleRate: Double = 24000
    public static let frameSize = 1920

    /// Which checkpoint to run. Only the 7B "Moshi" models hold an open-ended
    /// English conversation; Hibiki 1B is Kyutai's French→English simultaneous
    /// translator (what their iPhone demo ships) and stays mostly quiet for
    /// English input.
    public enum Model: String, CaseIterable, Identifiable, Sendable {
        case moshiko, moshika, hibiki
        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .moshiko: return "Moshi 7B (male voice)"
            case .moshika: return "Moshi 7B (female voice)"
            case .hibiki: return "Hibiki 1B (French → English)"
            }
        }
        public var detail: String {
            switch self {
            case .moshiko, .moshika: return "Conversational, English. ~4.2 GB download, needs a lot of RAM; may not keep real time on a phone."
            case .hibiki: return "Simultaneous translation: speak French, hear English. ~1.3 GB."
            }
        }
        /// Hub repo + file for the LM weights.
        var weights: (repo: String, file: String) {
            switch self {
            case .moshiko: return ("kyutai/moshiko-mlx-q4", "model.q4.safetensors")
            case .moshika: return ("kyutai/moshika-mlx-q4", "model.q4.safetensors")
            case .hibiki: return ("lmz/moshi-swift", "moshi-37c6cfd6@200.q6.safetensors")
            }
        }
        public var config: LmConfig {
            switch self {
            case .moshiko, .moshika: return LmConfig.moshi_2024_07()
            case .hibiki: return LmConfig.moshi1b(audioDelay: 2)
            }
        }
        public var vocabFile: String { Files.vocabFile(for: config) }
    }

    public struct Files {
        /// Mimi codec weights and the SentencePiece vocabs live in Kyutai's Swift repo.
        public static let assetsRepo = "lmz/moshi-swift"
        public static let mimiWeights = "tokenizer-dbaa9758-checkpoint125.safetensors"

        public static func vocabFile(for cfg: LmConfig) -> String {
            switch cfg.textOutVocabSize {
            case 48000: return "tokenizer_spm_48k_multi6_2.json"
            case 32000: return "tokenizer_spm_32k_3.json"
            case 8000: return "tokenizer_spm_8k_0.json"
            case 4000: return "test_en_audio_4000.json"
            default: return "tokenizer_spm_32k_3.json"
            }
        }
    }

    public struct StepOutput {
        public var audio: [Float]
        public var text: [String]
    }

    public private(set) var isLoaded = false
    private var moshi: LM?
    private var mimi: Mimi?
    private var gen: LMGen?
    private var vocab: [Int: String] = [:]
    private var stepCount = 0

    public private(set) var model: Model?

    public init() {
        // Keep MLX's scratch cache small on a phone; the weights are what matter.
        GPU.set(cacheLimit: 32 * 1024 * 1024)
    }

    // MARK: - Loading

    /// Where hub files land (Application Support, so iOS never purges them
    /// behind our back the way it can with Caches).
    public static var downloadBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "moshi")
    }

    private static func localFile(_ repoID: String, _ filename: String) -> URL {
        HubApi(downloadBase: downloadBase).localRepoLocation(Hub.Repo(id: repoID)).appending(path: filename)
    }

    /// True when every file the model needs is already on disk.
    public static func isDownloaded(_ model: Model) -> Bool {
        let w = model.weights
        return [localFile(w.repo, w.file),
                localFile(Files.assetsRepo, Files.mimiWeights),
                localFile(Files.assetsRepo, model.vocabFile)]
            .allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Deletes every downloaded file (all models).
    public static func deleteDownloads() throws {
        if FileManager.default.fileExists(atPath: downloadBase.path) {
            try FileManager.default.removeItem(at: downloadBase)
        }
    }

    private static func download(_ repoID: String, _ filename: String,
                                 progress: @escaping @Sendable (String, Double?) -> Void) async throws -> URL {
        let api = HubApi(downloadBase: downloadBase)
        let repo = Hub.Repo(id: repoID)
        let target = api.localRepoLocation(repo).appending(path: filename)
        if FileManager.default.fileExists(atPath: target.path) { return target }
        progress("Downloading \(filename)", 0)
        let url = try await api.snapshot(from: repo, matching: filename) { p in
            progress("Downloading \(filename)", p.fractionCompleted)
        }
        return url.appending(path: filename)
    }

    /// Downloads (first run only), builds and warms up both models.
    public func load(_ which: Model, progress: @escaping @Sendable (String, Double?) -> Void) async throws {
        if isLoaded { if model == which { return } else { unload() } }
        let cfg = which.config
        let w = which.weights
        let moshiURL = try await Self.download(w.repo, w.file, progress: progress)
        let mimiURL = try await Self.download(Files.assetsRepo, Files.mimiWeights, progress: progress)
        let vocabURL = try await Self.download(Files.assetsRepo, which.vocabFile, progress: progress)

        // iOS kills a process that crosses its memory budget with no error we
        // could catch, so check the budget against the weight file up front.
        let weightBytes = (try? FileManager.default.attributesOfItem(atPath: moshiURL.path)[.size] as? Int64) ?? 0
        let mimiBytes = (try? FileManager.default.attributesOfItem(atPath: mimiURL.path)[.size] as? Int64) ?? 0
        // Weights map in lazily and land once; add headroom for activations, the
        // KV caches, MLX's scratch cache and the rest of the app.
        let needed = Int64(Double(weightBytes + mimiBytes) * 1.04) + 450_000_000
        let available = Self.availableMemoryBytes
        if available > 0, available < needed {
            throw MoshiRuntimeError.notEnoughMemory(neededMB: Int(needed / 1_000_000), availableMB: Int(available / 1_000_000))
        }
        progress("Building Moshi", nil)
        let moshi = try Self.makeMoshi(moshiURL, cfg)
        progress("Building Mimi", nil)
        let mimi = try Self.makeMimi(mimiURL, numCodebooks: 16)
        let data = try Data(contentsOf: vocabURL)
        vocab = try JSONDecoder().decode([Int: String].self, from: data)

        progress("Warming up", nil)
        mimi.warmup()
        moshi.warmup()

        self.moshi = moshi
        self.mimi = mimi
        self.gen = LMGen(moshi, maxSteps: cfg.transformer.maxSeqLen,
                         audioSampler: Sampler(), textSampler: Sampler(), cb: EmptyCallbacks())
        model = which
        isLoaded = true
        progress("Ready", nil)
    }

    /// What iOS will let this process allocate right now (0 if unknown).
    public static var availableMemoryBytes: Int64 { Int64(os_proc_available_memory()) }

    public func unload() {
        moshi = nil; mimi = nil; gen = nil
        model = nil
        isLoaded = false
        GPU.clearCache()
    }

    /// Start a fresh conversation.
    public func reset() {
        mimi?.resetState()
        gen?.reset()
        stepCount = 0
    }

    // MARK: - Stepping

    /// Feed one mic frame (`frameSize` mono samples at `sampleRate`); returns
    /// Moshi's reply audio for the same slot plus any text pieces it spoke.
    public func step(pcm: [Float]) -> StepOutput {
        guard let mimi, let gen else { return StepOutput(audio: [], text: []) }
        var out = StepOutput(audio: [], text: [])
        let x = MLXArray(pcm)[.newAxis, .newAxis]
        let codes = mimi.encodeStep(StreamArray(x))
        codes.eval()
        guard let codes = codes.asArray() else { return out }
        let (_, _, steps) = codes.shape3
        for step in 0..<steps {
            if let textToken = gen.step(otherAudioTokens: codes[0..., 0..<8, step]) {
                let id: Int = textToken[0].item()
                if let piece = Self.textPiece(id, vocab: vocab) { out.text.append(piece) }
            }
            if let audioTokens = gen.lastAudioTokens() {
                let pcmOut = mimi.decodeStep(StreamArray(audioTokens[0..., 0..., .newAxis]))
                pcmOut.eval()
                if let p = pcmOut.asArray() { out.audio += p.asArray(Float.self) }
            }
        }
        stepCount += 1
        if stepCount % 128 == 0 { GPU.clearCache() }
        return out
    }

    /// Token ids 0 (pad) and 3 (end-of-text) are silence; SentencePiece marks a
    /// word boundary with `▁`, which becomes a plain space.
    public static func textPiece(_ id: Int, vocab: [Int: String]) -> String? {
        guard id != 0, id != 3, let v = vocab[id] else { return nil }
        return v.replacingOccurrences(of: "▁", with: " ")
    }

    // MARK: - Model construction (from Kyutai's demo app)

    static func makeMoshi(_ url: URL, _ cfg: LmConfig) throws -> LM {
        let weights = try loadArrays(url: url)
        let parameters = ModuleParameters.unflattened(weights)
        let model = LM(cfg, bSize: 1)
        if url.lastPathComponent.hasSuffix(".q4.safetensors") {
            quantize(model: model, groupSize: 32, bits: 4)
        } else if url.lastPathComponent.hasSuffix(".q6.safetensors") {
            quantize(model: model, groupSize: 64, bits: 6)
        } else if url.lastPathComponent.hasSuffix(".q8.safetensors") {
            quantize(model: model, groupSize: 64, bits: 8)
        }
        try model.update(parameters: parameters, verify: [.all])
        eval(model)
        return model
    }

    static func makeMimi(_ url: URL, numCodebooks: Int) throws -> Mimi {
        let cfg = MimiConfig.mimi_2024_07(numCodebooks: numCodebooks)
        let model = Mimi(cfg, bSize: 1)
        let origWeights = try loadArrays(url: url)
        var weights: [String: MLXArray] = [:]
        for (var key, var weight) in origWeights {
            if key.hasPrefix("encoder.model") { key.replace("encoder.model.", with: "encoder.") }
            if key.hasPrefix("decoder.model") { key.replace("decoder.model.", with: "decoder.") }
            if key.hasSuffix(".in_proj_weight") { key.replace(".in_proj_weight", with: ".in_proj.weight") }
            if key.hasSuffix(".linear1.weight") { key.replace(".linear1.weight", with: ".gating.linear1.weight") }
            if key.hasSuffix(".linear2.weight") { key.replace(".linear2.weight", with: ".gating.linear2.weight") }
            for (layerIdx, decoderIdx) in [2, 5, 8, 11].enumerated() {
                key.replace("decoder.\(decoderIdx).", with: "decoder.layers.\(layerIdx).upsample.")
                key.replace("decoder.\(decoderIdx + 1).", with: "decoder.layers.\(layerIdx).residuals.0.")
            }
            for (layerIdx, encoderIdx) in [1, 4, 7, 10].enumerated() {
                key.replace("encoder.\(encoderIdx).", with: "encoder.layers.\(layerIdx).residuals.0.")
                key.replace("encoder.\(encoderIdx + 2).", with: "encoder.layers.\(layerIdx).downsample.")
            }
            key.replace("decoder.0.", with: "decoder.init_conv1d.")
            key.replace("decoder.14.", with: "decoder.final_conv1d.")
            key.replace("encoder.0.", with: "encoder.init_conv1d.")
            key.replace("encoder.14.", with: "encoder.final_conv1d.")
            key.replace(".block.1.", with: ".block.0.")
            key.replace(".block.3.", with: ".block.1.")
            // PyTorch conv weights are (outC, inC, k); MLX wants (outC, k, inC).
            if key.hasSuffix(".conv.weight") || key.hasSuffix(".output_proj.weight")
                || key.hasSuffix(".input_proj.weight") {
                weight = weight.swappedAxes(-1, -2)
            }
            // Transposed convs are (inC, outC, k) in PyTorch; MLX wants (outC, k, inC).
            if key.hasSuffix(".convtr.weight") { weight = weight.transposed(axes: [1, 2, 0]) }
            weights[key] = weight
        }
        let parameters = ModuleParameters.unflattened(weights)
        try model.update(parameters: parameters, verify: [.all])
        return model
    }
}

public enum MoshiRuntimeError: LocalizedError {
    case notEnoughMemory(neededMB: Int, availableMB: Int)
    public var errorDescription: String? {
        switch self {
        case .notEnoughMemory(let needed, let available):
            return "Not enough memory to load this model: it needs about \(needed) MB and iOS allows this app \(available) MB right now. The app must be signed with the Increased Memory Limit capability (Xcode → Signing & Capabilities) to load it, or pick a smaller model."
        }
    }
}

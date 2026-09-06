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

    public struct Files {
        public static let hubRepo = "lmz/moshi-swift"
        public static let moshiWeights = "moshi-37c6cfd6@200.q6.safetensors"
        public static let mimiWeights = "tokenizer-dbaa9758-checkpoint125.safetensors"
        /// SentencePiece vocab, picked by the text vocab size of the config.
        public static let vocab = vocabFile(for: LmConfig.moshi1b(audioDelay: 2))

        public static func vocabFile(for cfg: LmConfig) -> String {
            switch cfg.textOutVocabSize {
            case 48000: return "tokenizer_spm_48k_multi6_2.json"
            case 32000: return "tokenizer_spm_32k_3.json"
            case 8000: return "tokenizer_spm_8k_0.json"
            case 4000: return "test_en_audio_4000.json"
            default: return "tokenizer_spm_48k_multi6_2.json"
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

    public init() {}

    // MARK: - Loading

    /// Where hub files land (Application Support, so iOS never purges them
    /// behind our back the way it can with Caches).
    public static var downloadBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "moshi")
    }

    /// True when every weight file is already on disk.
    public static func isDownloaded() -> Bool {
        let api = HubApi(downloadBase: downloadBase)
        let repo = Hub.Repo(id: Files.hubRepo)
        return [Files.moshiWeights, Files.mimiWeights, Files.vocab].allSatisfy {
            FileManager.default.fileExists(atPath: api.localRepoLocation(repo).appending(path: $0).path)
        }
    }

    /// Deletes the downloaded weights.
    public static func deleteDownloads() throws {
        let api = HubApi(downloadBase: downloadBase)
        let dir = api.localRepoLocation(Hub.Repo(id: Files.hubRepo))
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    private static func download(_ filename: String,
                                 progress: @escaping @Sendable (String, Double?) -> Void) async throws -> URL {
        let api = HubApi(downloadBase: downloadBase)
        let repo = Hub.Repo(id: Files.hubRepo)
        let target = api.localRepoLocation(repo).appending(path: filename)
        if FileManager.default.fileExists(atPath: target.path) { return target }
        progress("Downloading \(filename)", 0)
        let url = try await api.snapshot(from: repo, matching: filename) { p in
            progress("Downloading \(filename)", p.fractionCompleted)
        }
        return url.appending(path: filename)
    }

    /// Downloads (first run only), builds and warms up both models.
    public func load(progress: @escaping @Sendable (String, Double?) -> Void) async throws {
        guard !isLoaded else { return }
        let cfg = LmConfig.moshi1b(audioDelay: 2)
        let moshiURL = try await Self.download(Files.moshiWeights, progress: progress)
        let mimiURL = try await Self.download(Files.mimiWeights, progress: progress)
        let vocabURL = try await Self.download(Files.vocab, progress: progress)

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
        isLoaded = true
        progress("Ready", nil)
    }

    public func unload() {
        moshi = nil; mimi = nil; gen = nil
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

import Foundation
import Hub
import MLX
import MLXLLM
import MLXLMCommon

/// A downloadable chat model (e.g. `mlx-community/Qwen2.5-1.5B-Instruct-4bit`)
/// running on the phone's GPU through MLX.
///
/// Storage: weights live under Application Support/OnDeviceModels in the Hub
/// layout (`models/<org>/<repo>/`), the single source of truth for download,
/// install checks, sizing and delete — the same layout the Flutter app's
/// ModelManager used, so nothing is re-downloaded on upgrade.
///
/// One model is resident at a time; `load` of a different id unloads the first.
public actor LocalLLM {
    public static let shared = LocalLLM()

    public private(set) var loadedModelID: String?
    private var container: ModelContainer?

    public init() {
        GPU.set(cacheLimit: 32 * 1024 * 1024)
    }

    // MARK: - Storage

    public static var modelsRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appending(path: "OnDeviceModels")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var hub: HubApi { HubApi(downloadBase: modelsRoot) }

    /// `<root>/models/<org>/<repo>` — where HubApi puts a repo snapshot.
    public static func directory(for modelID: String) -> URL {
        hub.localRepoLocation(Hub.Repo(id: modelID))
    }

    /// Installed once the snapshot holds weights (a half-finished download has
    /// config JSON but no safetensors yet).
    public static func isInstalled(_ modelID: String) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory(for: modelID).path)
        else { return false }
        return names.contains { $0.hasSuffix(".safetensors") }
    }

    public static func installedSizeBytes(_ modelID: String) -> Int64 {
        guard let en = FileManager.default.enumerator(at: directory(for: modelID),
                                                      includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in en {
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += Int64(v?.fileSize ?? 0) }
        }
        return total
    }

    public static func delete(_ modelID: String) throws {
        let dir = directory(for: modelID)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: - Download / load

    /// Fetch the weights, config and tokenizer files (`*.safetensors`, `*.json`)
    /// without loading them. Progress is 0…1.
    public func download(_ modelID: String,
                         progress: @escaping @Sendable (Double) -> Void) async throws {
        let config = LLMModelFactory.shared.configuration(id: modelID)
        _ = try await downloadModel(hub: Self.hub, configuration: config) { p in
            progress(p.fractionCompleted)
        }
        try Task.checkCancellation()
        progress(1)
    }

    /// Download if needed, then build the model on the GPU. Idempotent per id.
    public func load(_ modelID: String,
                     progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        if loadedModelID == modelID, container != nil { return }
        unload()
        let config = LLMModelFactory.shared.configuration(id: modelID)
        let container = try await LLMModelFactory.shared.loadContainer(hub: Self.hub, configuration: config) { p in
            progress(p.fractionCompleted)
        }
        self.container = container
        loadedModelID = modelID
    }

    public func unload() {
        container = nil
        loadedModelID = nil
        GPU.clearCache()
    }

    // MARK: - Generate

    public struct Parameters: Sendable {
        public var temperature: Float
        public var maxTokens: Int
        public init(temperature: Float = 0.6, maxTokens: Int = 700) {
            self.temperature = temperature
            self.maxTokens = maxTokens
        }
    }

    private let stop = Flag()

    /// Chat completion through the model's own chat template. `onToken` gets
    /// each new text delta; the full reply is returned.
    public func generate(system: String, prompt: String,
                         parameters: Parameters = Parameters(),
                         onToken: @escaping @Sendable (String) -> Void) async throws -> String {
        guard let container else { throw LocalLLMError.notLoaded }
        stop.value = false
        var messages: [[String: String]] = []
        if !system.isEmpty { messages.append(["role": "system", "content": system]) }
        messages.append(["role": "user", "content": prompt])
        let input = UserInput(messages: messages)
        let params = GenerateParameters(temperature: parameters.temperature)
        let maxTokens = parameters.maxTokens
        let stop = self.stop
        let result = try await container.perform { context in
            let lmInput = try await context.processor.prepare(input: input)
            var emitted = ""
            let result = try MLXLMCommon.generate(input: lmInput, parameters: params, context: context) { tokens in
                if stop.value || tokens.count >= maxTokens { return .stop }
                // Decode every few tokens and emit only the new suffix, so the
                // caller gets deltas and multi-byte pieces resolve before display.
                if tokens.count % 3 == 0 {
                    let full = context.tokenizer.decode(tokens: tokens)
                    if full.count > emitted.count, full.hasPrefix(emitted) {
                        onToken(String(full.dropFirst(emitted.count)))
                        emitted = full
                    }
                }
                return .more
            }
            // Flush what the last partial decode left out.
            let full = result.output
            if full.count > emitted.count, full.hasPrefix(emitted) {
                onToken(String(full.dropFirst(emitted.count)))
            }
            return result
        }
        return result.output
    }

    /// Stop the in-flight `generate` at its next token. Idempotent.
    public nonisolated func cancel() { stop.value = true }
}

/// Lock-free stop flag readable from the generation callback.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

public enum LocalLLMError: LocalizedError {
    case notLoaded
    public var errorDescription: String? {
        switch self {
        case .notLoaded: return "No on-device model is loaded."
        }
    }
}

import Foundation
import OnDeviceLLM

/// The MLX engine — backs the downloadable `mlx-community/*` models via the
/// `OnDeviceLLM` package (Apple's mlx-swift LLM library). Availability means
/// "the selected model's weights are on disk"; `load` builds it on the GPU.
actor MLXEngine: OnDeviceInferenceEngine {
    static let shared = MLXEngine()

    nonisolated var id: String { OnDeviceEngineKind.mlx.rawValue }

    private let llm: LocalLLM
    /// The model this engine is meant to serve — set by `load`, falling back to
    /// whatever the settings point at so availability answers before warm-up.
    private var modelID: String?

    init(llm: LocalLLM = .shared) { self.llm = llm }

    /// `LocalAiSettings` is main-actor state; hop there for the fallback read.
    private func targetModelID() async -> String {
        if let modelID { return modelID }
        return await MainActor.run { LocalAiSettings.shared.activeLocalModelID }
    }

    func availability() async -> OnDeviceEngineAvailability {
        let id = await targetModelID()
        guard OnDeviceModelCatalog.engine(for: id) == .mlx else { return .unavailable("not-an-mlx-model") }
        return LocalLLM.isInstalled(id) ? .available : .unavailable("model-not-downloaded")
    }

    func load(modelID: String) async throws {
        self.modelID = modelID
        guard LocalLLM.isInstalled(modelID) else { throw OnDeviceEngineError("model-not-downloaded") }
        try await llm.load(modelID)
    }

    func generate(_ request: OnDeviceGenRequest,
                  onToken: @escaping @Sendable (String) -> Void) async throws -> String {
        let id = await targetModelID()
        if await llm.loadedModelID != id { try await load(modelID: id) }
        return try await llm.generate(system: request.system, prompt: request.prompt, onToken: onToken)
    }

    func cancel() async { llm.cancel() }

    func unload() async { await llm.unload() }
}

/// Picks the engine for whichever local model is selected in settings, so the
/// router, the chat bridge and the settings screen never need to know which
/// stack is behind `activeLocalModelID`.
final class OnDeviceRoutingEngine: OnDeviceInferenceEngine, @unchecked Sendable {
    let settings: LocalAiSettings
    let appleFM: any OnDeviceInferenceEngine
    let mlx: any OnDeviceInferenceEngine
    /// Last kind seen on an async call, for the synchronous `id` off the main thread.
    private let lastKind = KindBox()

    init(settings: LocalAiSettings,
         appleFM: any OnDeviceInferenceEngine = AppleFMEngine.shared,
         mlx: any OnDeviceInferenceEngine = MLXEngine.shared) {
        self.settings = settings
        self.appleFM = appleFM
        self.mlx = mlx
    }

    /// `LocalAiSettings` is main-actor state, so the routing decision hops there.
    private func activeKind() async -> OnDeviceEngineKind {
        let kind = await MainActor.run { OnDeviceModelCatalog.engine(for: settings.activeLocalModelID) }
        lastKind.value = kind
        return kind
    }

    private func engine(for kind: OnDeviceEngineKind) -> any OnDeviceInferenceEngine {
        kind == .mlx ? mlx : appleFM
    }

    nonisolated var id: String {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { OnDeviceModelCatalog.engine(for: settings.activeLocalModelID) }.rawValue
        }
        return lastKind.value.rawValue
    }

    func availability() async -> OnDeviceEngineAvailability {
        await engine(for: await activeKind()).availability()
    }

    func load(modelID: String) async throws {
        let kind = OnDeviceModelCatalog.engine(for: modelID)
        lastKind.value = kind
        try await engine(for: kind).load(modelID: modelID)
    }

    func generate(_ request: OnDeviceGenRequest,
                  onToken: @escaping @Sendable (String) -> Void) async throws -> String {
        try await engine(for: await activeKind()).generate(request, onToken: onToken)
    }

    func cancel() async {
        await appleFM.cancel()
        await mlx.cancel()
    }
}

private final class KindBox: @unchecked Sendable {
    private let lock = NSLock()
    private var kind: OnDeviceEngineKind = .appleFM
    var value: OnDeviceEngineKind {
        get { lock.lock(); defer { lock.unlock() }; return kind }
        set { lock.lock(); kind = newValue; lock.unlock() }
    }
}

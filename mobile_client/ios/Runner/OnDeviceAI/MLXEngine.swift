import Foundation

// MARK: - MLX-Swift engine (temporarily disabled)
//
// `mlx-swift-lm` (main) underwent a breaking API rewrite: model loading is now
// macro-based (`#huggingFaceLoadModelContainer` in the `MLXHuggingFace` module,
// backed by `swift-huggingface`'s `HubClient`), and the old `Hub` module became
// `HuggingFace`. Rather than chase that churning API blind, this engine is
// stubbed to report "unavailable" so the build stays green and the Apple
// Foundation Models path + routing + on-device STT + the model picker all work.
//
// To re-enable downloadable MLX models later:
//   1. Add the `MLXHuggingFace` product to the Runner target.
//   2. Restore `load` to use:
//        try await huggingFaceLoadModelContainer(configuration:
//            ModelConfiguration(id: modelId)) { progress in ... }   // import MLXHuggingFace
//   3. Re-point `ModelManager` downloads at `HubClient` (HuggingFace module).
//   4. Confirm `MLXLMCommon.generate(input:parameters:context:)` + the `.chunk`
//      case still match (they may have shifted in the rewrite too).
// The mlx-swift / mlx-swift-lm packages can stay added in the meantime.

final class MLXEngine: OnDeviceEngine {
    let id = "mlx"

    func availability() -> EngineAvailability {
        .unavailable("mlx-engine-disabled")
    }

    func load(modelId: String) async throws { throw Self.disabled() }

    func generate(_ req: GenRequest, onToken: @escaping (String) -> Void) async throws -> String {
        throw Self.disabled()
    }

    func route(system: String, prompt: String, schemaJSON: String) async throws -> [String: Any] {
        throw Self.disabled()
    }

    /// Release any loaded model. No-op while disabled.
    func unload() {}

    func cancel() {}

    private static func disabled() -> NSError {
        NSError(
            domain: "OnDeviceAI",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey:
                "MLX engine is temporarily disabled (mlx-swift-lm API migration pending). Use Apple Foundation Models."]
        )
    }
}

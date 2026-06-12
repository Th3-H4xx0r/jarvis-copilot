import Foundation

/// Shared abstraction over an on-device LLM engine.
///
/// Two concrete engines implement this:
///   • `AppleFMEngine` — Apple's on-device FoundationModels (iOS 26+).
///   • `MLXEngine`     — quantized HF models run via MLX-Swift on the GPU.
///
/// `OnDeviceAIPlugin` picks the active engine based on the model the Dart
/// side has loaded (`apple-fm` → Apple FM, anything else → MLX) and routes
/// every MethodChannel call into the protocol below.
///
/// All three call sites (`generate`, `route`, `cancel`) are designed so the
/// plugin can drive them from a single background `Task` and hop results
/// back to the main thread before touching Flutter's `result`/`eventSink`.

/// Whether an engine can run right now, with a human-readable reason when not.
///
/// The `String` payload on `.unavailable` is surfaced verbatim to Dart as
/// the `reason` field of `availability()`, so keep it short and explanatory
/// (e.g. "deviceNotEligible", "mlx-not-built").
enum EngineAvailability {
    case available
    case unavailable(String)
}

/// One generation request. `requestId` is the Dart-supplied correlation id
/// echoed back on every EventChannel event so the Dart side can match a
/// stream of tokens to the call that started it.
struct GenRequest {
    let system: String
    let prompt: String
    let requestId: String
}

/// The contract every on-device engine fulfils.
///
/// Implementations must be safe to call from a background task. `generate`
/// invokes `onToken` once per *incremental* delta (never a cumulative
/// snapshot) so the plugin can forward each piece straight to Flutter, and
/// returns the full concatenated text when the stream completes. `cancel`
/// must be cheap and idempotent — it may be called for a request that has
/// already finished.
protocol OnDeviceEngine {
    /// Stable engine identifier, mirrored into the Dart model list's
    /// `engine` field (`"apple-fm"` or `"mlx"`).
    var id: String { get }

    /// Whether this engine can run on the current device/OS right now.
    func availability() -> EngineAvailability

    /// Prepare the engine to serve `modelId`. For Apple FM this is a cheap
    /// session warm-up; for MLX it loads (and, if needed, materializes) the
    /// `ModelContainer` for the given Hugging Face repo id.
    func load(modelId: String) async throws

    /// Stream a free-form completion. `onToken` is called with each new
    /// delta; the full text is returned on completion. Throws on failure or
    /// cancellation.
    func generate(_ req: GenRequest, onToken: @escaping (String) -> Void) async throws -> String

    /// Produce a structured routing decision. `schemaJSON` is the JSON-schema
    /// description of the expected shape (advisory for prompt-based engines,
    /// satisfied natively by Apple FM's guided generation). Returns a plain
    /// `[String: Any]` matching the Dart `RoutingDecision` contract:
    ///   action, answer?, toolName?, toolArgs{}, confidence, reason?
    func route(system: String, prompt: String, schemaJSON: String) async throws -> [String: Any]

    /// Cancel the in-flight `generate`/`route`, if any. Idempotent.
    func cancel()
}

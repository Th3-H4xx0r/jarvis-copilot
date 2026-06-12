import Foundation

#if canImport(MLXLLM)
import MLXLLM
import MLXLMCommon
#endif

// MARK: - MLX-Swift engine
//
// Backs the `mlx` models — quantized HF repos (Qwen2.5-1.5B, Llama-3.2-1B …)
// run on the Apple GPU via MLX-Swift. Weights are downloaded by
// `ModelManager` and materialized into a `ModelContainer` on `load`.
//
// The concrete path is gated on `#if canImport(MLXLLM)` so the file compiles
// before the `mlx-swift` / `mlx-swift-examples` packages are added. Without
// them the engine reports `mlx-not-built` and every method throws clearly.

final class MLXEngine: OnDeviceEngine {
    let id = "mlx"

    /// Repo id this engine is currently bound to (for diagnostics).
    private var loadedModelId: String?

    /// Cooperative cancellation flag, flipped by `cancel()` and checked inside
    /// the token loop. We deliberately avoid relying solely on Task
    /// cancellation because the MLX generate loop is a tight synchronous-ish
    /// callback.
    private var cancelled = false

    #if canImport(MLXLLM)

    /// The loaded model + tokenizer. `ModelContainer` serializes access to the
    /// underlying MLX state, so all inference runs through `perform`.
    private var container: ModelContainer?

    // MARK: Availability

    func availability() -> EngineAvailability {
        // The package is built in; availability then hinges only on a model
        // being loaded, which the plugin enforces by calling `load` first.
        return .available
    }

    // MARK: Load

    func load(modelId: String) async throws {
        cancelled = false
        // `ModelManager` downloads weights into Application Support and points
        // MLX's hub at that directory, so this resolves locally when present
        // and only hits the network if missing.
        let config = ModelConfiguration(id: modelId)
        let container = try await LLMModelFactory.shared.loadContainer(
            configuration: config
        ) { _ in
            // Progress here is the *load* progress; download progress is
            // reported separately by ModelManager. We ignore it.
        }
        self.container = container
        self.loadedModelId = modelId
    }

    // MARK: Generate (streaming)

    func generate(_ req: GenRequest, onToken: @escaping (String) -> Void) async throws -> String {
        guard let container = container else {
            throw Self.notLoaded()
        }
        cancelled = false

        let prompt = Self.composePrompt(system: req.system, user: req.prompt)

        // MLXLMCommon yields cumulative `Generation` chunks; we diff to deltas
        // to satisfy the plugin's token-by-token EventChannel contract.
        let full: String = try await container.perform { context in
            let input = try await context.processor.prepare(
                input: .init(prompt: prompt))

            var emitted = ""
            let stream = try MLXLMCommon.generate(
                input: input,
                parameters: GenerateParameters(temperature: 0.6),
                context: context
            )
            for await item in stream {
                if self.cancelled { break }
                if case .chunk(let text) = item {
                    // `.chunk` is already an incremental piece in current
                    // MLXLMCommon, but guard against cumulative just in case.
                    if text.hasPrefix(emitted), text.count > emitted.count {
                        let delta = String(text.dropFirst(emitted.count))
                        onToken(delta)
                        emitted = text
                    } else {
                        onToken(text)
                        emitted += text
                    }
                }
            }
            return emitted
        }

        if cancelled {
            throw CancellationError()
        }
        return full
    }

    // MARK: Route (strict-JSON prompt + one retry)

    func route(system: String, prompt: String, schemaJSON: String) async throws -> [String: Any] {
        // First attempt: JSON-only instruction.
        let firstPrompt = Self.routePrompt(system: system, user: prompt, schemaJSON: schemaJSON, retry: false)
        if let dict = try await runJSON(firstPrompt) {
            return dict
        }
        // Retry once with a firmer reminder.
        let retryPrompt = Self.routePrompt(system: system, user: prompt, schemaJSON: schemaJSON, retry: true)
        if let dict = try await runJSON(retryPrompt) {
            return dict
        }
        // Give up → escalate to the cloud model.
        return ["action": "escalate", "confidence": 0.0, "toolArgs": [:], "reason": "parse"]
    }

    /// Run a non-streaming completion and parse the first JSON object out of it.
    private func runJSON(_ prompt: String) async throws -> [String: Any]? {
        guard let container = container else { throw Self.notLoaded() }
        cancelled = false

        let text: String = try await container.perform { context in
            let input = try await context.processor.prepare(input: .init(prompt: prompt))
            var out = ""
            let stream = try MLXLMCommon.generate(
                input: input,
                parameters: GenerateParameters(temperature: 0.0),
                context: context
            )
            for await item in stream {
                if self.cancelled { break }
                if case .chunk(let t) = item { out += t }
            }
            return out
        }
        return Self.normalizeRouting(Self.extractJSONObject(from: text))
    }

    #else

    // MARK: - Fallback (MLXLLM not built)

    func availability() -> EngineAvailability {
        .unavailable("mlx-not-built")
    }

    func load(modelId: String) async throws { throw Self.notBuilt() }

    func generate(_ req: GenRequest, onToken: @escaping (String) -> Void) async throws -> String {
        throw Self.notBuilt()
    }

    func route(system: String, prompt: String, schemaJSON: String) async throws -> [String: Any] {
        throw Self.notBuilt()
    }

    private static func notBuilt() -> NSError {
        NSError(domain: "MLXEngine", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "MLX is not built into this app"])
    }

    #endif

    // MARK: Cancel

    func cancel() {
        cancelled = true
    }

    // MARK: - Shared helpers (available in both build configs)

    private static func notLoaded() -> NSError {
        NSError(domain: "MLXEngine", code: -3,
                userInfo: [NSLocalizedDescriptionKey: "No MLX model loaded"])
    }

    /// Minimal chat framing. The model containers ship their own chat template
    /// via the tokenizer, but a plain system/user concatenation is a safe
    /// fallback that all instruct models understand.
    private static func composePrompt(system: String, user: String) -> String {
        if system.isEmpty { return user }
        return "\(system)\n\n\(user)"
    }

    /// Build the strict-JSON routing prompt. On retry we prepend a blunt
    /// "valid JSON only" reminder.
    private static func routePrompt(system: String, user: String, schemaJSON: String, retry: Bool) -> String {
        var lines: [String] = []
        if !system.isEmpty { lines.append(system) }
        lines.append("""
        You are a routing classifier. Decide whether to answer directly, call a tool, or escalate.
        Respond with ONLY a single JSON object and nothing else — no prose, no markdown fences.
        The JSON MUST match this shape:
        {
          "action": "answer" | "tool" | "escalate",
          "answer": string | null,
          "toolName": string | null,
          "toolArgs": object,
          "confidence": number between 0 and 1,
          "reason": string | null
        }
        Schema: \(schemaJSON)
        """)
        if retry {
            lines.append("Your previous reply was not valid JSON. Output VALID JSON ONLY this time. Start your reply with '{'.")
        }
        lines.append("User request:\n\(user)")
        lines.append("JSON:")
        return lines.joined(separator: "\n\n")
    }

    /// Pull the first balanced `{...}` object out of free-form model text
    /// (handles leading prose or ```json fences) and parse it.
    static func extractJSONObject(from text: String) -> [String: Any]? {
        let chars = Array(text)
        guard let start = chars.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var end: Int? = nil
        var i = start
        while i < chars.count {
            let c = chars[i]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else {
                if c == "\"" { inString = true }
                else if c == "{" { depth += 1 }
                else if c == "}" {
                    depth -= 1
                    if depth == 0 { end = i; break }
                }
            }
            i += 1
        }
        guard let end = end else { return nil }
        let jsonSlice = String(chars[start...end])
        guard let data = jsonSlice.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    /// Validate/normalize a parsed routing dict so the Dart side always gets a
    /// well-formed RoutingDecision. Returns nil if `action` is missing/invalid
    /// so callers can trigger the retry path.
    static func normalizeRouting(_ dict: [String: Any]?) -> [String: Any]? {
        guard let dict = dict,
              let action = dict["action"] as? String,
              ["answer", "tool", "escalate"].contains(action)
        else { return nil }

        var out: [String: Any] = ["action": action]
        out["confidence"] = (dict["confidence"] as? Double)
            ?? (dict["confidence"] as? NSNumber)?.doubleValue
            ?? 0.5
        if let answer = dict["answer"] as? String { out["answer"] = answer }
        if let toolName = dict["toolName"] as? String { out["toolName"] = toolName }
        if let reason = dict["reason"] as? String { out["reason"] = reason }
        out["toolArgs"] = (dict["toolArgs"] as? [String: Any]) ?? [:]
        return out
    }
}

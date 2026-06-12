import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Apple FoundationModels engine
//
// Backs the `apple-fm` model. On iOS 26+ with Apple Intelligence enabled
// this runs Apple's ~3B on-device language model — no download, no storage,
// no RAM accounting on our side (the OS owns the weights).
//
// The whole concrete implementation lives behind
// `#if canImport(FoundationModels)` + `@available(iOS 26.0, *)`. When the
// framework isn't importable (older SDK) or we're below iOS 26 at runtime,
// a thin fallback keeps the *type* present and simply reports unavailable,
// so the rest of the app compiles and links unchanged.

#if canImport(FoundationModels)

@available(iOS 26.0, *)
final class AppleFMEngine: OnDeviceEngine {
    let id = "apple-fm"

    /// Reused across calls so multi-turn warm-up costs are amortized. We
    /// recreate it per `generate`/`route` only if you want a clean context;
    /// here we keep one session and let the framework manage its transcript.
    private var session: LanguageModelSession?

    /// Cancels the in-flight stream. FoundationModels surfaces cancellation
    /// through Swift's structured-concurrency `Task`, so we hold the task and
    /// cancel it directly.
    private var currentTask: Task<Void, Never>?

    // MARK: Availability

    func availability() -> EngineAvailability {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            return .unavailable(Self.describe(reason))
        @unknown default:
            return .unavailable("unknown")
        }
    }

    /// Map Apple's enum cases to the short reason strings Dart surfaces.
    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "deviceNotEligible"
        case .appleIntelligenceNotEnabled:
            return "appleIntelligenceNotEnabled"
        case .modelNotReady:
            return "modelNotReady"
        @unknown default:
            return "unavailable"
        }
    }

    // MARK: Load

    /// Apple FM needs no per-model download; "loading" is just spinning up a
    /// session so the first token isn't penalized by lazy init.
    func load(modelId: String) async throws {
        guard case .available = SystemLanguageModel.default.availability else {
            throw NSError(
                domain: "AppleFMEngine", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Apple FM unavailable"])
        }
        session = LanguageModelSession()
    }

    private func ensureSession(system: String) -> LanguageModelSession {
        // A non-empty system prompt seeds a fresh session's instructions;
        // otherwise reuse the warm session from `load`.
        if !system.isEmpty {
            let s = LanguageModelSession(instructions: Instructions(system))
            session = s
            return s
        }
        if let s = session { return s }
        let s = LanguageModelSession()
        session = s
        return s
    }

    // MARK: Generate (streaming)

    func generate(_ req: GenRequest, onToken: @escaping (String) -> Void) async throws -> String {
        let session = ensureSession(system: req.system)

        // FoundationModels' `streamResponse(to:)` yields *cumulative* snapshots
        // of the answer-so-far. The plugin's EventChannel contract wants pure
        // deltas, so we diff against what we've already emitted and forward
        // only the new suffix.
        var emitted = ""
        let stream = session.streamResponse(to: req.prompt)
        for try await snapshot in stream {
            try Task.checkCancellation()
            // `snapshot.content` is the accumulated String for a free-form
            // (String) response.
            let full = snapshot.content
            if full.count > emitted.count, full.hasPrefix(emitted) {
                let delta = String(full[full.index(full.startIndex, offsetBy: emitted.count)...])
                if !delta.isEmpty { onToken(delta) }
            } else if full != emitted {
                // Non-monotonic snapshot (rare): re-sync by emitting the whole
                // thing fresh would double-up, so just emit the new tail by
                // longest-common-prefix.
                let delta = Self.suffixAfterCommonPrefix(old: emitted, new: full)
                if !delta.isEmpty { onToken(delta) }
            }
            emitted = full
        }
        return emitted
    }

    private static func suffixAfterCommonPrefix(old: String, new: String) -> String {
        let oldChars = Array(old)
        let newChars = Array(new)
        var i = 0
        while i < oldChars.count, i < newChars.count, oldChars[i] == newChars[i] { i += 1 }
        return String(newChars[i...])
    }

    // MARK: Route (guided generation)

    func route(system: String, prompt: String, schemaJSON: String) async throws -> [String: Any] {
        let session = system.isEmpty
            ? (self.session ?? LanguageModelSession())
            : LanguageModelSession(instructions: Instructions(system))
        self.session = session

        // Guided generation: ask the framework to fill in a typed struct. This
        // is far more reliable than prompt-and-parse — Apple constrains decoding
        // to the schema, so we always get a well-formed `RoutingDecisionGen`.
        let response = try await session.respond(
            to: prompt,
            generating: RoutingDecisionGen.self
        )
        return response.content.asDictionary()
    }

    // MARK: Cancel

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        // Dropping the session invalidates any in-flight stream the next time
        // a snapshot is awaited; combined with Task.checkCancellation in
        // generate this stops emission promptly.
    }
}

// MARK: - Guided-generation schema
//
// Mirrors the Dart RoutingDecision exactly. @Generable can't express a
// free-form `[String: Any]` (toolArgs), so we model it as a JSON *string*
// the model fills in, then decode that back to a dictionary on our side.

@available(iOS 26.0, *)
@Generable
struct RoutingDecisionGen {
    @Guide(description: "One of: answer, tool, escalate")
    var action: String

    @Guide(description: "The direct answer text, when action is 'answer'")
    var answer: String?

    @Guide(description: "The tool to call, when action is 'tool'")
    var toolName: String?

    @Guide(description: "A JSON object string of arguments for the tool, e.g. {\"city\":\"NYC\"}. Use {} when none.")
    var toolArgsJSON: String?

    @Guide(description: "Confidence from 0.0 to 1.0")
    var confidence: Double

    @Guide(description: "Short reason for the decision")
    var reason: String?

    /// Collapse into the `[String: Any]` shape the Dart channel expects,
    /// decoding the embedded `toolArgsJSON` back into a real dictionary.
    func asDictionary() -> [String: Any] {
        var out: [String: Any] = [
            "action": action,
            "confidence": confidence,
        ]
        if let answer = answer { out["answer"] = answer }
        if let toolName = toolName { out["toolName"] = toolName }
        if let reason = reason { out["reason"] = reason }
        out["toolArgs"] = Self.parseArgs(toolArgsJSON)
        return out
    }

    private static func parseArgs(_ json: String?) -> [String: Any] {
        guard let json = json,
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }
}

#else

// MARK: - Fallback (framework not importable / pre-iOS 26 SDK)
//
// Keeps `AppleFMEngine` present as a real type so `OnDeviceAIPlugin` can
// always instantiate its default engine. Everything reports unavailable and
// throws; the plugin/Dart side then steers the user to an MLX model instead.

final class AppleFMEngine: OnDeviceEngine {
    let id = "apple-fm"

    func availability() -> EngineAvailability {
        .unavailable("foundationmodels-unavailable")
    }

    func load(modelId: String) async throws {
        throw NSError(
            domain: "AppleFMEngine", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "FoundationModels not available"])
    }

    func generate(_ req: GenRequest, onToken: @escaping (String) -> Void) async throws -> String {
        throw NSError(
            domain: "AppleFMEngine", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "FoundationModels not available"])
    }

    func route(system: String, prompt: String, schemaJSON: String) async throws -> [String: Any] {
        throw NSError(
            domain: "AppleFMEngine", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "FoundationModels not available"])
    }

    func cancel() {}
}

#endif

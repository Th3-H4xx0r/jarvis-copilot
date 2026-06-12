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
// IMPORTANT — availability shape:
//   The concrete `AppleFMEngine` TYPE is deliberately NOT `@available`-gated.
//   `OnDeviceAIPlugin` instantiates it unconditionally (`AppleFMEngine()`) and
//   calls `.cancel()` on any iOS version, so the type must exist and be
//   constructible everywhere. Every actual FoundationModels API call lives
//   behind an `if #available(iOS 26.0, *)` / `guard #available` checkpoint
//   *inside* a method body, and all FoundationModels *types* are referenced
//   only from `@available(iOS 26.0, *)` helpers that the engine reaches via a
//   runtime check. On iOS < 26 (or when the framework isn't importable at all)
//   the engine simply reports `.unavailable(...)` and throws.

final class AppleFMEngine: OnDeviceEngine {
    let id = "apple-fm"

    #if canImport(FoundationModels)

    /// Holds the FoundationModels session. This is an `Any` box so the
    /// `AppleFMEngine` type itself carries no `@available`-restricted stored
    /// property; the concrete `LanguageModelSession` only ever appears inside
    /// `@available(iOS 26.0, *)` code (`FMSession`), which we down-cast to.
    private var sessionBox: AnyObject?

    // Cache availability()+prewarm so the router's per-turn check doesn't re-run
    // FMSession.availability() and prewarm() on every call (wasted ANE/CPU when
    // turns are back-to-back). Short TTL so a real availability change is still
    // picked up within a few seconds.
    private var cachedAvail: EngineAvailability?
    private var lastAvailCheck = Date.distantPast
    private static let availCacheTTL: TimeInterval = 5.0

    // Cancellation note: `generate`/`route` are `async` and awaited by the
    // plugin's single `inferenceTask`. When the plugin cancels that task (or
    // calls `cancel()`), cancellation propagates cooperatively into the
    // `Task.checkCancellation()` checkpoints inside `FMSession.generate`/
    // `route`, and `cancel()` also invalidates the session below. We therefore
    // don't hold a separate engine-owned `Task` to cancel (that field was dead
    // code — never assigned — in the prior version).

    // MARK: Availability

    func availability() -> EngineAvailability {
        guard #available(iOS 26.0, *) else {
            return .unavailable("ios-below-26")
        }
        if let cached = cachedAvail,
           Date().timeIntervalSince(lastAvailCheck) < Self.availCacheTTL {
            return cached
        }
        let avail = FMSession.availability()
        // The router checks availability before every local turn — use that to
        // keep a warm, prewarmed session so the first token isn't cold.
        if case .available = avail {
            let box = (sessionBox as? FMSession) ?? FMSession()
            sessionBox = box
            box.prewarm()
        }
        lastAvailCheck = Date()
        cachedAvail = avail
        return avail
    }

    // MARK: Load

    /// Apple FM needs no per-model download; "loading" is just spinning up a
    /// session so the first token isn't penalized by lazy init.
    func load(modelId: String) async throws {
        guard #available(iOS 26.0, *) else {
            throw Self.unavailableError("ios-below-26")
        }
        try FMSession.assertAvailable()
        let box = FMSession()
        box.reset()
        sessionBox = box
        cachedAvail = nil // a fresh box replaced the old one — re-check next time
    }

    // MARK: Generate (streaming)

    func generate(_ req: GenRequest, onToken: @escaping (String) -> Void) async throws -> String {
        guard #available(iOS 26.0, *) else {
            throw Self.unavailableError("ios-below-26")
        }
        let box = (sessionBox as? FMSession) ?? FMSession()
        sessionBox = box
        return try await box.generate(system: req.system, prompt: req.prompt, onToken: onToken)
    }

    // MARK: Route (guided generation)

    func route(system: String, prompt: String, schemaJSON: String) async throws -> [String: Any] {
        guard #available(iOS 26.0, *) else {
            throw Self.unavailableError("ios-below-26")
        }
        let box = (sessionBox as? FMSession) ?? FMSession()
        sessionBox = box
        return try await box.route(system: system, prompt: prompt)
    }

    // MARK: Cancel

    func cancel() {
        // Dropping the session invalidates any in-flight stream the next time
        // a snapshot is awaited; combined with the `Task.checkCancellation()`
        // checkpoints in `FMSession.generate`/`route` (reached cooperatively
        // when the plugin cancels its `inferenceTask`) this stops emission
        // promptly. Idempotent.
        if #available(iOS 26.0, *) {
            (sessionBox as? FMSession)?.invalidate()
        }
        cachedAvail = nil // force the next availability() to re-prewarm
    }

    private static func unavailableError(_ reason: String) -> NSError {
        NSError(
            domain: "AppleFMEngine", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Apple FM unavailable: \(reason)"])
    }

    #else

    // MARK: - Fallback (framework not importable / pre-iOS 26 SDK)
    //
    // Keeps `AppleFMEngine` present as a real type so `OnDeviceAIPlugin` can
    // always instantiate its default engine. Everything reports unavailable and
    // throws; the plugin/Dart side then steers the user to an MLX model instead.

    func availability() -> EngineAvailability {
        .unavailable("foundationmodels-unavailable")
    }

    func load(modelId: String) async throws {
        throw Self.unavailableError("foundationmodels-unavailable")
    }

    func generate(_ req: GenRequest, onToken: @escaping (String) -> Void) async throws -> String {
        throw Self.unavailableError("foundationmodels-unavailable")
    }

    func route(system: String, prompt: String, schemaJSON: String) async throws -> [String: Any] {
        throw Self.unavailableError("foundationmodels-unavailable")
    }

    func cancel() {}

    private static func unavailableError(_ reason: String) -> NSError {
        NSError(
            domain: "AppleFMEngine", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "FoundationModels not available: \(reason)"])
    }

    #endif
}

#if canImport(FoundationModels)

// MARK: - FoundationModels session box (iOS 26+)
//
// All references to FoundationModels TYPES live here, behind
// `@available(iOS 26.0, *)`. `AppleFMEngine` reaches this only after a runtime
// `#available` check, holding it as an opaque `AnyObject` so the engine type
// itself is usable on every OS version.

@available(iOS 26.0, *)
final class FMSession {
    /// Reused across calls so multi-turn warm-up costs are amortized. We
    /// recreate it per `generate`/`route` only when a fresh system prompt is
    /// supplied; otherwise we keep one session and let the framework manage its
    /// transcript.
    private var session: LanguageModelSession?
    private var cachedSystem: String?

    /// Map Apple's availability to the shared `EngineAvailability` shape.
    static func availability() -> EngineAvailability {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            return .unavailable(describe(reason))
        @unknown default:
            return .unavailable("unknown")
        }
    }

    /// Throw if Apple FM can't run right now.
    static func assertAvailable() throws {
        guard case .available = SystemLanguageModel.default.availability else {
            throw NSError(
                domain: "AppleFMEngine", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Apple FM unavailable"])
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

    /// Spin up a fresh warm session (used by `load`) and prewarm it so the first
    /// real response isn't paying the model-load cost.
    func reset() {
        let s = LanguageModelSession()
        s.prewarm()
        session = s
        cachedSystem = ""
    }

    /// Prewarm ahead of the first turn (called when the engine is known
    /// available) so the first response is fast, not cold.
    func prewarm() {
        if session == nil {
            let s = LanguageModelSession()
            s.prewarm()
            session = s
            cachedSystem = ""
        } else {
            session?.prewarm()
        }
    }

    /// Drop the current session so any in-flight stream stops emitting.
    func invalidate() {
        session = nil
        cachedSystem = nil
    }

    private func ensureSession(system: String) -> LanguageModelSession {
        // Reuse the SAME warm session across turns (it stays loaded + keeps a
        // short conversational transcript). Only rebuild when the system prompt
        // actually changes — recreating per call was a big chunk of the latency.
        if let s = session, cachedSystem == system { return s }
        let s = system.isEmpty
            ? LanguageModelSession()
            : LanguageModelSession(instructions: Instructions(system))
        s.prewarm()
        session = s
        cachedSystem = system
        return s
    }

    func generate(system: String, prompt: String, onToken: @escaping (String) -> Void) async throws -> String {
        let session = ensureSession(system: system)

        // FoundationModels' `streamResponse(to:)` yields *cumulative* snapshots
        // of the answer-so-far. The plugin's EventChannel contract wants pure
        // deltas, so we diff against what we've already emitted and forward
        // only the new suffix.
        var emitted = ""
        let stream = session.streamResponse(to: prompt)
        for try await snapshot in stream {
            try Task.checkCancellation()
            // `snapshot.content` is the accumulated String for a free-form
            // (String) response.
            let full = snapshot.content
            if full.count > emitted.count, full.hasPrefix(emitted) {
                let delta = String(full[full.index(full.startIndex, offsetBy: emitted.count)...])
                if !delta.isEmpty { onToken(delta) }
            } else if full != emitted {
                // Non-monotonic snapshot (rare): re-sync by emitting the new
                // tail by longest-common-prefix.
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

    func route(system: String, prompt: String) async throws -> [String: Any] {
        let session = system.isEmpty
            ? (self.session ?? LanguageModelSession())
            : LanguageModelSession(instructions: Instructions(system))
        self.session = session

        // Guided generation: ask the framework to fill in a typed struct. This
        // is far more reliable than prompt-and-parse — Apple constrains decoding
        // to the schema, so we always get a well-formed `RoutingDecisionGen`.
        try Task.checkCancellation()
        let response = try await session.respond(
            to: prompt,
            generating: RoutingDecisionGen.self
        )
        return response.content.asDictionary()
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

    @Guide(description: "REQUIRED when action is 'answer': the FULL reply to the user in JARVIS's voice. When action is 'tool': a short spoken confirmation. Empty string for 'escalate'.")
    var answer: String

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
        out["answer"] = answer
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

#endif

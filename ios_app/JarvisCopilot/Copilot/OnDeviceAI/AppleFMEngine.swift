import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple FoundationModels engine — backs the `apple-fm` model. On iOS 26+ with
/// Apple Intelligence enabled this runs Apple's on-device language model: no
/// download, no storage, no RAM accounting on our side (the OS owns the weights).
///
/// Port of `mobile_client/ios/Runner/OnDeviceAI/AppleFMEngine.swift`.
///
/// **Availability shape.** The engine TYPE is deliberately NOT `@available`-gated:
/// the app deploys to iOS 17 and constructs the engine unconditionally, so it has
/// to exist on every OS version. Every FoundationModels API call sits behind an
/// `#available(iOS 26.0, *)` checkpoint *inside* a method body, and every
/// FoundationModels TYPE is referenced only from the `@available(iOS 26.0, *)`
/// ``FMSessionBox`` below, which the engine holds as an opaque `AnyObject`. On
/// iOS < 26 (or an SDK without the framework) it reports `.unavailable` and throws.
///
/// An `actor` because the session is warm, shared, mutable state: a voice turn
/// and a chat turn can both reach for it.
actor AppleFMEngine: OnDeviceInferenceEngine {

    static let shared = AppleFMEngine()

    nonisolated var id: String { OnDeviceEngineKind.appleFM.rawValue }

    /// The router checks availability before EVERY local turn. Re-running
    /// Apple's availability probe + `prewarm()` each time wastes ANE/CPU on
    /// back-to-back turns, so cache it briefly — short enough that a real
    /// availability change (the user enabling Apple Intelligence) is picked up
    /// within a few seconds.
    static let availabilityCacheSeconds: TimeInterval = 5

    /// `AnyObject` so this actor carries no `@available`-restricted stored
    /// property. Only ``FMSessionBox`` (iOS 26+) is ever put in here.
    private var sessionBox: AnyObject?
    private var cachedAvailability: OnDeviceEngineAvailability?
    private var lastAvailabilityCheck = Date.distantPast

    private let now: @Sendable () -> Date

    /// `{ Date() }` rather than `Date.init`: the metatype reference isn't
    /// `@Sendable`, which warns today and is an error in Swift 6 mode.
    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    // MARK: - Availability

    func availability() async -> OnDeviceEngineAvailability {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return .unavailable("ios-below-26") }
        if let cached = cachedAvailability,
           now().timeIntervalSince(lastAvailabilityCheck) < Self.availabilityCacheSeconds {
            return cached
        }
        let result = FMSessionBox.availability()
        // Availability is checked before every local turn — use that to keep a
        // warm, prewarmed session so the first token isn't cold.
        if result.isAvailable {
            let box = (sessionBox as? FMSessionBox) ?? FMSessionBox()
            sessionBox = box
            box.prewarm()
        }
        lastAvailabilityCheck = now()
        cachedAvailability = result
        return result
        #else
        return .unavailable("foundationmodels-unavailable")
        #endif
    }

    // MARK: - Load

    /// Apple FM needs no per-model download; "loading" is just spinning up a
    /// session so the first token isn't penalised by lazy init.
    func load(modelID: String) async throws {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { throw OnDeviceEngineError("ios-below-26") }
        guard FMSessionBox.availability().isAvailable else {
            throw OnDeviceEngineError(FMSessionBox.availability().reason ?? "unavailable")
        }
        let box = FMSessionBox()
        box.reset()
        sessionBox = box
        cachedAvailability = nil // a fresh box replaced the old one
        #else
        throw OnDeviceEngineError("foundationmodels-unavailable")
        #endif
    }

    // MARK: - Generate

    func generate(_ request: OnDeviceGenRequest,
                  onToken: @escaping @Sendable (String) -> Void) async throws -> String {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { throw OnDeviceEngineError("ios-below-26") }
        let box = (sessionBox as? FMSessionBox) ?? FMSessionBox()
        sessionBox = box
        return try await box.generate(system: request.system,
                                      prompt: request.prompt,
                                      onToken: onToken)
        #else
        throw OnDeviceEngineError("foundationmodels-unavailable")
        #endif
    }

    // MARK: - Cancel

    func cancel() async {
        #if canImport(FoundationModels)
        // Dropping the session invalidates any in-flight stream the next time a
        // snapshot is awaited; combined with the `Task.checkCancellation()`
        // checkpoint in `FMSessionBox.generate` this stops emission promptly.
        if #available(iOS 26.0, *) { (sessionBox as? FMSessionBox)?.invalidate() }
        cachedAvailability = nil // force the next availability() to re-prewarm
        #endif
    }
}

#if canImport(FoundationModels)

/// Every reference to a FoundationModels TYPE lives here, behind
/// `@available(iOS 26.0, *)`. ``AppleFMEngine`` reaches it only after a runtime
/// `#available` check and holds it as an opaque `AnyObject`, so the engine type
/// itself is usable on every OS version the app deploys to.
@available(iOS 26.0, *)
final class FMSessionBox {

    /// Reused across calls so multi-turn warm-up costs are amortised. Rebuilt
    /// only when the system prompt actually changes — recreating per call was a
    /// big chunk of the Flutter build's latency.
    private var session: LanguageModelSession?
    private var cachedSystem: String?

    /// Map Apple's availability onto the shared shape.
    static func availability() -> OnDeviceEngineAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            return .unavailable(describe(reason))
        @unknown default:
            return .unavailable("unknown")
        }
    }

    private static func describe(
        _ reason: SystemLanguageModel.Availability.UnavailableReason
    ) -> String {
        switch reason {
        case .deviceNotEligible: return "deviceNotEligible"
        case .appleIntelligenceNotEnabled: return "appleIntelligenceNotEnabled"
        case .modelNotReady: return "modelNotReady"
        @unknown default: return "unavailable"
        }
    }

    /// Fresh warm session (used by `load`).
    func reset() {
        let fresh = LanguageModelSession()
        fresh.prewarm()
        session = fresh
        cachedSystem = ""
    }

    /// Prewarm ahead of the first turn so the first response isn't cold.
    func prewarm() {
        if session == nil {
            reset()
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
        if let existing = session, cachedSystem == system { return existing }
        let fresh = system.isEmpty
            ? LanguageModelSession()
            : LanguageModelSession(instructions: Instructions(system))
        fresh.prewarm()
        session = fresh
        cachedSystem = system
        return fresh
    }

    func generate(system: String, prompt: String,
                  onToken: @escaping @Sendable (String) -> Void) async throws -> String {
        let session = ensureSession(system: system)

        // `streamResponse(to:)` yields CUMULATIVE snapshots of the answer so far.
        // Our contract is pure deltas, so diff against what we already emitted
        // and forward only the new suffix.
        var emitted = ""
        for try await snapshot in session.streamResponse(to: prompt) {
            try Task.checkCancellation()
            let full = snapshot.content
            if full.count > emitted.count, full.hasPrefix(emitted) {
                let delta = String(full[full.index(full.startIndex, offsetBy: emitted.count)...])
                if !delta.isEmpty { onToken(delta) }
            } else if full != emitted {
                // Non-monotonic snapshot (rare): re-sync on the longest common prefix.
                let delta = Self.suffixAfterCommonPrefix(old: emitted, new: full)
                if !delta.isEmpty { onToken(delta) }
            }
            emitted = full
        }
        return emitted
    }

    static func suffixAfterCommonPrefix(old: String, new: String) -> String {
        let oldChars = Array(old)
        let newChars = Array(new)
        var i = 0
        while i < oldChars.count, i < newChars.count, oldChars[i] == newChars[i] { i += 1 }
        return String(newChars[i...])
    }
}

#endif

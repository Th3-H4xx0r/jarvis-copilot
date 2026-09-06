import Foundation

/// The server's active JARVIS personality, so on-device replies speak in the same
/// voice as the server ones. Populated at startup from
/// `GET /api/personality/active`; empty means "no persona configured".
///
/// A tiny locked box rather than a stored `String` because the model that reads it
/// is a `Sendable` value type constructed in nonisolated contexts (see the default
/// argument of `LocalRouter.init`), while the writer is on the main actor.
final class OnDevicePersona: @unchecked Sendable {
    static let shared = OnDevicePersona()

    private let lock = NSLock()
    private var value: String

    init(_ initial: String = "") { value = initial }

    var text: String {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set {
            let clean = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            lock.lock(); defer { lock.unlock() }
            value = clean
        }
    }
}

/// ``OnDeviceModel`` implemented over an ``OnDeviceInferenceEngine`` — in
/// production Apple's FoundationModels, in tests a fake engine.
///
/// This is what turns `Copilot/Skills`' router from "always escalate" into a real
/// local lane: `LocalRouter` asks `availability()` before every turn, and streams
/// `generate(_:)` when it decides the turn can be answered on-device.
///
/// Port of the prompt-building half of `mobile_client/lib/services/on_device_ai.dart`.
/// The Dart `route()` (guided generation) is NOT ported — the Swift router
/// pre-gates with keywords and then asks for one free-form answer, which is both
/// faster (one inference instead of two) and keeps Apple's `@Generable` macro out
/// of a build that must also compile for iOS 17.
struct AppleFoundationModel: OnDeviceModel {

    let engine: any OnDeviceInferenceEngine
    let persona: OnDevicePersona

    init(engine: (any OnDeviceInferenceEngine)? = nil,
         persona: OnDevicePersona = .shared) {
        self.engine = engine ?? AppleFMEngine.shared
        self.persona = persona
    }

    func availability() async -> OnDeviceAvailability {
        switch await engine.availability() {
        case .available:
            return OnDeviceAvailability(available: true, engine: engine.id)
        case .unavailable(let reason):
            // Deviation from Dart: keep the engine id instead of collapsing to
            // "none", so the settings screen can say WHICH engine is unavailable.
            return OnDeviceAvailability(available: false, engine: engine.id, reason: reason)
        }
    }

    func generate(_ request: LocalRequest) -> AsyncThrowingStream<String, Error> {
        let engine = engine
        let genRequest = OnDeviceGenRequest(
            system: Self.assistantPrompt(persona: persona.text),
            prompt: request.userText)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    _ = try await engine.generate(genRequest) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Prompts
    //
    // Kept here so prompt engineering lives in one place, exactly as the Dart
    // service did.

    static let assistantInstruction =
        "Answer the user directly and briefly in plain text. Do not output "
        + "JSON, tool calls, or meta-commentary — just the reply."

    /// Plain assistant prompt for free-form generation. Leads with the server
    /// persona so the on-device reply sounds like the same JARVIS.
    static func assistantPrompt(persona: String) -> String {
        persona.isEmpty
            ? "You are JARVIS, a concise and helpful on-device assistant. \(assistantInstruction)"
            : "\(persona)\n\n\(assistantInstruction)"
    }
}

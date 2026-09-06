import Foundation

/// Shared abstraction over an on-device LLM engine.
///
/// Port of `mobile_client/ios/Runner/OnDeviceAI/OnDeviceEngine.swift`. In the
/// Flutter app this protocol sat behind a MethodChannel and had two
/// implementations; here it is called directly from Swift and only one engine
/// ships:
///
///   • ``AppleFMEngine`` — Apple's on-device FoundationModels (iOS 26+).
///   • ``MLXEngineSlot`` — the named slot for the MLX engine. MLX-Swift is a
///     third-party package and this app is system-frameworks-only, so the slot
///     exists (so ids, settings and the model catalogue keep their shape) but
///     always reports unavailable.
///
/// `route(...)` from the Flutter protocol is deliberately NOT ported: the Swift
/// ``LocalRouter`` decides with a keyword pre-gate and one free-form generation,
/// so nothing needs Apple's guided generation. That also keeps `@Generable` (a
/// macro that only exists on the iOS 26 SDK) out of the build.

/// Whether an engine can run right now, with a short reason when it can't.
///
/// The `String` payload is surfaced verbatim as the `reason` of an
/// ``OnDeviceAvailability``, so keep it short and explanatory
/// (e.g. "deviceNotEligible", "ios-below-26").
enum OnDeviceEngineAvailability: Equatable, Sendable {
    case available
    case unavailable(String)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    var reason: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}

/// One free-form generation request.
struct OnDeviceGenRequest: Sendable {
    let system: String
    let prompt: String
    /// Correlation id — carried so a future multiplexed engine can match a
    /// stream of tokens to the call that started it.
    let requestID: String

    init(system: String, prompt: String, requestID: String = UUID().uuidString) {
        self.system = system
        self.prompt = prompt
        self.requestID = requestID
    }
}

/// Which inference stack backs a local model. Kept as an enum (rather than a
/// bare string) so the settings UI and the catalogue can't disagree.
enum OnDeviceEngineKind: String, Sendable, CaseIterable {
    case appleFM = "apple-fm"
    case mlx

    var label: String {
        switch self {
        case .appleFM: return "Apple Intelligence"
        case .mlx: return "MLX"
        }
    }

    /// SF Symbol for the settings list.
    var symbol: String {
        switch self {
        case .appleFM: return "apple.logo"
        case .mlx: return "memorychip"
        }
    }
}

/// The contract every on-device engine fulfils.
///
/// Everything is `async` so an implementation can be an `actor` (``AppleFMEngine``
/// is): the FoundationModels session is mutable, shared state that a voice turn
/// and a chat turn can both reach for.
protocol OnDeviceInferenceEngine: Sendable {
    /// Stable engine identifier, mirrored into the model catalogue's `engine`
    /// field (`"apple-fm"` or `"mlx"`).
    nonisolated var id: String { get }

    /// Whether this engine can run on the current device/OS right now.
    func availability() async -> OnDeviceEngineAvailability

    /// Prepare the engine to serve `modelID`. For Apple FM this is a cheap
    /// session warm-up; there is no download.
    func load(modelID: String) async throws

    /// Stream a completion. `onToken` is called with each new DELTA (never a
    /// cumulative snapshot); the full text is returned on completion.
    func generate(_ request: OnDeviceGenRequest,
                  onToken: @escaping @Sendable (String) -> Void) async throws -> String

    /// Cancel the in-flight `generate`, if any. Cheap and idempotent — it may be
    /// called for a request that already finished.
    func cancel() async
}

/// Engine failures carry a short reason the settings screen can show verbatim.
struct OnDeviceEngineError: LocalizedError, Equatable {
    let reason: String
    init(_ reason: String) { self.reason = reason }
    var errorDescription: String? { "On-device engine unavailable: \(reason)" }
}

/// The MLX slot. Present so model ids, the engine enum and the settings screen
/// keep the shape they have in the Flutter app; permanently unavailable because
/// MLX-Swift is a third-party package this target does not link.
struct MLXEngineSlot: OnDeviceInferenceEngine {
    static let unavailableReason = "mlx-not-built"

    nonisolated var id: String { OnDeviceEngineKind.mlx.rawValue }

    func availability() async -> OnDeviceEngineAvailability {
        .unavailable(Self.unavailableReason)
    }

    func load(modelID: String) async throws {
        throw OnDeviceEngineError(Self.unavailableReason)
    }

    func generate(_ request: OnDeviceGenRequest,
                  onToken: @escaping @Sendable (String) -> Void) async throws -> String {
        throw OnDeviceEngineError(Self.unavailableReason)
    }

    func cancel() async {}
}

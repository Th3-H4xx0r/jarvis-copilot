import Foundation

/// Shared types for the on-device AI layer. These are the interfaces the router,
/// the tool catalogue and (later) the chat/voice surfaces all speak in.
///
/// Port of `mobile_client/lib/services/on_device_ai_types.dart` — the MLX /
/// Apple-Foundation-Models engines are deliberately NOT ported in this wave;
/// only the protocol and an unavailable default, so the router's behaviour is
/// exercised without an inference stack.

/// How aggressively the on-device layer handles a turn before escalating.
enum LocalAiTier: String, Sendable, CaseIterable {
    /// Everything goes to the server (today's behaviour).
    case off
    /// Local model answers trivial/safe turns + fires device-local skills;
    /// everything else escalates.
    case routerCommands = "router_commands"
    /// Local model also attempts client-dispatchable tool calls and streams
    /// longer local answers; only server-only work + low confidence escalate.
    case fullLocalFirst = "full_local_first"

    /// The wire value stored in preferences / sent to the server.
    var wire: String { rawValue }

    static func parse(_ s: String?) -> LocalAiTier {
        guard let s, let tier = LocalAiTier(rawValue: s) else { return .off }
        return tier
    }
}

/// Where a tool actually runs — decides whether the client can execute it
/// locally or must escalate to the server agent.
enum ToolExecClass: String, Sendable {
    /// Phone runs it itself; works fully offline + instant.
    case deviceLocal
    /// The app's InvokeRunner can dispatch it (may hop the bridge to another
    /// device) — needs network but not the server agent.
    case clientDispatchable
    /// Must be run by the server agent.
    case serverOnly
}

/// Which app surface a turn came from.
enum VoiceSurface: String, Sendable { case chat, voice }

/// Engine availability snapshot.
struct OnDeviceAvailability: Sendable {
    let available: Bool
    let engine: String
    let reason: String?

    init(available: Bool, engine: String, reason: String? = nil) {
        self.available = available
        self.engine = engine
        self.reason = reason
    }

    static func unavailable(_ reason: String) -> OnDeviceAvailability {
        OnDeviceAvailability(available: false, engine: "none", reason: reason)
    }
}

/// A single inference request handed to the engine.
struct LocalRequest: Sendable {
    let userText: String
    let surface: VoiceSurface
    /// Serialized tool catalogue the model sees (name + one-line description).
    let toolCatalogJSON: String
    let tier: LocalAiTier
}

/// One tool the router decided to run locally.
struct ToolCallPlan {
    let name: String
    let args: [String: Any]
    let execClass: ToolExecClass
    /// True when the action is outward-facing/destructive and the caller should
    /// confirm (chat) / ask aloud (voice) before running it.
    let requiresConfirm: Bool
    /// A short natural confirmation in JARVIS's voice, shown/spoken instead of a
    /// flat "Done." when present.
    let confirmation: String?

    init(name: String, args: [String: Any], execClass: ToolExecClass,
         requiresConfirm: Bool = false, confirmation: String? = nil) {
        self.name = name
        self.args = args
        self.execClass = execClass
        self.requiresConfirm = requiresConfirm
        self.confirmation = confirmation
    }
}

/// What the router tells the caller to do with one turn.
enum RouteResult {
    /// Speak/show this text — generated on-device.
    case directAnswer(String)
    case toolCall(ToolCallPlan)
    /// Hand off to the server path with this reason (for logs/telemetry).
    case escalate(String)

    var escalateReason: String? {
        if case .escalate(let reason) = self { return reason }
        return nil
    }

    var plan: ToolCallPlan? {
        if case .toolCall(let plan) = self { return plan }
        return nil
    }
}

/// The on-device inference boundary.
///
/// TODO(local-ai wave): implement over Apple Foundation Models / MLX. Nothing
/// else in this area needs to change — the router already treats an unavailable
/// engine as "escalate", which is exactly today's behaviour.
protocol OnDeviceModel: Sendable {
    func availability() async -> OnDeviceAvailability
    func generate(_ request: LocalRequest) -> AsyncThrowingStream<String, Error>
}

/// The default: no engine. Every turn escalates, so wiring the router in ahead
/// of an engine is a no-op rather than a regression.
struct UnavailableOnDeviceModel: OnDeviceModel {
    let reason: String

    init(reason: String = "no on-device engine in this build") { self.reason = reason }

    func availability() async -> OnDeviceAvailability { .unavailable(reason) }

    func generate(_ request: LocalRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish(throwing: SkillError.unavailable(reason)) }
    }
}

/// Persisted configuration for the on-device AI layer. Plain mutable fields so
/// tests and a settings screen can read/write them directly; `load`/`save`
/// handle durability.
///
/// Port of `mobile_client/lib/services/local_ai_settings.dart`, minus the
/// Android-only STT flag.
@MainActor
final class LocalAiSettings {
    static let shared = LocalAiSettings()

    private let store: any KeyValueStore

    // Safe defaults: off / server.
    var tier: LocalAiTier = .off
    var chatEnabled = false
    var voiceEnabled = false
    var activeLocalModelID = "apple-fm"

    /// Minimum self-reported confidence to accept a local decision. Default 0 —
    /// the model decides; confidence never forces escalation unless raised.
    var confidenceFloor = 0.0

    /// Confirm destructive/outward actions before running them locally.
    var confirmLocalActions = true

    /// Let device commands short-circuit even when a server model is picked.
    var commandShortCircuit = true

    /// Show the "on-device" badge on locally-handled replies.
    var showBadge = true

    init(store: any KeyValueStore = UserDefaults.standard) {
        self.store = store
    }

    var enabledForChat: Bool { tier != .off && chatEnabled }
    var enabledForVoice: Bool { tier != .off && voiceEnabled }

    func enabled(for surface: VoiceSurface) -> Bool {
        surface == .chat ? enabledForChat : enabledForVoice
    }

    private static let kTier = "lai_tier"
    private static let kChat = "lai_chat"
    private static let kVoice = "lai_voice"
    private static let kModel = "lai_model"
    private static let kConfidence = "lai_conf"
    private static let kConfirm = "lai_confirm"
    private static let kShort = "lai_short"
    private static let kBadge = "lai_badge"

    func load() {
        tier = LocalAiTier.parse(store.string(Self.kTier))
        chatEnabled = store.string(Self.kChat) == "1"
        voiceEnabled = store.string(Self.kVoice) == "1"
        activeLocalModelID = store.string(Self.kModel) ?? "apple-fm"
        confidenceFloor = Double(store.string(Self.kConfidence) ?? "") ?? 0
        // Default true unless explicitly stored "0".
        confirmLocalActions = store.string(Self.kConfirm) != "0"
        commandShortCircuit = store.string(Self.kShort) != "0"
        showBadge = store.string(Self.kBadge) != "0"
    }

    func save() {
        store.set(tier.wire, forKey: Self.kTier)
        store.set(chatEnabled ? "1" : "0", forKey: Self.kChat)
        store.set(voiceEnabled ? "1" : "0", forKey: Self.kVoice)
        store.set(activeLocalModelID, forKey: Self.kModel)
        store.set("\(confidenceFloor)", forKey: Self.kConfidence)
        store.set(confirmLocalActions ? "1" : "0", forKey: Self.kConfirm)
        store.set(commandShortCircuit ? "1" : "0", forKey: Self.kShort)
        store.set(showBadge ? "1" : "0", forKey: Self.kBadge)
    }
}

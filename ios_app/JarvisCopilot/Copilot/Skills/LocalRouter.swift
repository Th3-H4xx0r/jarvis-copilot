import Foundation

/// Decides, for one user turn, whether the on-device model answers it or whether
/// to escalate to the server. The router never touches the network — it returns
/// a `RouteResult`; the caller acts on it.
///
/// Design (fast + reliable): the on-device model is used ONLY to ANSWER
/// conversation/knowledge — the one thing a small model does well and fast (one
/// streamed inference). A cheap keyword PRE-GATE sends everything else (device
/// commands, live data, the user's accounts, sending/calling/playing) to the
/// server, where tool execution actually works. No guided-generation routing
/// call, so there's only ONE model inference per local turn.
///
/// Port of `mobile_client/lib/services/local_router.dart`.
@MainActor
final class LocalRouter {
    private let model: any OnDeviceModel
    private let settings: LocalAiSettings
    /// The skills this device actually has, evaluated per turn (the registry can
    /// change while the app runs, and the user can disable a skill).
    private let availableSkills: @MainActor () -> Set<String>

    /// The default engine is now real: ``AppleFoundationModel`` over Apple's
    /// on-device FoundationModels (`Copilot/OnDeviceAI`). It still reports
    /// unavailable — and so still escalates every turn — on anything below
    /// iOS 26 or without Apple Intelligence, which is exactly what
    /// `UnavailableOnDeviceModel` did before it.
    init(model: any OnDeviceModel = AppleFoundationModel(),
         settings: LocalAiSettings = .shared,
         availableSkills: (@MainActor () -> Set<String>)? = nil) {
        self.model = model
        self.settings = settings
        self.availableSkills = availableSkills ?? { LocalExecutor.deviceSkills() }
    }

    func handle(_ userText: String, surface: VoiceSurface) async -> RouteResult {
        let text = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .escalate("empty-input") }

        // Tier / per-surface gate (zero added latency).
        if settings.tier == .off { return .escalate("tier-off") }
        if !settings.enabled(for: surface) { return .escalate("\(surface.rawValue)-disabled") }

        // Engine availability.
        let availability = await model.availability()
        if !availability.available {
            return .escalate("unavailable:\(availability.reason ?? "unknown")")
        }

        // Device-local action with a safety allow-list. Checked FIRST: it knows
        // which skills this device actually has, refuses anything off the
        // allow-list, and covers more verbs (alarms, clipboard, camera, URLs)
        // than the older matcher. Anything it doesn't recognise falls through,
        // so previous behaviour is unchanged.
        if case .run(let local) = LocalExecutor.classify(text, skills: availableSkills()) {
            return .toolCall(ToolCallPlan(name: local.skill, args: local.args,
                                          execClass: .deviceLocal,
                                          confirmation: local.ack))
        }

        // Instant local command (deterministic, no model) for simple, reliable,
        // this-device actions — open an app, flashlight, vibrate, volume. These
        // run immediately via the existing skill; no model means no fabricated
        // args.
        if let cmd = LocalCommandMatcher.match(text) {
            return .toolCall(ToolCallPlan(name: cmd.name, args: cmd.args,
                                          execClass: .deviceLocal,
                                          confirmation: cmd.confirmation))
        }

        // Pre-gate: anything that needs to DO something or fetch real data goes
        // to the server (the small on-device model fabricates args / role-plays
        // these, and the server has the working skills + the user's data). The
        // local model only answers conversation/knowledge.
        if Self.looksLikeServerRequest(text) { return .escalate("server-request") }

        // Answer locally — the caller streams a full reply from the model.
        return .directAnswer("")
    }

    /// True when the turn looks like a command, an outward action, or a request
    /// for live/real-world or account data — i.e. something the on-device model
    /// can't reliably do and that belongs on the server.
    static func looksLikeServerRequest(_ text: String) -> Bool {
        serverRequestRx.hasMatch(text)
    }

    private static let serverRequestRx = Rx(
        #"\b("#
        // outward comms
        + #"text|sms|send|email|e-?mail|call|dial|message|msg|dm|tweet|whatsapp|imessage|"#
        // media / apps / navigation
        + #"play|pause|skip|stream|spotify|youtube|open|launch|navigate|directions?|maps?|uber|"#
        // create / schedule / device control
        + #"set|turn|switch|toggle|remind|reminders?|schedule|alarm|timer|vibrate|flashlight|torch|"#
        + #"brightness|volume|wifi|bluetooth|airplane|dnd|book|reserve|order|buy|purchase|pay|"#
        + #"add|create|delete|remove|search|google|find|look ?up|translate|download|install|"#
        // live data / accounts / "my …"
        + #"weather|forecast|temperature|news|headlines?|stocks?|prices?|traffic|scores?|sports?|"#
        + #"calendar|agenda|inbox|emails?|meetings?|tasks?|notes?|brief|flights?|"#
        + #"my"#
        + #")\b"#)
}

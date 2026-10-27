import Foundation

/// The model or harness one Ask Jarvis action runs on. No choice (nil) = "Same as default".
enum AgentChoice: Codable, Equatable, Hashable, Sendable {
    case harness(String)
    case model(id: String, provider: String?)
}

/// What a turn sends to `/api/chat/start`: a harness id, or a model with NO harness id
/// (the server only honours `model` for clients that leave `harness_id` out).
struct TurnChoice: Equatable, Sendable {
    var harnessID: String?
    var model: String?
    var provider: String?
}

/// Where an action was run from: which chat its Ask Jarvis lands in, a widget's override, and
/// whether it was his own press in Control Center — the only place Skip Face ID applies. A widget
/// (a design Jarvis wrote could hide a button), the ring (its gestures aren't authenticated over
/// Bluetooth), a Shortcut or Siri always ask for Face ID.
struct RingActionContext: Equatable, Sendable {
    var chatKey: String
    var chatTitle: String
    var widgetAgent: WidgetAgent? = nil
    var physical: Bool = false
    /// Pressed on a Lock Screen card that iOS ran only after the iPhone was unlocked.
    var unlocked: Bool = false

    /// Ring gestures share one "Ring" chat, as they always have.
    static let ring = RingActionContext(chatKey: "ring.inputs", chatTitle: "Ring")

    /// Each button has its own chat, named after it.
    static func button(_ button: ControlButton, widgetAgent: WidgetAgent?, physical: Bool) -> RingActionContext {
        let name = button.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return RingActionContext(chatKey: "button.\(button.id)", chatTitle: name.isEmpty ? "Jarvis button" : name,
                                 widgetAgent: widgetAgent, physical: physical)
    }
}

enum ActionAgent {
    /// What a turn sends. Every turn names its choice: the server keeps a harness on the chat it
    /// ran in, so "" for Same as default would follow whatever ran there last.
    static func turn(choice: AgentChoice?, override: WidgetAgent?, defaultHarness: String) -> TurnChoice {
        let fallback = defaultHarness.isEmpty ? "single" : defaultHarness
        switch override {
        case .default?: return TurnChoice(harnessID: fallback)
        case .harness(let id)?: return TurnChoice(harnessID: id)
        case .model(let id, let provider)?: return TurnChoice(model: id, provider: provider)
        case nil: break
        }
        switch choice {
        case .harness(let id)?: return TurnChoice(harnessID: id)
        case .model(let id, let provider)?: return TurnChoice(model: id, provider: provider)
        case nil: return TurnChoice(harnessID: fallback)
        }
    }

    /// His one Default right now: the server's word, else the last one this app saw.
    @MainActor
    static func defaultHarness() async -> String {
        if let snapshot = try? await HarnessAPI().snapshot() {
            for key in ["default", "chat"] {
                if let id = snapshot.assignments[key], !id.isEmpty { return id }
            }
            return "single"
        }
        return HarnessStore.shared.effective("default")
    }
}

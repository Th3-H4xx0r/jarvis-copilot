import Foundation

/// What the car shows for a voice turn — the Live Activity's CarPlay card and the
/// Talk widget: his words while he talks, then Jarvis's reply.
///
/// Compiled into the app and the widget (Copilot/Shared), so the rule is tested once.
enum CarCardText {
    /// Matches the island's own cap (`VoiceLiveActivityThrottle.lineLimit`).
    static let lineLimit = 120

    static func title(state: String) -> String {
        switch state {
        case "listening": return "Listening…"
        case "thinking": return "Thinking…"
        case "speaking": return "Speaking"
        case "error": return "Error"
        default: return "Talk to Jarvis"
        }
    }

    /// Listening and thinking: what he said. Speaking, idle (a held reply) and
    /// error: Jarvis's side. Empty when there's nothing to say.
    static func line(state: String, transcript: String, activity: String) -> String {
        let text: String
        switch state {
        case "listening", "thinking": text = transcript
        default: text = activity.isEmpty && state != "idle" ? transcript : activity
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > lineLimit else { return trimmed }
        return String(trimmed.prefix(lineLimit)) + "…"
    }
}

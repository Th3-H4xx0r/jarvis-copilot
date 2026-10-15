import SwiftUI

/// Which logo, name and colour each agent's Live Activity wears.
///
/// The logos are Simple Icons vectors (CC0; see THIRD_PARTY_NOTICES.md) in
/// `JarvisWidget/AgentLogos.xcassets`, a resource of both the widget and the app.
/// They are drawn as white template marks on the island's black, so the one
/// accent stays the state colour (accent working, amber waiting on you). Brands
/// Simple Icons doesn't carry get a plain SF Symbol, and Jarvis keeps its orb.
enum AgentBrand {
    /// Every agent type with its own activity, in settings order. Mirrors
    /// `AGENTS` in `agent/agent_la_push.py`.
    static let all = ["claude", "codex", "gemini", "copilot", "cursor", "opencode",
                      "amp", "antigravity", "muse", "jarvis"]

    enum Mark: Equatable {
        /// An image in `AgentLogos.xcassets`.
        case asset(String)
        /// An SF Symbol, for a brand Simple Icons doesn't have.
        case symbol(String)
        /// The Jarvis orb.
        case orb
    }

    /// The activity an agent's sessions belong to: Claude Code and Claude Desktop
    /// share "claude". Nil for an agent this build doesn't know.
    static func group(of agent: String) -> String? {
        let a = agent.lowercased()
        if a == "claude-desktop" { return "claude" }
        return all.contains(a) ? a : nil
    }

    static func mark(for agent: String) -> Mark {
        switch group(of: agent) {
        case "claude": return .asset("agent_claude")
        case "codex": return .asset("agent_openai")
        case "gemini": return .asset("agent_gemini")
        case "copilot": return .asset("agent_copilot")
        case "cursor": return .asset("agent_cursor")
        case "opencode": return .asset("agent_opencode")
        // Not in Simple Icons ("amp" there is the AMP web framework, not
        // Sourcegraph's agent), so a symbol each.
        case "amp": return .symbol("bolt.fill")
        case "antigravity": return .symbol("atom")
        case "muse": return .symbol("sparkles")
        case "jarvis": return .orb
        default: return .symbol("chevron.left.forwardslash.chevron.right")
        }
    }

    /// The agent's short name — the settings rows and the activity header when
    /// the lead's own name isn't known yet.
    static func title(for agent: String) -> String {
        switch group(of: agent) {
        case "claude": return "Claude"
        case "codex": return "Codex"
        case "gemini": return "Gemini"
        case "copilot": return "Copilot"
        case "cursor": return "Cursor"
        case "opencode": return "OpenCode"
        case "amp": return "Amp"
        case "antigravity": return "Antigravity"
        case "muse": return "Muse"
        case "jarvis": return "Jarvis"
        default: return agent.isEmpty ? "Agent" : agent.capitalized
        }
    }

    /// The settings row's second line: which apps the activity covers.
    static func covers(_ agent: String) -> String {
        switch group(of: agent) {
        case "claude": return "Claude Code and Desktop"
        case "codex": return "OpenAI Codex"
        case "gemini": return "Gemini CLI"
        case "copilot": return "GitHub Copilot CLI"
        case "jarvis": return "Jarvis's own coding sessions"
        default: return title(for: agent)
        }
    }
}

// MARK: - State colours and words (the app and the widget share them)

/// Amber waits on you, the accent works, red failed, grey rests — the Agents
/// tab's rules (`AgentRowStatus`), in colours the widget can also read.
func jcAgentStateColor(_ state: String) -> Color {
    switch state {
    case "approval", "question": return JcState.amber
    case "working", "thinking": return JcAccent.color
    case "error": return JcState.danger
    default: return Color(red: 0.51, green: 0.55, blue: 0.59)
    }
}

func jcAgentStateLabel(_ state: String) -> String {
    switch state {
    case "approval": return "Needs you"
    case "question": return "Question"
    case "working": return "Working"
    case "thinking": return "Thinking"
    case "finished": return "Finished"
    case "error": return "Failed"
    case "ratelimit": return "Rate-limited"
    default: return "Idle"
    }
}

/// A fleet-bar shorthand (p / w / e / i) as its state colour.
func jcAgentBarColor(_ short: String) -> Color {
    switch short {
    case "p": return jcAgentStateColor("approval")
    case "w": return jcAgentStateColor("working")
    case "e": return jcAgentStateColor("error")
    default: return jcAgentStateColor("idle")
    }
}

/// Where a tap on an agent's activity lands: the lead session in the Agents tab.
func jcAgentWidgetURL(_ st: AgentActivityAttributes.ContentState) -> URL {
    // A coding row no hook talks for ("row:<id>") has no Agents-tab session.
    guard !st.key.isEmpty, !st.key.hasPrefix("row:"),
          let key = st.key.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
          let url = URL(string: "jarviscopilot://agents?key=\(key)")
    else { return URL(string: "jarviscopilot://agents")! }
    return url
}

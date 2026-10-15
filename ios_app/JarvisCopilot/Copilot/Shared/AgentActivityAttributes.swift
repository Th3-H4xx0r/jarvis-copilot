import ActivityKit
import Foundation

/// Attributes for one AGENT's Live Activity — Claude, Codex, Gemini, Copilot,
/// Cursor, OpenCode, Amp, Antigravity, Muse or Jarvis each get their own, grouping
/// that agent's live sessions (`agent/agent_la_push.py` on the server).
///
/// Shared between the app (which starts / updates / ends them, and registers
/// their push tokens) and the JarvisWidget extension (which renders them). The
/// server can also START one with an APNs push-to-start, which names this type
/// (`attributes-type: "AgentActivityAttributes"`) and sends `{"agent": …}` — so
/// the type name and the key below are wire format, not just Swift.
struct AgentActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// Live sessions of this agent (the lead included).
        var count: Int = 0
        /// How many of them wait on you (an approval or a question).
        var waiting: Int = 0
        /// How many are working / thinking.
        var working: Int = 0
        /// The lead session's agent, spelled out ("Claude Code", "Claude Desktop", "Codex").
        var name: String = ""
        /// The lead session's project (≤ 22 chars).
        var project: String = ""
        /// The lead's state: working | thinking | approval | question | finished |
        /// error | ratelimit | idle.
        var state: String = "idle"
        /// What the lead is doing right now, e.g. "Bash: npm test" (≤ 60 chars).
        var step: String = ""
        /// The waiting request Allow / Deny answer. Empty when nothing holds it
        /// (the phone couldn't reach it), so no buttons are drawn.
        var fingerprint: String = ""
        /// "approval" | "question" | "".
        var kind: String = ""
        /// When the lead started its turn (Unix seconds; 0 = unknown).
        var since: Double = 0
        /// The lead's engine key, for the tap's deep link.
        var key: String = ""
        /// Every session's state, most urgent first, as shorthand (p waiting,
        /// w working, e error, i idle), comma-joined, at most 8 — the fleet bar.
        var bar: String = ""
        /// The "Show Allow / Deny on the Lock Screen" setting.
        var actions: Bool = true
        /// The group's most recent activity (Unix seconds), for "idle 12 min".
        var last: Double = 0
        /// When the lead started waiting on you (Unix seconds; 0 = not waiting):
        /// the amber "waiting for your OK · 0:13" timer counts up from here.
        var waitingSince: Double = 0
        /// The question it asked (≤ 90 chars), for kind "question".
        var question: String = ""
        /// Its options as Lock Screen buttons — only when they fit (one
        /// single-select question, ≤ 3 short labels); else one Answer button.
        var options: [String] = []
    }

    /// The agent TYPE: claude | codex | gemini | copilot | cursor | opencode |
    /// amp | antigravity | muse | jarvis. Fixed for the activity's life.
    var agent: String
}

extension AgentActivityAttributes.ContentState {
    /// Every key is optional on the wire: a push from an older (or newer) server
    /// decodes with the defaults instead of failing — a failed decode freezes the
    /// activity on its last frame.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? d.count
        waiting = try c.decodeIfPresent(Int.self, forKey: .waiting) ?? d.waiting
        working = try c.decodeIfPresent(Int.self, forKey: .working) ?? d.working
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        project = try c.decodeIfPresent(String.self, forKey: .project) ?? d.project
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? d.state
        step = try c.decodeIfPresent(String.self, forKey: .step) ?? d.step
        fingerprint = try c.decodeIfPresent(String.self, forKey: .fingerprint) ?? d.fingerprint
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? d.kind
        since = try c.decodeIfPresent(Double.self, forKey: .since) ?? d.since
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? d.key
        bar = try c.decodeIfPresent(String.self, forKey: .bar) ?? d.bar
        actions = try c.decodeIfPresent(Bool.self, forKey: .actions) ?? d.actions
        last = try c.decodeIfPresent(Double.self, forKey: .last) ?? d.last
        waitingSince = try c.decodeIfPresent(Double.self, forKey: .waitingSince) ?? d.waitingSince
        question = try c.decodeIfPresent(String.self, forKey: .question) ?? d.question
        options = try c.decodeIfPresent([String].self, forKey: .options) ?? d.options
    }

    /// The lead waits on you.
    var waitsOnYou: Bool { state == "approval" || state == "question" }
    /// The lead is busy (the timer runs).
    var isWorking: Bool { state == "working" || state == "thinking" }
    /// Sessions besides the lead.
    var others: Int { max(0, count - 1) }
    /// Allow / Deny: only for an approval something holds, with the setting on.
    var showsButtons: Bool { actions && kind == "approval" && !fingerprint.isEmpty }
    /// The question's options as buttons: something holds it, they fit, setting on.
    var showsOptions: Bool { actions && kind == "question" && !fingerprint.isEmpty && !options.isEmpty }
    /// When the wait began (falls back to the last activity for an older server).
    var waitingStart: Double { waitingSince > 0 ? waitingSince : last }
    /// The fleet bar, one entry per session (p / w / e / i).
    var barStates: [String] {
        bar.split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }

    /// How strongly the system should prefer this activity for the Dynamic
    /// Island when several run: waiting on you beats working beats idle.
    var relevance: Double {
        if waitsOnYou { return 80 }
        if isWorking { return 40 }
        return 5
    }
}

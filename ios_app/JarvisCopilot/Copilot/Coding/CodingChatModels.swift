import Foundation

/// The chat-transcript half of `coding/coding_models.dart`
/// (`GET /api/coding/session/{id}/messages` and `/prompt`). Split out of
/// `CodingModels.swift` to keep both files readable.

// MARK: - Tool uses

/// One tool use inside an assistant chat message: name + one-line summary, with
/// the output snippet revealed when the card is expanded.
struct CodingChatTool: Identifiable, Equatable {
    /// Position within the message — stable for `ForEach` and for diffing a
    /// re-fetched message against the one we already show.
    let id: Int
    let name: String
    let summary: String
    let output: String
    let ok: Bool
    /// True while the tool/subagent is still in flight (no result yet — the
    /// server sends `ok: null`). A completed Task has `running == false`.
    let running: Bool
    /// Non-empty when this tool is a spawned subagent (`Task`/`Agent`) — the
    /// subagent's type (e.g. "Explore"). Renders as a subagent tree node.
    let subagentType: String
    /// File-edit tools carry a renderable unified diff (lines prefixed with
    /// `+` / `-` / ` ` / `@@`) — the chat view shows these as red/green blocks.
    let diff: [String]

    init(id: Int = 0, name: String, summary: String = "", output: String = "",
         ok: Bool = true, running: Bool = false, subagentType: String = "",
         diff: [String] = []) {
        self.id = id
        self.name = name
        self.summary = summary
        self.output = output
        self.ok = ok
        self.running = running
        self.subagentType = subagentType
        self.diff = diff
    }

    init(json j: [String: Any], index: Int = 0) {
        // `ok: null` is the server's "still running" marker, so it decides BOTH
        // `ok` (optimistically true) and `running`.
        let okMissing = j["ok"] == nil || j["ok"] is NSNull
        self.init(
            id: index,
            name: CodingJSON.text(j["name"], "tool"),
            summary: CodingJSON.text(j["summary"]),
            output: CodingJSON.text(j["output"]),
            ok: okMissing ? true : CodingJSON.bool(j["ok"]),
            running: okMissing,
            subagentType: CodingJSON.text(j["subagent_type"]),
            diff: CodingJSON.strings(j["diff"]))
    }

    var isSubagent: Bool { !subagentType.isEmpty || name == "Task" || name == "Agent" }
}

// MARK: - Messages

/// One conversation message. `i` is the server's stable 0-based index — pass
/// `after=<count you already have>` to fetch only the new tail. An assistant
/// message may carry BOTH `text` and `tools`.
struct CodingChatMessage: Identifiable, Equatable {
    /// The server's stable 0-based index; doubles as the SwiftUI identity.
    let i: Int
    /// user | assistant
    let role: String
    let text: String
    let tools: [CodingChatTool]
    /// Epoch seconds, or nil.
    let ts: Double?

    var id: Int { i }
    var isUser: Bool { role == "user" }

    init(i: Int, role: String, text: String = "", tools: [CodingChatTool] = [], ts: Double? = nil) {
        self.i = i
        self.role = role
        self.text = text
        self.tools = tools
        self.ts = ts
    }

    init(json j: [String: Any]) {
        self.init(
            i: CodingJSON.int(j["i"]),
            role: CodingJSON.text(j["role"], "assistant"),
            text: CodingJSON.text(j["text"]),
            tools: CodingJSON.maps(j["tools"]).enumerated().map {
                CodingChatTool(json: $0.element, index: $0.offset)
            },
            ts: CodingJSON.double(j["ts"]))
    }
}

// MARK: - Context gauge

/// Per-chat context-window occupancy (the auto-compact gauge). `used` ≈ live
/// context size = input + cache_creation + cache_read tokens of the latest turn.
struct ChatContext: Equatable {
    let used: Int
    let window: Int
    let pct: Int
    let model: String?

    init(used: Int, window: Int, pct: Int, model: String? = nil) {
        self.used = used
        self.window = window
        self.pct = pct
        self.model = model
    }

    /// Nil when there's no usage yet — a zero/missing `window` would divide by
    /// zero in the gauge.
    static func from(_ o: Any?) -> ChatContext? {
        guard let j = o as? [String: Any] else { return nil }
        let window = CodingJSON.int(j["window"])
        guard window > 0 else { return nil }
        return ChatContext(used: CodingJSON.int(j["used"]),
                           window: window,
                           pct: CodingJSON.int(j["pct"]),
                           model: CodingJSON.str(j["model"]))
    }

    /// Compact "124k" style.
    static func fmtTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1000 { return "\(Int((Double(n) / 1000).rounded()))k" }
        return "\(n)"
    }

    var usedLabel: String { Self.fmtTokens(used) }
    var windowLabel: String { Self.fmtTokens(window) }
}

// MARK: - Live status line

/// The live status line parsed into its parts so the thinking bubble can style
/// each — e.g. "✳ Moonwalking… (3m 22s · ↓ 19.5k tokens · …xhigh effort)" →
/// verb "Moonwalking…", elapsed "3m 22s", tokens "↓ 19.5k tokens", effort
/// "…xhigh effort". Any unclassified segments land in `extra`.
struct LiveStatus: Equatable {
    let verb: String
    let elapsed: String?
    let tokens: String?
    let effort: String?
    let extra: [String]

    init(verb: String, elapsed: String? = nil, tokens: String? = nil,
         effort: String? = nil, extra: [String] = []) {
        self.verb = verb
        self.elapsed = elapsed
        self.tokens = tokens
        self.effort = effort
        self.extra = extra
    }

    /// Leading spinner glyph(s) Claude Code prints before the verb.
    ///
    /// Optional rather than `try!`: a status line is cosmetic, and crashing the
    /// app over one is never the right trade. Both callers degrade to the plain
    /// string when the pattern didn't compile.
    private static let spinner = try? NSRegularExpression(
        pattern: "^[\\s✱✳✴✷✻✽⏺·\\*•◦✢]+")
    private static let timeSeg = try? NSRegularExpression(pattern: "^\\d+\\s*[hms]\\b")

    static func parse(_ raw: String?) -> LiveStatus? {
        let line = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty { return nil }
        let s = stripSpinner(line)

        var verb = s
        var inside = ""
        if let open = s.firstIndex(of: "("), s.hasSuffix(")") {
            verb = String(s[s.startIndex..<open]).trimmingCharacters(in: .whitespaces)
            inside = String(s[s.index(after: open)..<s.index(before: s.endIndex)])
                .trimmingCharacters(in: .whitespaces)
        }
        if verb.isEmpty { verb = "Working" }

        var elapsed: String?
        var tokens: String?
        var effort: String?
        var extra: [String] = []
        for partRaw in inside.components(separatedBy: "·") {
            let p = partRaw.trimmingCharacters(in: .whitespaces)
            if p.isEmpty { continue }
            let lower = p.lowercased()
            if elapsed == nil, matches(timeSeg, p) {
                elapsed = p
            } else if tokens == nil,
                      lower.contains("token") || p.contains("↑") || p.contains("↓") {
                tokens = p
            } else if effort == nil,
                      lower.contains("effort") || lower.contains("thinking") {
                effort = p
            } else {
                extra.append(p)
            }
        }
        return LiveStatus(verb: verb, elapsed: elapsed, tokens: tokens, effort: effort, extra: extra)
    }

    private static func stripSpinner(_ s: String) -> String {
        let ns = s as NSString
        guard let spinner,
              let m = spinner.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              m.range.location == 0 else {
            return String(s.drop(while: { $0 == " " }))
        }
        let rest = ns.substring(from: m.range.length)
        return String(rest.drop(while: { $0 == " " || $0 == "\t" }))
    }

    private static func matches(_ re: NSRegularExpression?, _ s: String) -> Bool {
        guard let re else { return false }
        let ns = s as NSString
        return re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) != nil
    }
}

// MARK: - Transcript page

/// The `/messages` page payload: the (possibly partial) message tail plus the
/// session's live state so the chat header chip stays fresh without a second
/// poll. `source` is `live|cache` (informational).
struct CodingChatPage: Equatable {
    let messages: [CodingChatMessage]
    let total: Int
    /// working | waiting | idle | nil
    let activityState: String?
    let status: String
    let source: String?
    /// Live spinner line while working, e.g. "✳ Zesting… (50s · ↑ 2.0k tokens)".
    let statusLine: String?
    /// Context-window gauge, or nil if the transcript has no usage yet.
    let context: ChatContext?

    init(messages: [CodingChatMessage] = [], total: Int = 0, activityState: String? = nil,
         status: String = "", source: String? = nil, statusLine: String? = nil,
         context: ChatContext? = nil) {
        self.messages = messages
        self.total = total
        self.activityState = activityState
        self.status = status
        self.source = source
        self.statusLine = statusLine
        self.context = context
    }

    init(json j: [String: Any]) {
        self.init(
            messages: CodingJSON.maps(j["messages"]).map(CodingChatMessage.init(json:)),
            total: CodingJSON.int(j["total"]),
            activityState: CodingJSON.str(j["activity_state"]),
            status: CodingJSON.text(j["status"]),
            source: CodingJSON.str(j["source"]),
            statusLine: CodingJSON.str(j["status_line"]),
            context: ChatContext.from(j["context"]))
    }
}

// MARK: - Interactive prompt

/// One selectable option in an interactive prompt (`{key:'1', label:'Yes'}`).
/// Answering sends just `key` to the PTY — no newline.
struct CodingPromptOption: Identifiable, Equatable {
    let key: String
    let label: String

    var id: String { key }

    init(key: String, label: String) {
        self.key = key
        self.label = label
    }

    init(json j: [String: Any]) {
        self.init(key: CodingJSON.text(j["key"]), label: CodingJSON.text(j["label"]))
    }
}

/// The `/prompt` payload — what Claude is currently asking in the pane (when
/// `activity_state == waiting`). `raw` is the pane tail, shown monospace when no
/// structured options were detected.
struct CodingPromptState: Equatable {
    let waiting: Bool
    let question: String?
    let options: [CodingPromptOption]
    let raw: String?

    init(waiting: Bool = false, question: String? = nil,
         options: [CodingPromptOption] = [], raw: String? = nil) {
        self.waiting = waiting
        self.question = question
        self.options = options
        self.raw = raw
    }

    init(json j: [String: Any]) {
        self.init(
            waiting: CodingJSON.bool(j["waiting"]),
            question: CodingJSON.str(j["question"]),
            options: CodingJSON.maps(j["options"]).map(CodingPromptOption.init(json:)),
            raw: CodingJSON.str(j["raw"]))
    }

    /// A stable identity for "the same prompt" so a dismissed sheet isn't
    /// re-popped on the next poll tick.
    var signature: String {
        "\(question ?? "")|\(options.map(\.key).joined(separator: ","))|\(raw ?? "")"
    }
}

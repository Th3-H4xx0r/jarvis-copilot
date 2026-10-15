import Foundation

// A session's conversation as the session screen draws it — your prompts, the
// agent's text, one-line tool rows, file-edit cards — built from either the
// full Claude Code transcript (`/api/coding/session/<id>/messages`) or the
// agent's own record of its last turn (`/api/coding/agents/session`). Pure, so
// both sources read the same and the rules are unit tested.

// MARK: - Tool lines

/// "Read app.ts", "Ran npm test": a verb and what it acted on.
struct AgentToolLine: Equatable {
    let verb: String
    let object: String
    let symbol: String
    /// Commands and patterns read best in monospace; file names don't.
    let monospaced: Bool

    var text: String {
        object.isEmpty ? verb.trimmingCharacters(in: CharacterSet(charactersIn: ":")) : "\(verb) \(object)"
    }
}

enum AgentToolPhrase {
    enum Tense { case past, progressive, imperative }

    private enum Object { case file, line, host, none, raw }

    private struct Verbs {
        let imperative: String
        let progressive: String
        let past: String
        let symbol: String
        let monospaced: Bool
        let object: Object

        func verb(_ tense: Tense) -> String {
            switch tense {
            case .past: return past
            case .progressive: return progressive
            case .imperative: return imperative
            }
        }
    }

    private static func verbs(_ tool: String) -> Verbs {
        switch tool {
        case "Bash", "BashOutput":
            return Verbs(imperative: "run", progressive: "Running", past: "Ran",
                         symbol: "terminal", monospaced: true, object: .line)
        case "Read", "NotebookRead":
            return Verbs(imperative: "read", progressive: "Reading", past: "Read",
                         symbol: "doc.text", monospaced: false, object: .file)
        case "Edit", "MultiEdit", "NotebookEdit":
            return Verbs(imperative: "edit", progressive: "Editing", past: "Edited",
                         symbol: "pencil", monospaced: false, object: .file)
        case "Write":
            return Verbs(imperative: "write", progressive: "Writing", past: "Wrote",
                         symbol: "square.and.pencil", monospaced: false, object: .file)
        case "Grep":
            return Verbs(imperative: "search for", progressive: "Searching for", past: "Searched for",
                         symbol: "magnifyingglass", monospaced: true, object: .line)
        case "Glob":
            return Verbs(imperative: "find files", progressive: "Finding files", past: "Found files",
                         symbol: "magnifyingglass", monospaced: true, object: .line)
        case "WebSearch":
            return Verbs(imperative: "search the web for", progressive: "Searching the web for",
                         past: "Searched the web for", symbol: "magnifyingglass", monospaced: false, object: .line)
        case "WebFetch":
            return Verbs(imperative: "fetch", progressive: "Fetching", past: "Fetched",
                         symbol: "arrow.down.circle", monospaced: false, object: .host)
        case "Task", "Agent":
            return Verbs(imperative: "start an agent:", progressive: "Running an agent:", past: "Ran an agent:",
                         symbol: "point.3.filled.connected.trianglepath.dotted", monospaced: false, object: .line)
        case "TodoWrite":
            return Verbs(imperative: "update the plan", progressive: "Updating the plan", past: "Updated the plan",
                         symbol: "text.alignleft", monospaced: false, object: .none)
        case "ExitPlanMode":
            return Verbs(imperative: "propose a plan", progressive: "Proposing a plan", past: "Proposed a plan",
                         symbol: "text.alignleft", monospaced: false, object: .none)
        case "AskUserQuestion":
            return Verbs(imperative: "ask", progressive: "Asking", past: "Asked",
                         symbol: "questionmark.circle", monospaced: false, object: .line)
        default:
            return Verbs(imperative: "use", progressive: "Using", past: "Used",
                         symbol: tool.hasPrefix("mcp__") ? "cpu" : "gearshape", monospaced: false, object: .raw)
        }
    }

    /// The part of a summary after the tool's own name: the hooks write
    /// "Bash: npm test", the transcript just "npm test".
    static func detail(tool: String, summary: String) -> String {
        let s = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["\(tool):", "\(tool) "] where s.hasPrefix(prefix) {
            return String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }

    static func line(tool: String, summary: String, tense: Tense = .past) -> AgentToolLine {
        let v = verbs(tool)
        let detail = detail(tool: tool, summary: summary)
        let object: String
        switch v.object {
        case .file:
            let base = CodingJSON.basename(detail)
            object = base.isEmpty ? AgentsPresentation.firstLine(detail) : base
        case .line:
            object = AgentsPresentation.firstLine(detail, limit: 120)
        case .host:
            object = URLComponents(string: detail)?.host ?? AgentsPresentation.firstLine(detail, limit: 120)
        case .none:
            object = ""
        case .raw:
            object = [name(of: tool), AgentsPresentation.firstLine(detail, limit: 120)]
                .filter { !$0.isEmpty }.joined(separator: " ")
        }
        return AgentToolLine(verb: v.verb(tense), object: object, symbol: v.symbol, monospaced: v.monospaced)
    }

    /// "mcp__github__search_issues" → "github search issues"; anything else as is.
    private static func name(of tool: String) -> String {
        guard tool.hasPrefix("mcp__") else { return tool }
        return tool.dropFirst(5).components(separatedBy: "__")
            .map { $0.replacingOccurrences(of: "_", with: " ") }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    private enum Kind: Hashable { case read, command, edit, search, web, agent, plan, other }

    private static func kind(_ tool: String) -> Kind {
        switch tool {
        case "Read", "NotebookRead": return .read
        case "Bash", "BashOutput", "KillShell": return .command
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return .edit
        case "Grep", "Glob", "WebSearch", "ToolSearch": return .search
        case "WebFetch": return .web
        case "Task", "Agent": return .agent
        case "TodoWrite", "ExitPlanMode": return .plan
        default: return .other
        }
    }

    private static func phrase(_ kind: Kind, _ n: Int) -> String {
        func count(_ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
        switch kind {
        case .read: return "read " + count("file", "files")
        case .command: return "ran " + count("command", "commands")
        case .edit: return "edited " + count("file", "files")
        case .search: return "ran " + count("search", "searches")
        case .web: return "fetched " + count("page", "pages")
        case .agent: return "ran " + count("agent", "agents")
        case .plan: return "updated the plan"
        case .other: return "used " + count("tool", "tools")
        }
    }

    /// "Read 3 files, ran 2 commands" for a collapsed run of tool rows: the
    /// first three kinds in the order they came, then how many steps are left.
    static func groupSummary(_ tools: [String]) -> String {
        var order: [Kind] = []
        var counts: [Kind: Int] = [:]
        for tool in tools {
            let k = kind(tool)
            if !order.contains(k) { order.append(k) }
            counts[k, default: 0] += 1
        }
        let shown = order.prefix(3)
        var text = shown.map { phrase($0, counts[$0] ?? 0) }.joined(separator: ", ")
        let rest = order.dropFirst(3).reduce(0) { $0 + (counts[$1] ?? 0) }
        if rest > 0 { text += " and \(rest) more" }
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}

// MARK: - Items

struct AgentToolItem: Equatable {
    let tool: String
    let line: AgentToolLine
    let output: String
    let failed: Bool
    let running: Bool
}

/// One file the agent changed, with its diff.
struct AgentFileEdit: Equatable {
    let path: String
    let added: Int
    let removed: Int
    let isNew: Bool
    let truncated: Bool
    let lines: [AgentDiffLine]

    var name: String { CodingJSON.basename(path).isEmpty ? path : CodingJSON.basename(path) }

    init(path: String, added: Int, removed: Int, isNew: Bool, truncated: Bool, lines: [AgentDiffLine]) {
        self.path = path
        self.added = added
        self.removed = removed
        self.isNew = isNew
        self.truncated = truncated
        self.lines = lines
    }

    init(_ diff: AgentFileDiff) {
        self.init(path: diff.path, added: diff.added, removed: diff.removed, isNew: diff.isNew,
                  truncated: diff.truncated, lines: diff.lines)
    }

    /// A transcript tool's unified diff ("+x", "-y", " z", "@@", "… +12 more lines").
    init(tool: CodingChatTool) {
        var lines: [AgentDiffLine] = []
        var added = 0, removed = 0
        var truncated = false
        for raw in tool.diff {
            if raw.hasPrefix("…") {
                truncated = true
                // A Write's "… +40 more lines" still counts toward its total.
                if let tail = raw.split(separator: "+").last?.split(separator: " ").first, raw.contains("+"),
                   let n = Int(tail) {
                    added += n
                }
            } else if raw.hasPrefix("@@") {
                lines.append(AgentDiffLine(kind: .gap, text: ""))
            } else if raw.hasPrefix("+") {
                added += 1
                lines.append(AgentDiffLine(kind: .added, text: String(raw.dropFirst())))
            } else if raw.hasPrefix("-") {
                removed += 1
                lines.append(AgentDiffLine(kind: .removed, text: String(raw.dropFirst())))
            } else {
                lines.append(AgentDiffLine(kind: .context, text: raw.hasPrefix(" ") ? String(raw.dropFirst()) : raw))
            }
        }
        self.init(path: tool.summary, added: added, removed: removed, isNew: tool.name == "Write",
                  truncated: truncated, lines: lines)
    }
}

enum AgentConversationItem: Identifiable, Equatable {
    case prompt(id: String, text: String)
    case text(id: String, text: String)
    case tool(id: String, AgentToolItem)
    /// A long run of tool rows folded into one summary row.
    case tools(id: String, summary: String, [AgentToolItem])
    case edit(id: String, AgentFileEdit)

    var id: String {
        switch self {
        case .prompt(let id, _), .text(let id, _), .tool(let id, _), .tools(let id, _, _), .edit(let id, _):
            return id
        }
    }
}

enum AgentConversation {
    /// Runs of this many tool rows or more fold into one.
    static let collapseThreshold = 4

    /// The transcript: every prompt, then each assistant message's tools (file
    /// edits as cards) and its text. The server merges an assistant turn's
    /// blocks into one message, so its tools come before its words.
    static func items(_ messages: [CodingChatMessage], working: Bool) -> [AgentConversationItem] {
        var out: [AgentConversationItem] = []
        let lastIndex = messages.last?.i
        for m in messages {
            if m.isUser {
                let text = trim(m.text)
                if !text.isEmpty { out.append(.prompt(id: "m\(m.i)", text: text)) }
                continue
            }
            // Only the newest message's open tools are really still running.
            let live = working && m.i == lastIndex
            for t in m.tools {
                let id = "m\(m.i)-t\(t.id)"
                if !t.diff.isEmpty {
                    out.append(.edit(id: id, AgentFileEdit(tool: t)))
                } else {
                    let running = live && t.running
                    out.append(.tool(id: id, AgentToolItem(
                        tool: t.name,
                        line: AgentToolPhrase.line(tool: t.name, summary: t.summary,
                                                   tense: running ? .progressive : .past),
                        output: t.output, failed: !t.ok, running: running)))
                }
            }
            let text = trim(m.text)
            if !text.isEmpty { out.append(.text(id: "m\(m.i)-x", text: text)) }
        }
        return out
    }

    /// The last turn from the hooks: the prompt, each action (an edit becomes
    /// its file's card, once, where the file was first touched), any file no
    /// action pointed at, then the answer.
    static func items(_ turn: AgentTurn, working: Bool) -> [AgentConversationItem] {
        var out: [AgentConversationItem] = []
        let prompt = trim(turn.prompt)
        if !prompt.isEmpty { out.append(.prompt(id: "prompt", text: prompt)) }
        var shown = Set<Int>()
        let last = turn.actions.last?.index
        for a in turn.actions {
            if let f = a.fileIndex, f >= 0, f < turn.files.count {
                if shown.insert(f).inserted { out.append(.edit(id: "file\(f)", AgentFileEdit(turn.files[f]))) }
                continue
            }
            let running = working && a.index == last && a.output.isEmpty && !a.failed
            out.append(.tool(id: "a\(a.index)", AgentToolItem(
                tool: a.tool,
                line: AgentToolPhrase.line(tool: a.tool, summary: a.summary, tense: running ? .progressive : .past),
                output: a.output, failed: a.failed, running: running)))
        }
        for (i, file) in turn.files.enumerated() where !shown.contains(i) {
            out.append(.edit(id: "file\(i)", AgentFileEdit(file)))
        }
        let final = trim(turn.final)
        if !final.isEmpty { out.append(.text(id: "final", text: final)) }
        return out
    }

    /// Folds every run of `threshold` or more tool rows into one summary row.
    /// A tool still running stays outside, so what's happening now is visible.
    static func collapse(_ items: [AgentConversationItem],
                         threshold: Int = collapseThreshold) -> [AgentConversationItem] {
        var out: [AgentConversationItem] = []
        var run: [(id: String, item: AgentToolItem)] = []

        func flush() {
            var tail: [(id: String, item: AgentToolItem)] = []
            if let last = run.last, last.item.running { tail = [run.removeLast()] }
            if run.count >= threshold, let first = run.first, let end = run.last {
                out.append(.tools(id: "\(first.id)…\(end.id)",
                                  summary: AgentToolPhrase.groupSummary(run.map(\.item.tool)),
                                  run.map(\.item)))
            } else {
                out += run.map { .tool(id: $0.id, $0.item) }
            }
            out += tail.map { .tool(id: $0.id, $0.item) }
            run = []
        }

        for item in items {
            if case .tool(let id, let tool) = item {
                run.append((id, tool))
            } else {
                flush()
                out.append(item)
            }
        }
        flush()
        return out
    }

    /// A running tool row already spins and says what it runs, so the
    /// screen's "working" row would only repeat it underneath.
    static func endsInRunningTool(_ items: [AgentConversationItem]) -> Bool {
        if case .tool(_, let tool) = items.last { return tool.running }
        return false
    }

    /// The prompts the conversation shows, to tell when a sent instruction landed.
    static func prompts(_ items: [AgentConversationItem]) -> [String] {
        items.compactMap { if case .prompt(_, let text) = $0 { return text } else { return nil } }
    }

    private static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension AgentTurn {
    /// Nothing to draw: no prompt, no steps, no files, no answer.
    var isEmpty: Bool {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && actions.isEmpty && files.isEmpty
            && final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

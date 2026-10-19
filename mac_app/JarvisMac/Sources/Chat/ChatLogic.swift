import Foundation
import UniformTypeIdentifiers

/// `text/event-stream` from the server's `/api/chat/stream` (the same frames
/// the iPhone reads: token/delta/text, tool, tool_complete, approval, clarify,
/// done, cancel…).
struct ChatSSE {
    struct Event: Equatable {
        let name: String
        /// The frame's top-level strings and numbers.
        let object: [String: String]
        /// The whole frame (tool arguments, choices, the done frame's session).
        var json: [String: Any] = [:]

        static func == (a: Event, b: Event) -> Bool { a.name == b.name && a.object == b.object }

        var token: String? {
            guard ["token", "delta", "text"].contains(name) else { return nil }
            let t = object["text"] ?? object["delta"] ?? object["content"] ?? ""
            return t.isEmpty ? nil : t
        }
        var toolName: String? { ["tool", "tool_start", "tool_call"].contains(name) ? object["name"] : nil }
        /// The server ends a turn with done/stream_end, error/apperror or `cancel`.
        var isEnd: Bool { ["done", "stream_end", "complete", "error", "apperror", "cancel", "cancelled"].contains(name) }
        var isCancel: Bool { name == "cancel" || name == "cancelled" }
        var error: String? {
            guard name == "error" || name == "apperror" else { return nil }
            return object["message"] ?? object["error"] ?? "The chat failed."
        }
        /// The turn's id (the first `chat_start` frame carries it) — Stop needs it.
        var streamID: String? { object["stream_id"].flatMap { $0.isEmpty ? nil : $0 } }
        var approval: ChatApproval? { name == "approval" ? ChatApproval(json: json) : nil }
        var clarify: ChatClarify? { name == "clarify" ? ChatClarify(json: json) : nil }
    }

    private var event = "message"
    private var data: [String] = []

    mutating func feed(_ line: String) -> Event? {
        if line.isEmpty {
            defer { event = "message"; data.removeAll() }
            return flush()
        }
        if line.hasPrefix(":") { return nil }
        if line.hasPrefix("event:") {
            event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("data:") {
            var d = String(line.dropFirst(5))
            if d.hasPrefix(" ") { d.removeFirst() }
            data.append(d)
        }
        return nil
    }

    mutating func finish() -> Event? {
        defer { data.removeAll() }
        return flush()
    }

    private func flush() -> Event? {
        guard !data.isEmpty else { return nil }
        let raw = data.joined(separator: "\n")
        var obj: [String: String] = [:]
        var json: [String: Any] = [:]
        if let d = raw.data(using: .utf8), let parsed = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            json = parsed
            for (k, v) in parsed {
                if let s = v as? String { obj[k] = s } else if let n = v as? NSNumber { obj[k] = n.stringValue }
            }
        } else {
            obj["text"] = raw
        }
        return Event(name: obj["event"] ?? event, object: obj, json: json)
    }
}

// MARK: - A turn

/// One tool call in a reply: the phone's tool row (name without its `device_`
/// prefix, one grey line, the time it took, Arguments / Result when opened).
struct ChatTool: Identifiable, Equatable {
    let id = UUID()
    var name: String
    /// The arguments, pretty-printed (empty when there were none).
    var args = ""
    /// One short line of the arguments: the first three keys.
    var argsLine = ""
    var preview: String?
    var result: String?
    var done = false
    var isError = false
    var duration: Double?

    var shortName: String { name.hasPrefix("device_") ? String(name.dropFirst("device_".count)) : name }

    /// The one line a closed row shows: the result once there is one, else
    /// the server's preview, else the arguments.
    var detailLine: String {
        let pick: String
        if done, let result, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pick = result
        } else if let preview, !preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pick = preview
        } else {
            pick = argsLine
        }
        let trimmed = pick.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.split(separator: "\n").first.map(String.init) ?? ""
    }

    var hasDetail: Bool { !args.isEmpty || !(result ?? "").isEmpty || !(preview ?? "").isEmpty }

    var durationText: String? {
        guard let d = duration, d >= 0 else { return nil }
        return d < 10 ? String(format: "%.1fs", d) : "\(Int(d))s"
    }
}

enum ChatToolArgs {
    /// `tool_call {name, arguments}` (the lazy-tools bridge) as the tool it ran.
    static func unwrap(name: String, args: [String: Any]) -> (String, [String: Any]) {
        guard name == "tool_call", let inner = args["name"] as? String, !inner.isEmpty else { return (name, args) }
        if let a = args["arguments"] as? [String: Any] { return (inner, a) }
        if let s = args["arguments"] as? String, let d = s.data(using: .utf8),
           let a = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { return (inner, a) }
        return (inner, [:])
    }

    static func pretty(_ args: [String: Any]) -> String {
        guard !args.isEmpty, JSONSerialization.isValidJSONObject(args),
              let d = try? JSONSerialization.data(withJSONObject: args, options: [.prettyPrinted, .sortedKeys])
        else { return "" }
        return String(decoding: d, as: UTF8.self)
    }

    /// The phone's preview line: the first three keys, values clipped.
    static func previewLine(_ args: [String: Any]) -> String {
        args.keys.sorted().prefix(3).map { key in
            var text = display(args[key])
            if text.count > 40 { text = text.prefix(39) + "…" }
            return "\(key): \(text)"
        }.joined(separator: " · ")
    }

    static func display(_ value: Any?) -> String {
        switch value {
        case nil, is NSNull: return "null"
        case let s as String: return s
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        case let v?:
            if JSONSerialization.isValidJSONObject(v),
               let d = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys]) {
                return String(decoding: d, as: UTF8.self)
            }
            return "\(v)"
        }
    }
}

/// What a reply shows: its tools (one box), its text, and how it ended.
struct ChatTurn: Equatable {
    var text = ""
    var tools: [ChatTool] = []
    var streaming = false
    /// You pressed Stop (or the server cancelled): a muted "Stopped".
    var stopped = false
    var error: String?
    /// A muted line under the reply ("No reply", why the server stopped).
    var note: String?
    /// The model's thought process, when the stream carries one.
    var reasoning = ""
    /// Tokens in / out and the time it took.
    var stats: ChatTurnStats?
    /// Who answered: the model, its route, a hand-off.
    var meta: HarnessMeta?

    var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var hasReasoning: Bool { !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var hasOutput: Bool { hasText || !tools.isEmpty }
    /// The three dots: still working, nothing said, no tool spinning, not thinking out loud.
    var showsDots: Bool { streaming && !hasText && !hasReasoning && !tools.contains { !$0.done } }

    /// The quiet line under a settled reply, the phone's footer: who answered,
    /// then the numbers — "Claude Opus 5.5 · 3.2 s · routed deep 82% · 40.2k in
    /// (98% cached) · 12 out". Empty while it streams (half-counted numbers
    /// flickering under a reply are noise).
    var footer: String {
        guard !streaming else { return "" }
        let by = HarnessFormat.answeredBy(meta)
        // The harness's time is the turn's; the stats say theirs only without it.
        let timed = !by.isEmpty && (meta?.ms ?? 0) > 0
        return [by, stats?.line(time: !timed) ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// What the server stored with the reply fills in what the stream didn't say.
    mutating func fill(from record: ChatReplyRecord) {
        if meta == nil { meta = record.meta }
        if let stored = record.stats {
            var s = stats ?? ChatTurnStats()
            if !s.hasTokens {
                s.inputTokens = stored.inputTokens
                s.cachedTokens = stored.cachedTokens
                s.outputTokens = stored.outputTokens
                s.estimated = stored.estimated
            }
            if s.durationMs == nil { s.durationMs = stored.durationMs }
            stats = s
        }
        if !hasReasoning { reasoning = record.reasoning }
    }

    mutating func startTool(name: String, args: [String: Any], preview: String?) {
        let (name, args) = ChatToolArgs.unwrap(name: name, args: args)
        tools.append(ChatTool(name: name, args: ChatToolArgs.pretty(args), argsLine: ChatToolArgs.previewLine(args),
                              preview: preview.flatMap { $0.isEmpty ? nil : $0 }))
    }

    /// Close the latest open call with that name (any name when nil).
    mutating func completeTool(name: String?, duration: Double?, isError: Bool, preview: String?, result: String?) {
        guard let i = tools.indices.reversed().first(where: {
            !tools[$0].done && (name == nil || name!.isEmpty || tools[$0].name == name)
        }) else { return }
        tools[i].done = true
        tools[i].isError = isError
        if let duration { tools[i].duration = duration }
        if let preview, !preview.isEmpty { tools[i].preview = preview }
        if let result, !result.isEmpty { tools[i].result = result }
    }

    /// The head of a finished call's result (tool_snippet): fills it in, never closes it.
    @discardableResult
    mutating func fillResult(name: String?, result: String) -> Bool {
        guard let i = tools.indices.reversed().first(where: {
            (name == nil || tools[$0].name == name) && (tools[$0].result ?? "").isEmpty
        }) else { return false }
        tools[i].result = result
        return true
    }

    /// Over: nothing may keep spinning.
    mutating func finish() {
        streaming = false
        for i in tools.indices where !tools[i].done { tools[i].done = true }
    }
}

/// One streaming turn folded from its frames. Pure, so every frame shape is
/// tested without a socket (the phone's ChatStreamReducer).
struct ChatStreamState: Equatable {
    enum End: Equatable { case done, cancelled, failed }

    var turn = ChatTurn(streaming: true)
    var streamID: String?
    var approval: ChatApproval?
    var clarify: ChatClarify?
    var end: End?
    /// When you sent it: the footer's time.
    var startedAt = Date()

    /// True when something you can see changed.
    @discardableResult
    mutating func apply(_ e: ChatSSE.Event, now: Date = Date()) -> Bool {
        if let id = e.streamID { streamID = id }
        let o = e.object
        switch e.name {
        case "token", "delta", "text":
            guard let t = e.token else { return false }
            turn.text += t
            return true

        case "reasoning", "thinking":
            let t = o["text"] ?? o["delta"] ?? ""
            guard !t.isEmpty else { return false }
            turn.reasoning += t
            return true

        case "turn_meta":
            // Only the closing frame carries the final numbers (time, hand-off).
            guard o["phase"] == "end", let meta = HarnessMeta(json: e.json), meta != turn.meta else { return false }
            turn.meta = meta
            return true

        case "metering", "usage":
            // Every second while a turn runs; only this turn's own numbers count
            // (the outer ones are the session's), so it rarely changes anything.
            var stats = turn.stats ?? ChatTurnStats()
            guard stats.absorb(usage: e.json, turnOnly: true) else { return false }
            turn.stats = stats
            return true

        case "interim_assistant":
            // Words between tool rounds; only when nothing streamed (else they print twice).
            guard e.json["already_streamed"] as? Bool != true, !turn.hasText,
                  let t = o["text"], !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            turn.text += t
            return true

        case "tool", "tool_start", "tool_call":
            let name = o["name"] ?? "tool"
            guard name != "clarify" else { return false }  // a question, not a row
            turn.startTool(name: name, args: (e.json["args"] ?? e.json["input"]) as? [String: Any] ?? [:],
                           preview: o["preview"])
            return true

        case "tool_snippet":
            guard let s = o["snippet"], !s.isEmpty, o["name"] != "clarify" else { return false }
            return turn.fillResult(name: o["name"].flatMap { $0.isEmpty ? nil : $0 }, result: s)

        case "tool_complete", "tool_end", "tool_result":
            guard o["name"] != "clarify" else { return false }
            turn.completeTool(name: o["name"], duration: Double(o["duration"] ?? o["duration_sec"] ?? ""),
                              isError: e.json["is_error"] as? Bool == true, preview: o["preview"],
                              result: o["result"] ?? o["snippet"] ?? o["output"])
            return true

        case "approval":
            guard let a = e.approval, a != approval else { return false }
            approval = a
            return true

        case "clarify":
            guard let c = e.clarify, c != clarify else { return false }
            clarify = c
            return true

        case "error", "apperror":
            turn.error = e.error
            close(.failed, now: now)
            return true

        case "cancel", "cancelled":
            turn.stopped = true
            let why = (o["message"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !why.isEmpty, !why.lowercased().hasPrefix("cancelled") { turn.note = why }
            close(.cancelled, now: now)
            return true

        case "done", "stream_end", "complete":
            var stats = turn.stats ?? ChatTurnStats()
            if stats.absorb(usage: e.json) { turn.stats = stats }
            let session = e.json["session"] as? [String: Any] ?? [:]
            let messages = session["messages"] as? [[String: Any]] ?? []
            if !turn.hasText {
                // Some engines stream nothing and send the answer only here.
                let stored = ChatSnapshot.lastAssistantText(in: messages)
                if let t = o["answer"] ?? stored, !t.isEmpty { turn.text = t }
            }
            if let record = ChatReplyRecord(messages: messages) { turn.fill(from: record) }
            close(.done, now: now)
            return true

        default:
            return false  // title, keep-alives…: alive, nothing to draw
        }
    }

    private mutating func close(_ how: End, now: Date = Date()) {
        if end == nil { end = how }
        approval = nil
        clarify = nil
        stamp(now: now)
        turn.finish()
    }

    /// The time it took, from Send to now, unless it's already known.
    mutating func stamp(now: Date = Date()) {
        guard turn.stats?.durationMs == nil else { return }
        var stats = turn.stats ?? ChatTurnStats()
        stats.durationMs = max(0, Int((now.timeIntervalSince(startedAt) * 1_000).rounded()))
        turn.stats = stats
    }
}

/// `GET /api/session`: is a turn still running, and what did the last one say.
struct ChatSnapshot: Equatable {
    let activeStreamID: String?
    let lastAssistantText: String?
    /// Who answered it and its numbers, as stored.
    let lastRecord: ChatReplyRecord?

    init(json: [String: Any]) {
        let s = json["session"] as? [String: Any] ?? json
        activeStreamID = (s["active_stream_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let messages = s["messages"] as? [[String: Any]] ?? []
        lastAssistantText = Self.lastAssistantText(in: messages)
        lastRecord = ChatReplyRecord(messages: messages)
    }

    /// The reply after the last thing you said — never an older turn's.
    static func lastAssistantText(in messages: [[String: Any]]) -> String? {
        for m in messages.reversed() {
            let role = m["role"] as? String
            if role == "user" { return nil }
            guard role == "assistant" else { continue }
            var text = m["content"] as? String ?? ""
            if text.isEmpty, let parts = m["content"] as? [[String: Any]] {
                text = parts.compactMap { $0["text"] as? String }.joined()
            }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        }
        return nil
    }
}

/// A live stream that has gone quiet: the server sends metering every second
/// while a turn runs, so 45 s of nothing means the socket died quietly — unless
/// Jarvis is waiting on you (an approval or a question).
enum ChatStall {
    static let idleLimit: TimeInterval = 45

    static func isStalled(lastEvent: Date, now: Date, waitingOnYou: Bool, limit: TimeInterval = idleLimit) -> Bool {
        !waitingOnYou && now.timeIntervalSince(lastEvent) > limit
    }
}

// MARK: - Approvals and questions

/// A command Jarvis wants to run that needs your yes (the chat runs with
/// approvals on). Answered at `/api/approval/respond`, like the web UI.
struct ChatApproval: Equatable {
    enum Choice: String, CaseIterable { case once, session, always, deny }

    let command: String
    let description: String
    let id: String?
    /// A text, call, email or message about to go out (`kind: "send"`): drawn
    /// as the person and the message with Send (Call) and Cancel.
    let send: ChatSend?

    init(command: String, description: String, id: String? = nil, send: ChatSend? = nil) {
        self.command = command
        self.description = description
        self.id = id
        self.send = send
    }

    init?(json: [String: Any]) {
        let p = json["pending"] as? [String: Any] ?? json
        command = (p["command"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        description = (p["description"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        id = (p["approval_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        send = p["kind"] as? String == "send" ? ChatSend(json: p["send"] as? [String: Any]) : nil
        guard !command.isEmpty || !description.isEmpty || send != nil else { return nil }
    }

    static func respondBody(session: String, choice: Choice, approvalID: String?) -> [String: Any] {
        var body: [String: Any] = ["session_id": session, "choice": choice.rawValue]
        if let approvalID { body["approval_id"] = approvalID }
        return body
    }
}

/// Who Jarvis is about to text, call, email or message, and what it says —
/// the server pauses the turn on it (agent/send_confirm.py). Send (Call)
/// answers the approval "once" and it goes; Cancel answers "deny". Worded like
/// the phone's card (SendConfirmations.Card).
struct ChatSend: Equatable {
    enum Kind: String { case call, text, email, message }

    let kind: Kind
    /// The number or address.
    let to: String
    /// The contact's full name, or "".
    let name: String
    /// The contact's photo as a `data:` URL, or "".
    let photo: String
    let text: String
    let subject: String
    /// What it goes through: "iPhone", "Mac", "WhatsApp", "FaceTime"…
    let via: String

    init(kind: Kind, to: String, name: String = "", photo: String = "", text: String = "", subject: String = "",
         via: String = "") {
        self.kind = kind
        self.to = to
        self.name = name
        self.photo = photo
        self.text = text
        self.subject = subject
        self.via = via
    }

    init?(json: [String: Any]?) {
        guard let json else { return nil }
        func field(_ key: String) -> String { (json[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let to = field("to"), name = field("name")
        guard !to.isEmpty || !name.isEmpty else { return nil }
        self.init(kind: Kind(rawValue: field("kind").lowercased()) ?? .message, to: to, name: name,
                  photo: field("photo"), text: field("text"), subject: field("subject"), via: field("via"))
    }

    /// The person: their name, else the number or address.
    var title: String { name.isEmpty ? to : name }

    /// "Text · +1 555…" under a name; with only a handle (already the title)
    /// what goes and how: "Text · iPhone".
    var subtitle: String {
        let what: String
        switch kind {
        case .call: what = via == "FaceTime" ? "FaceTime" : "Call"
        case .text: what = "Text"
        case .email: what = "Email"
        // "whatsapp" → "Whatsapp"; a name with its own capitals ("WhatsApp") as is.
        case .message: what = via.isEmpty ? "Message" : via.contains(where: \.isUppercase) ? via : via.capitalized
        }
        if !name.isEmpty, !to.isEmpty { return "\(what) · \(to)" }
        let shown = via.isEmpty || what.lowercased() == via.lowercased() ? "" : " · \(via)"
        return what + shown
    }

    var actionTitle: String { kind == .call ? "Call" : "Send" }

    var actionSymbol: String {
        switch kind {
        case .call: return "phone.fill"
        case .email: return "envelope.fill"
        case .text, .message: return "paperplane.fill"
        }
    }

    /// "JA" for Jane Appleseed; "" without a name (the card draws a person).
    var initials: String {
        String(name.split(separator: " ").prefix(2).compactMap { $0.first(where: \.isLetter) }).uppercased()
    }
}

/// A question Jarvis asks mid-turn (its `clarify` tool); the answer goes to
/// `/api/clarify/respond`, as the phone sends it, and the turn carries on.
struct ChatClarify: Equatable {
    let question: String
    let choices: [String]

    init(question: String, choices: [String] = []) {
        self.question = question
        self.choices = choices
    }

    init?(json: [String: Any]) {
        question = (json["question"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        choices = (json["choices_offered"] as? [Any] ?? json["choices"] as? [Any] ?? []).map { "\($0)" }
        guard !question.isEmpty else { return nil }
    }

    static func respondBody(session: String, answer: String) -> [String: Any] {
        ["session_id": session, "response": answer]
    }
}

// MARK: - What answers

/// Who answers the island's Jarvis chat (Settings → General → Island chat),
/// sent with every `/api/chat/start` the way the phone sends it.
enum ChatRunChoice: Equatable, Hashable {
    /// The chat's harness, else the Chat default (`harness_id: ""`).
    case chatDefault
    case harness(id: String, name: String)
    /// "Single model": `harness_id: "single"` plus the model and its provider.
    case model(id: String, label: String, provider: String)

    var harnessID: String {
        switch self {
        case .chatDefault: return ""
        case .harness(let id, _): return id
        case .model: return "single"
        }
    }

    /// What the island's chip says.
    var label: String {
        switch self {
        case .chatDefault: return "Jarvis"
        case .harness(_, let name): return name
        case .model(let id, let label, _): return label.isEmpty ? id : label
        }
    }

    var symbol: String? {
        switch self {
        case .chatDefault: return nil
        case .harness: return "flowchart"
        case .model: return "sparkles"
        }
    }

    func apply(to body: inout [String: Any]) {
        // Present-but-empty means "follow the Chat default"; the server treats a
        // missing key as an app that predates harnesses.
        body["harness_id"] = harnessID
        if case .model(let id, _, let provider) = self {
            body["model"] = id
            if !provider.isEmpty { body["model_provider"] = provider }
        }
    }

    private static let kindKey = "chat.run.kind", idKey = "chat.run.id", nameKey = "chat.run.name",
                       providerKey = "chat.run.provider"

    static func load(_ d: UserDefaults = .standard) -> ChatRunChoice {
        let id = d.string(forKey: idKey) ?? "", name = d.string(forKey: nameKey) ?? ""
        switch d.string(forKey: kindKey) {
        case "harness" where !id.isEmpty: return .harness(id: id, name: name.isEmpty ? id : name)
        case "model" where !id.isEmpty: return .model(id: id, label: name, provider: d.string(forKey: providerKey) ?? "")
        default: return .chatDefault
        }
    }

    func save(_ d: UserDefaults = .standard) {
        switch self {
        case .chatDefault:
            d.set("default", forKey: Self.kindKey)
            for k in [Self.idKey, Self.nameKey, Self.providerKey] { d.removeObject(forKey: k) }
        case .harness(let id, let name):
            d.set("harness", forKey: Self.kindKey); d.set(id, forKey: Self.idKey); d.set(name, forKey: Self.nameKey)
            d.removeObject(forKey: Self.providerKey)
        case .model(let id, let label, let provider):
            d.set("model", forKey: Self.kindKey); d.set(id, forKey: Self.idKey); d.set(label, forKey: Self.nameKey)
            d.set(provider, forKey: Self.providerKey)
        }
    }
}

enum ChatRequest {
    /// `POST /api/chat/start` — the phone's body (ChatAPI.startBody).
    static func startBody(session: String, message: String, attachments: [[String: Any]],
                          choice: ChatRunChoice) -> [String: Any] {
        var body: [String: Any] = ["session_id": session, "message": message]
        if !attachments.isEmpty { body["attachments"] = attachments }
        choice.apply(to: &body)
        return body
    }
}

/// A model the server offers (`GET /api/models`).
struct ChatModelOption: Identifiable, Hashable {
    let id: String
    let label: String
    /// The provider's name, for the picker's sections.
    let provider: String
    /// The id the server routes on, sent as `model_provider`.
    let providerID: String

    var choice: ChatRunChoice { .model(id: id, label: label, provider: providerID) }
}

/// A harness (`GET /api/harnesses`), Single left out (it's the model choice).
struct ChatHarnessOption: Identifiable, Hashable {
    let id: String
    let name: String

    var choice: ChatRunChoice { .harness(id: id, name: name) }
}

enum ChatCatalog {
    /// Grouped by provider on newer servers, one flat list on older ones.
    static func models(_ json: [String: Any]) -> [ChatModelOption] {
        var out: [ChatModelOption] = []
        for group in json["groups"] as? [[String: Any]] ?? [] {
            let provider = group["provider"] as? String ?? ""
            let providerID = (group["provider_id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? provider
            for m in group["models"] as? [[String: Any]] ?? [] {
                guard let id = m["id"] as? String, !id.isEmpty else { continue }
                let label = (m["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
                out.append(ChatModelOption(id: id, label: label, provider: provider, providerID: providerID))
            }
        }
        if out.isEmpty {
            for item in json["models"] as? [Any] ?? [] {
                if let m = item as? [String: Any], let id = m["id"] as? String, !id.isEmpty {
                    let provider = m["provider"] as? String ?? ""
                    out.append(ChatModelOption(id: id, label: (m["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id,
                                               provider: provider,
                                               providerID: (m["provider_id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? provider))
                } else if let id = item as? String, !id.isEmpty {
                    out.append(ChatModelOption(id: id, label: id, provider: "", providerID: ""))
                }
            }
        }
        return out
    }

    static func harnesses(_ json: [String: Any]) -> [ChatHarnessOption] {
        (json["harnesses"] as? [[String: Any]] ?? []).compactMap { h in
            guard let id = h["id"] as? String, !id.isEmpty, id != "single" else { return nil }
            let name = [h["icon"] as? String, h["name"] as? String].compactMap { $0?.isEmpty == false ? $0 : nil }
                .joined(separator: " ")
            return ChatHarnessOption(id: id, name: name.isEmpty ? id : name)
        }
    }
}

// MARK: - Media

/// The agent's `MEDIA:<ref>` lines (the phone's ChatMedia, the web UI's
/// renderMd stash): rewritten into markdown images before rendering, so the
/// line becomes the picture instead of text.
enum ChatMedia {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "ico", "avif", "heic"]

    private static let componentAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-_.!~*'()")
        return set
    }()

    /// `http(s)` → `![image](url)`; a local path that looks like an image →
    /// `<base>/api/media?path=…`; anything else stays as text.
    static func rewrite(_ input: String, base: String = "") -> String {
        guard input.contains("MEDIA:"),
              let regex = try? NSRegularExpression(pattern: "MEDIA:([^\\s)\\]]+)") else { return input }
        let text = input as NSString
        var out = ""
        var cursor = 0
        for match in regex.matches(in: input, range: NSRange(location: 0, length: text.length)) {
            out += text.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let ref = text.substring(with: match.range(at: 1))
            out += replacement(for: ref, whole: text.substring(with: match.range), base: base)
            cursor = match.range.location + match.range.length
        }
        return out + text.substring(from: cursor)
    }

    private static func replacement(for ref: String, whole: String, base: String) -> String {
        guard !ref.isEmpty else { return whole }
        let lower = ref.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return "![image](\(ref))" }
        let path = ref.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ref
        guard let dot = path.lastIndex(of: "."),
              imageExtensions.contains(String(path[path.index(after: dot)...]).lowercased()) else { return ref }
        let encoded = ref.addingPercentEncoding(withAllowedCharacters: componentAllowed) ?? ref
        return "![image](\(base)/api/media?path=\(encoded))"
    }

    /// The `/api/media` URL behind a file on the server, root-relative (join it
    /// onto the island's API origin with `url(for:origin:)`).
    static func mediaSource(_ path: String) -> String {
        "/api/media?path=" + (path.addingPercentEncoding(withAllowedCharacters: componentAllowed) ?? path)
    }

    /// Where an image's bytes come from: the web as is; a server path through
    /// the island's API origin (jc-client's loopback, which carries the session).
    static func url(for source: String, origin: String?) -> URL? {
        let lower = source.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return URL(string: source) }
        guard source.hasPrefix("/"), var o = origin, !o.isEmpty else { return nil }
        while o.hasSuffix("/") { o.removeLast() }
        return URL(string: o + source)
    }

    /// A `data:` image's bytes.
    static func inlineData(_ source: String) -> Data? {
        guard source.hasPrefix("data:"), let comma = source.firstIndex(of: ",") else { return nil }
        return Data(base64Encoded: String(source[source.index(after: comma)...]), options: .ignoreUnknownCharacters)
    }
}

/// A model running on this Mac behind an OpenAI-compatible server: Ollama
/// (11434) or LM Studio (1234). After coucou's LocalChat (github.com/Louis-CFM/coucou, MIT).
enum LocalModel {
    static let ollama = "http://127.0.0.1:11434"
    static let lmStudio = "http://127.0.0.1:1234"

    static func normalise(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        for suffix in ["/api", "/v1"] where s.hasSuffix(suffix) { s.removeLast(suffix.count) }
        return s
    }

    static func chatURL(base: String) -> URL? { URL(string: normalise(base) + "/v1/chat/completions") }
    static func modelsURL(base: String) -> URL? { URL(string: normalise(base) + "/v1/models") }

    static func delta(_ line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]", let d = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let choice = (json["choices"] as? [[String: Any]])?.first,
              let delta = choice["delta"] as? [String: Any],
              let content = delta["content"] as? String, !content.isEmpty else { return nil }
        return content
    }

    static func isDone(_ line: String) -> Bool {
        line.hasPrefix("data:") && line.dropFirst(5).trimmingCharacters(in: .whitespaces) == "[DONE]"
    }

    /// What to show of a reasoning model's output: closed `<think>` blocks gone,
    /// an open one hidden until it closes.
    static func visible(_ text: String) -> String {
        var s = text
        while let open = s.range(of: "<think>") {
            if let close = s.range(of: "</think>", range: open.upperBound..<s.endIndex) {
                s.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                s = String(s[..<open.lowerBound])
                break
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The models a server offers for chat (embedding / rerank models left out).
    static func chatModels(_ json: [String: Any]) -> [String] {
        let skip = ["embed", "bge-", "all-minilm", "clip", "rerank"]
        return (json["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            .filter { id in !skip.contains { id.lowercased().contains($0) } }
    }
}

/// What goes with a message: files dropped on the island and the window you
/// were looking at (⌃⌥W).
enum ChatContext {
    static let maxInlineBytes = 64 * 1024

    struct Attachment: Equatable, Identifiable {
        var id: String { url.path }
        let url: URL
        let name: String
        let isImage: Bool
        /// The file's text when it is small, readable text; nil otherwise.
        let inlineText: String?
        var size: Int? = nil
    }

    static let maxUploadBytes = 50 * 1024 * 1024

    /// Checked from the file's size before a byte of it is read.
    static func canUpload(size: Int?) -> Bool {
        guard let size else { return false }
        return size <= maxUploadBytes
    }

    struct Window: Equatable {
        let app: String
        let title: String
        let url: String?

        var line: String {
            var s = "I'm looking at \(app)"
            if !title.isEmpty { s += " — \"\(title)\"" }
            if let url, !url.isEmpty { s += " (\(url))" }
            return s + "."
        }
    }

    static func attachment(for url: URL) -> Attachment? {
        guard url.isFileURL, let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
              values.isDirectory != true else { return nil }
        let type = UTType(filenameExtension: url.pathExtension)
        let isImage = type?.conforms(to: .image) ?? false
        var text: String?
        if !isImage, (values.fileSize ?? Int.max) <= maxInlineBytes,
           let data = try? Data(contentsOf: url), !data.contains(0), let s = String(data: data, encoding: .utf8) {
            text = s
        }
        return Attachment(url: url, name: url.lastPathComponent, isImage: isImage, inlineText: text,
                          size: values.fileSize)
    }

    static func prompt(_ text: String, attachments: [Attachment], window: Window?) -> String {
        var parts = [text]
        if let window { parts.append(window.line) }
        for a in attachments {
            if let body = a.inlineText {
                parts.append("File \(a.name):\n```\n\(body)\n```")
            } else {
                parts.append("(Attached: \(a.name))")
            }
        }
        return parts.joined(separator: "\n\n")
    }

    /// "12 KB" for a chip.
    static func sizeText(_ bytes: Int?) -> String? {
        guard let bytes else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

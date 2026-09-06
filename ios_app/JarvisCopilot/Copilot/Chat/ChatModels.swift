import Foundation

/// Data models for the native chat UI, ported from `chat/chat_models.dart`.
///
/// These mirror the web UI's chat contract closely enough to render the same
/// conversation. An assistant turn is an ordered list of ``ChatBlock``s (text and
/// tool cards interleaved, in arrival order) plus a separate reasoning trace —
/// exactly how the web UI lays out a streamed reply.
///
/// Everything here is a value type: `Equatable` so SwiftUI can diff a streaming
/// turn cheaply, and `Identifiable` so `ForEach` keeps its rows stable while text
/// is still arriving.

// MARK: - Sessions

/// A row in the sessions list (`GET /api/sessions`).
struct ChatSessionSummary: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var messageCount: Int?
    /// Epoch seconds.
    var updatedAt: Int?
    var model: String?
    var modelProvider: String?
    var pinned = false
    var archived = false
    /// A turn is running on this session right now — possibly ours, possibly the
    /// web UI's (see ``ChatStore``'s re-attach path).
    var isStreaming = false

    init(id: String, title: String = "", messageCount: Int? = nil, updatedAt: Int? = nil,
         model: String? = nil, modelProvider: String? = nil,
         pinned: Bool = false, archived: Bool = false, isStreaming: Bool = false) {
        self.id = id
        self.title = title
        self.messageCount = messageCount
        self.updatedAt = updatedAt
        self.model = model
        self.modelProvider = modelProvider
        self.pinned = pinned
        self.archived = archived
        self.isStreaming = isStreaming
    }

    init(json j: [String: Any]) {
        let activeStream = j.string("active_stream_id") ?? ""
        self.init(
            id: j.string("session_id") ?? j.string("id") ?? "",
            title: (j.string("title") ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            messageCount: j.int("message_count"),
            updatedAt: j.int("updated_at") ?? j.int("last_message_at"),
            model: j.string("model"),
            modelProvider: j.string("model_provider"),
            pinned: j["pinned"] as? Bool == true,
            archived: j["archived"] as? Bool == true,
            isStreaming: j["is_streaming"] as? Bool == true || !activeStream.isEmpty
        )
    }

    var displayTitle: String { title.isEmpty ? "New chat" : title }
}

// MARK: - Blocks

enum ChatRole: String, Equatable, Sendable, Codable {
    case user, assistant, system
}

struct TextBlock: Identifiable, Equatable, Sendable {
    var id = UUID()
    var text: String = ""
    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// A single tool call, used both live (streaming) and rebuilt from history.
struct ToolInvocation: Identifiable, Equatable, Sendable {
    /// The server's `tid` when it sent one, else a generated id — the tool rows
    /// need stable identity while the call is still running.
    var id: String = UUID().uuidString
    var name: String
    var args: [String: JSONValue] = [:]
    /// A short line the server sent about the call (arguments or a result peek).
    var preview: String?
    /// The full result text, from `tool_result` or a stored `tool` record.
    var result: String?
    var done = false
    var isError = false
    var durationSec: Double?
    /// The OpenAI-style `tool_calls[].id`, used to fold stored results back in.
    var callID: String?

    /// A short human label for the collapsed card header.
    var label: String { name.replacingOccurrences(of: "_", with: " ") }
    /// Device skills read better without their routing prefix.
    var shortName: String {
        name.hasPrefix("device_") ? String(name.dropFirst("device_".count)) : name
    }

    /// The one line a collapsed tool row shows.
    var detailLine: String {
        if done, let result, !result.trimmingCharacters(in: .whitespaces).isEmpty {
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let preview, !preview.trimmingCharacters(in: .whitespaces).isEmpty {
            return preview.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return args.previewLine
    }

    var hasDetail: Bool { !args.isEmpty || !(result ?? "").isEmpty || !(preview ?? "").isEmpty }
}

/// One block inside a message. Assistant turns interleave text and tool cards in
/// arrival order.
enum ChatBlock: Identifiable, Equatable, Sendable {
    case text(TextBlock)
    case tool(ToolInvocation)

    var id: String {
        switch self {
        case .text(let b): return "t:\(b.id.uuidString)"
        case .tool(let t): return "x:\(t.id)"
        }
    }
    var asText: TextBlock? { if case .text(let b) = self { return b }; return nil }
    var asTool: ToolInvocation? { if case .tool(let t) = self { return t }; return nil }
}

// MARK: - Attachments and stats

/// An attachment on a message already in the transcript.
struct MessageAttachment: Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    /// Image/poster bytes for a just-sent attachment, so the bubble can show a
    /// real preview this session. Nil after a history reload — the server stores
    /// only the name, and the bubble falls back to a file chip.
    var thumbnail: Data?
}

/// Per-turn status shown as a small line under the reply. The UI shows only three
/// of these: tokens in, tokens out, and the elapsed seconds.
struct ChatTurnStats: Equatable, Sendable {
    var inputTokens: Int?
    var outputTokens: Int?
    var durationMs: Int?
    /// Time to the first visible text — measured, but not shown.
    var firstTokenMs: Int?
    var tokensPerSecond: Double?
    /// The server metered this turn by estimate, not by count.
    var estimated = false

    var isEmpty: Bool { inputTokens == nil && outputTokens == nil && durationMs == nil }

    /// "16.4k in · 12 out · 3.2 s"
    var line: String {
        var parts: [String] = []
        if inputTokens != nil || outputTokens != nil {
            let tilde = estimated ? "~" : ""
            parts.append("\(tilde)\(Self.compact(inputTokens ?? 0)) in · \(Self.compact(outputTokens ?? 0)) out")
        }
        if let durationMs { parts.append(Self.seconds(durationMs)) }
        return parts.joined(separator: " · ")
    }

    static func compact(_ n: Int) -> String {
        n >= 1_000 ? String(format: "%.1fk", Double(n) / 1_000) : "\(n)"
    }

    static func seconds(_ ms: Int) -> String {
        ms < 1_000 ? "\(ms) ms" : String(format: "%.1f s", Double(ms) / 1_000)
    }
}

/// The agent's open clarify question. The UI shows the question plus choice chips;
/// answering posts to `/api/clarify/respond` so the blocked turn resumes (without
/// it the turn just hangs on "thinking").
struct ClarifyPrompt: Identifiable, Equatable, Sendable {
    var question: String
    var choices: [String] = []
    /// The question itself — there is only ever one open at a time.
    var id: String { question }
}

// MARK: - Messages

/// A chat message. User messages carry a single text block; assistant messages
/// carry interleaved blocks plus an optional reasoning trace.
struct ChatMessage: Identifiable, Equatable, Sendable {
    /// A fresh message (one the user just typed, or the live assistant turn) gets
    /// a random id; one rebuilt from the server's record gets a *deterministic*
    /// one — see ``storedID(role:timestamp:index:)``.
    var id = UUID()
    var role: ChatRole
    var blocks: [ChatBlock] = []
    var reasoning: String = ""
    var attachments: [MessageAttachment] = []
    var streaming = false
    var isError = false
    /// This turn was answered on-device (shows the "on-device" badge).
    var onDevice = false
    var stats: ChatTurnStats?
    /// Epoch seconds, from a stored record.
    var timestamp: Int?

    static func user(_ text: String, attachments: [MessageAttachment] = []) -> ChatMessage {
        ChatMessage(role: .user, blocks: [.text(TextBlock(text: text))], attachments: attachments)
    }

    static func assistant(streaming: Bool = false) -> ChatMessage {
        ChatMessage(role: .assistant, streaming: streaming)
    }

    /// The identity of a message rebuilt from `GET /api/session`.
    ///
    /// A random `UUID()` per parse re-identifies every row on every refresh, so
    /// `ForEach` throws the transcript away and rebuilds it: the scroll position
    /// jumps and an expanded reasoning card collapses under the user's thumb
    /// (swift-correctness H10). Role + timestamp + position is stable across
    /// refetches of the same thread and distinct within one, which is all the
    /// list diffing needs.
    static func storedID(role: String, timestamp: Int?, index: Int) -> UUID {
        let seed = "\(role)|\(timestamp.map(String.init) ?? "-")|\(index)"
        // Two FNV-1a passes with different offset bases fill the 16 bytes. Not a
        // cryptographic hash — nothing here needs one — just a stable one.
        var bytes: [UInt8] = []
        for basis in [UInt64(0xcbf2_9ce4_8422_2325), UInt64(0x9e37_79b9_7f4a_7c15)] {
            var hash = basis
            for byte in seed.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
            withUnsafeBytes(of: hash.bigEndian) { bytes.append(contentsOf: $0) }
        }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    var isUser: Bool { role == .user }
    var isAssistant: Bool { role == .assistant }

    /// Concatenated plain text — used for copy and the user-bubble path.
    var plainText: String {
        blocks.compactMap(\.asText).map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Every tool call in this turn, in arrival order (the tool rows above the text).
    var tools: [ToolInvocation] { blocks.compactMap(\.asTool) }

    /// True while the model is reasoning and nothing visible has arrived yet — the
    /// cue for the "Thinking…" dots.
    var isThinking: Bool {
        !reasoning.isEmpty && plainText.isEmpty
    }

    /// Append streamed text to the trailing text block, opening a fresh one if the
    /// last block is a tool card (a post-tool continuation).
    mutating func appendToken(_ token: String) {
        guard !token.isEmpty else { return }
        if let last = blocks.last, case .text(var block) = last {
            block.text += token
            blocks[blocks.count - 1] = .text(block)
        } else {
            blocks.append(.text(TextBlock(text: token)))
        }
    }

    mutating func startTool(_ tool: ToolInvocation) {
        blocks.append(.tool(tool))
    }

    /// Mark the most recent unfinished tool block as complete. `id` wins when the
    /// server sent one; `name` is the fallback (older servers send no ids).
    mutating func completeTool(id: String? = nil, name: String? = nil, durationSec: Double? = nil,
                               isError: Bool = false, preview: String? = nil, result: String? = nil) {
        for index in blocks.indices.reversed() {
            guard case .tool(var tool) = blocks[index], !tool.done else { continue }
            let matches = (id != nil && tool.id == id) || (id == nil && (name == nil || tool.name == name))
            guard matches else { continue }
            tool.done = true
            tool.durationSec = durationSec ?? tool.durationSec
            tool.isError = isError
            if let preview, !preview.isEmpty { tool.preview = preview }
            if let result, !result.isEmpty { tool.result = result }
            blocks[index] = .tool(tool)
            return
        }
    }

    /// Close every still-running tool row — nothing may keep spinning once the
    /// turn is over.
    mutating func closeOpenTools() {
        for index in blocks.indices {
            if case .tool(var tool) = blocks[index], !tool.done {
                tool.done = true
                blocks[index] = .tool(tool)
            }
        }
    }

    /// Drop text blocks that never received anything (a tool-only turn leaves one
    /// behind).
    mutating func dropEmptyTextBlocks() {
        blocks.removeAll { $0.asText?.isEmpty == true }
    }

}

// In an extension so the memberwise initialiser survives.
extension ChatMessage {
    /// Build a message from a stored session entry. Handles string or array
    /// `content`, OpenAI-style `tool_calls`, and a `thinking` / `reasoning` trace.
    /// Returns nil for records that render nothing (a `tool` role folds into its
    /// matching tool block instead — see ``ChatHistory``).
    init?(stored j: [String: Any]) {
        let rawRole = j.string("role") ?? ""
        if rawRole == "tool" { return nil }

        var blocks: [ChatBlock] = []
        if let content = j["content"] as? String {
            if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(.text(TextBlock(text: content)))
            }
        } else if let parts = j["content"] as? [Any] {
            for case let part as [String: Any] in parts {
                switch part.string("type") ?? "" {
                case "text":
                    let text = part.string("text") ?? ""
                    if !text.isEmpty { blocks.append(.text(TextBlock(text: text))) }
                case "tool_use":
                    blocks.append(.tool(ToolInvocation(
                        name: part.string("name") ?? "tool",
                        args: JSONValue(part["input"]).objectValue ?? [:],
                        done: true,
                        callID: part.string("id"))))
                default:
                    break
                }
            }
        }

        // OpenAI-style tool_calls live alongside content.
        if let calls = j["tool_calls"] as? [Any] {
            for case let call as [String: Any] in calls {
                let function = call.dict("function")
                let name = function?.string("name") ?? call.string("name") ?? "tool"
                var args: [String: JSONValue] = [:]
                if let raw = function?["arguments"] as? String {
                    args = ChatHistory.parseJSONObject(raw)
                } else if let dict = function?["arguments"] as? [String: Any] {
                    args = JSONValue(dict).objectValue ?? [:]
                }
                blocks.append(.tool(ToolInvocation(name: name, args: args, done: true,
                                                   callID: call.string("id"))))
            }
        }

        let reasoning = j.string("thinking") ?? j.string("reasoning") ?? ""
        if blocks.isEmpty && reasoning.isEmpty { return nil }

        var attachments: [MessageAttachment] = []
        for item in (j["attachments"] as? [Any] ?? []) {
            if let dict = item as? [String: Any], let name = dict.string("name") {
                attachments.append(MessageAttachment(name: name))
            } else if let name = item as? String {
                attachments.append(MessageAttachment(name: name))
            }
        }

        self.init(role: ChatRole(rawValue: rawRole) ?? .assistant,
                  blocks: blocks,
                  reasoning: reasoning,
                  attachments: attachments,
                  onDevice: j["on_device"] as? Bool == true,
                  timestamp: j.int("timestamp"))
    }
}

// MARK: - History

enum ChatHistory {
    /// Rebuild a transcript from `GET /api/session`'s `messages`. Records with the
    /// `tool` role carry the *result* of a call made in the preceding assistant
    /// record, so they are indexed by `tool_call_id` and folded into the matching
    /// tool block rather than rendered on their own.
    static func hydrate(_ raw: [[String: Any]]) -> [ChatMessage] {
        var results: [String: String] = [:]
        for record in raw where record.string("role") == "tool" {
            let id = record.string("tool_call_id") ?? ""
            if !id.isEmpty { results[id] = record.string("content") ?? "" }
        }

        var messages: [ChatMessage] = []
        for record in raw {
            guard var message = ChatMessage(stored: record) else { continue }
            message.id = ChatMessage.storedID(role: message.role.rawValue,
                                              timestamp: message.timestamp,
                                              index: messages.count)
            for index in message.blocks.indices {
                guard case .tool(var tool) = message.blocks[index],
                      let callID = tool.callID,
                      let result = results[callID], !result.isEmpty else { continue }
                tool.result = result
                message.blocks[index] = .tool(tool)
            }
            messages.append(message)
        }
        return messages
    }

    /// A JSON object out of a string field, or empty when it isn't one (some
    /// providers send `arguments` as a partially-streamed string).
    static func parseJSONObject(_ raw: String) -> [String: JSONValue] {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return JSONValue(object).objectValue ?? [:]
    }
}

// MARK: - What the transcript renders

/// One transcript row: a message plus the only thing the list layout needs to know
/// about its neighbours. Consecutive messages from the same speaker stay close; a
/// change of speaker gets clear air.
struct ChatRow: Identifiable, Equatable, Sendable {
    var message: ChatMessage
    var continuesSpeaker: Bool
    var id: UUID { message.id }

    static func rows(for messages: [ChatMessage]) -> [ChatRow] {
        messages.enumerated().map { index, message in
            ChatRow(message: message,
                    continuesSpeaker: index > 0 && messages[index - 1].role == message.role)
        }
    }
}

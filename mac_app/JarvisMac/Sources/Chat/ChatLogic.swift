import Foundation
import UniformTypeIdentifiers

/// `text/event-stream` from the server's `/api/chat/stream` (the same frames
/// the iPhone reads: token/delta/text, tool, tool_result, done…).
struct ChatSSE {
    struct Event: Equatable {
        let name: String
        let object: [String: String]

        var token: String? {
            guard ["token", "delta", "text"].contains(name) else { return nil }
            let t = object["text"] ?? object["delta"] ?? object["content"] ?? ""
            return t.isEmpty ? nil : t
        }
        var toolName: String? { name == "tool" ? object["name"] : nil }
        var isEnd: Bool { ["done", "stream_end", "complete", "error", "cancelled"].contains(name) }
        var error: String? { name == "error" ? (object["message"] ?? object["error"] ?? "The chat failed.") : nil }
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
        if let d = raw.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            for (k, v) in json {
                if let s = v as? String { obj[k] = s } else if let n = v as? NSNumber { obj[k] = n.stringValue }
            }
        } else {
            obj["text"] = raw
        }
        return Event(name: obj["event"] ?? event, object: obj)
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
        return Attachment(url: url, name: url.lastPathComponent, isImage: isImage, inlineText: text)
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
}

import Foundation

/// Talks to the JarvisCopilot chat API with the bridge's own credentials. The bridge
/// has no device-originated message type, so anything the app or a board wants to
/// *ask* Jarvis goes through the same HTTP chat endpoints the web UI and the Apple
/// Watch use: a session per purpose, `chat/start` streamed as server-sent events, and
/// `background` for a hidden one-shot turn whose answer we wait for.
@MainActor
final class JarvisChatClient {
    static let shared = JarvisChatClient()
    private init() {}

    enum ChatError: LocalizedError {
        case notPaired, noServer, http(Int), badReply, streamFailed(String), busy, stalled
        var errorDescription: String? {
            switch self {
            case .notPaired:         return "Pair with Jarvis Copilot in Settings first"
            case .noServer:          return "no Jarvis server URL"
            case .http(let code):    return "Jarvis answered HTTP \(code)"
            case .badReply:          return "Jarvis sent a reply the app could not parse"
            case .streamFailed(let m): return "Jarvis: \(m)"
            case .busy:              return "Jarvis is still working on the previous message"
            case .stalled:           return "lost the live stream"
            }
        }
    }

    /// What the server knows about a session right now: whether a turn is running (and
    /// on which stream) and the last assistant text. The phone's live stream can be
    /// starved when the web UI is open on the same session, so this is the fallback.
    struct SessionSnapshot {
        let activeStreamID: String?
        let lastAssistantText: String?
        let lastToolNames: [String]
    }

    func snapshot(sessionID: String) async throws -> SessionSnapshot {
        guard let request = BridgeClient.shared.authorizedRequest(
            path: "api/session", query: [URLQueryItem(name: "session_id", value: sessionID)], timeout: 30) else {
            throw ChatError.noServer
        }
        let (data, response) = try await BridgeClient.shared.urlSession.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ChatError.http(code) }
        let session = obj["session"] as? [String: Any] ?? obj
        let active = (session["active_stream_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let messages = session["messages"] as? [[String: Any]] ?? []
        var lastText: String?
        var tools: [String] = []
        for m in messages.reversed() {
            guard (m["role"] as? String) == "assistant" else { if lastText == nil { continue } else { break } }
            if let calls = m["tool_calls"] as? [[String: Any]] {
                tools = calls.compactMap { ($0["function"] as? [String: Any])?["name"] as? String ?? $0["name"] as? String } + tools
            }
            if lastText == nil {
                if let c = m["content"] as? String, !c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lastText = c }
                else if let parts = m["content"] as? [[String: Any]] {
                    let text = parts.compactMap { $0["text"] as? String }.joined()
                    if !text.isEmpty { lastText = text }
                }
                if lastText == nil { continue }  // a tool-call-only assistant record; keep walking
            } else { break }
        }
        return SessionSnapshot(activeStreamID: active, lastAssistantText: lastText, lastToolNames: tools)
    }

    /// Attaches to a stream already running on the server (after a 409, or when the
    /// phone's own stream went quiet).
    func attach(streamID: String, onEvent: @escaping (StreamEvent) -> Void) async throws -> String {
        try await stream(id: streamID, onEvent: onEvent)
    }

    /// One conversation per key (a board's device ID), created on first use and
    /// remembered so the agent keeps its context across app launches.
    func sessionID(for key: String, title: String) async throws -> String {
        let defaultsKey = "jarvisChatSession.\(key)"
        if let cached = UserDefaults.standard.string(forKey: defaultsKey), !cached.isEmpty { return cached }
        let obj = try await postJSON(path: "api/session/new", body: ["title": title])
        guard let sid = Self.extractSessionID(obj) else { throw ChatError.badReply }
        UserDefaults.standard.set(sid, forKey: defaultsKey)
        return sid
    }

    func forgetSession(for key: String) {
        UserDefaults.standard.removeObject(forKey: "jarvisChatSession.\(key)")
    }

    /// What the chat stream reports while the agent works, in the same shape the web UI
    /// consumes: text deltas, tool calls starting and finishing, and reasoning deltas.
    enum StreamEvent {
        case token(String)
        case reasoning(String)
        case toolStarted(id: String, name: String, preview: String)
        case toolFinished(id: String?, name: String, snippet: String)
        /// Token usage for the turn, as the server meters it.
        case usage(inputTokens: Int, outputTokens: Int, tokensPerSecond: Double?, estimated: Bool)
    }

    struct Model: Identifiable, Hashable {
        let id: String
        let label: String
        let provider: String
    }

    /// The server's model catalogue: `(default, models)`. Cached for the app's lifetime.
    private var modelCache: (String, [Model])?

    func models() async throws -> (defaultModel: String, models: [Model]) {
        if let cached = modelCache { return cached }
        guard BridgeClient.shared.isPaired else { throw ChatError.notPaired }
        guard let request = BridgeClient.shared.authorizedRequest(path: "api/models", timeout: 30) else { throw ChatError.noServer }
        let (data, response) = try await BridgeClient.shared.urlSession.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ChatError.badReply }
        var out: [Model] = []
        for group in obj["groups"] as? [[String: Any]] ?? [] {
            let provider = group["provider"] as? String ?? ""
            for m in group["models"] as? [[String: Any]] ?? [] {
                guard let id = m["id"] as? String, !id.isEmpty else { continue }
                out.append(Model(id: id, label: m["label"] as? String ?? id, provider: provider))
            }
        }
        let result = (obj["default_model"] as? String ?? "", out)
        modelCache = result
        return result
    }

    /// Sends a user turn and streams the reply. `onToken` receives each delta on the
    /// main actor; the full reply is returned when the stream ends.
    func send(sessionID: String, message: String, model: Model? = nil, onToken: @escaping (String) -> Void) async throws -> String {
        try await send(sessionID: sessionID, message: message, model: model) { event in
            if case .token(let t) = event { onToken(t) }
        }
    }

    func send(sessionID: String, message: String, model: Model? = nil, onEvent: @escaping (StreamEvent) -> Void) async throws -> String {
        guard BridgeClient.shared.isPaired else { throw ChatError.notPaired }
        guard var request = BridgeClient.shared.authorizedRequest(
            path: "api/chat/start", query: [URLQueryItem(name: "stream", value: "1")], timeout: 300) else {
            throw ChatError.noServer
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")
        var body: [String: Any] = ["session_id": sessionID, "message": message]
        if let model {
            body["model"] = model.id
            if !model.provider.isEmpty { body["model_provider"] = model.provider }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await BridgeClient.shared.urlSession.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChatError.badReply }
        if http.statusCode == 200, (http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("text/event-stream") {
            return try await consumeSSE(bytes, onEvent: onEvent)
        }
        var data = Data()
        for try await b in bytes { data.append(b) }
        if http.statusCode == 409 { throw ChatError.busy }
        guard http.statusCode == 200 else { throw ChatError.http(http.statusCode) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streamID = obj["stream_id"] as? String, !streamID.isEmpty else { throw ChatError.badReply }
        return try await stream(id: streamID, onEvent: onEvent)
    }

    /// A hidden one-shot turn: the agent runs with its tools and we return its final
    /// text. Used to relay `jarvis.invoke` requests from board scripts.
    func background(parentSession: String, prompt: String) async throws -> String {
        guard BridgeClient.shared.isPaired else { throw ChatError.notPaired }
        let obj = try await postJSON(path: "api/background", body: ["session_id": parentSession, "prompt": prompt])
        guard let streamID = obj["stream_id"] as? String, !streamID.isEmpty else { throw ChatError.badReply }
        return try await stream(id: streamID, onEvent: { _ in })
    }

    // MARK: - Plumbing

    private func stream(id: String, onEvent: @escaping (StreamEvent) -> Void) async throws -> String {
        guard var request = BridgeClient.shared.authorizedRequest(
            path: "api/chat/stream", query: [URLQueryItem(name: "stream_id", value: id)], timeout: 300) else {
            throw ChatError.noServer
        }
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await BridgeClient.shared.urlSession.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ChatError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try await consumeSSE(bytes, onEvent: onEvent)
    }

    /// Reads the SSE stream incrementally and returns on `stream_end`; the server keeps
    /// the connection open with heartbeats long after the answer.
    /// No real event for this long means the phone's consumer is starved (another
    /// client drained the queue) or the connection died quietly; the caller re-syncs.
    static let idleLimit: TimeInterval = 45

    private func consumeSSE(_ bytes: URLSession.AsyncBytes, onEvent: @escaping (StreamEvent) -> Void) async throws -> String {
        var full = ""
        var event = ""
        let lastEvent = IdleClock()
        let watchdog = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if lastEvent.idle > Self.idleLimit { return }
            }
        }
        defer { watchdog.cancel() }
        for try await line in bytes.lines {
            if watchdog.isCancelled == false, lastEvent.idle > Self.idleLimit { throw ChatError.stalled }
            if line.hasPrefix(":") { continue }
            if line.hasPrefix("event:") {
                event = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                let json = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                guard let d = json.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                lastEvent.touch()
                switch event {
                case "token":
                    if let t = obj["text"] as? String { full += t; onEvent(.token(t)) }
                case "interim_assistant":
                    // Text the agent said between tool rounds; skipped when it already
                    // arrived as tokens.
                    if (obj["already_streamed"] as? Bool) != true, let t = obj["text"] as? String,
                       !t.trimmingCharacters(in: .whitespaces).isEmpty {
                        let chunk = (full.isEmpty ? "" : "\n\n") + t
                        full += chunk; onEvent(.token(chunk))
                    }
                case "reasoning":
                    if let t = (obj["text"] as? String) ?? (obj["delta"] as? String) { onEvent(.reasoning(t)) }
                case "tool":
                    let name = obj["name"] as? String ?? "tool"
                    guard name != "clarify" else { break }
                    let preview = (obj["preview"] as? String) ?? Self.previewArgs(obj["args"])
                    onEvent(.toolStarted(id: obj["tid"] as? String ?? UUID().uuidString, name: name, preview: preview))
                case "tool_complete":
                    let name = obj["name"] as? String ?? "tool"
                    guard name != "clarify" else { break }
                    let snippet = (obj["snippet"] as? String) ?? (obj["result"] as? String) ?? (obj["preview"] as? String) ?? ""
                    onEvent(.toolFinished(id: obj["tid"] as? String, name: name, snippet: snippet))
                case "metering":
                    let u = obj["usage"] as? [String: Any] ?? [:]
                    func num(_ keys: String...) -> Int {
                        for k in keys { if let v = u[k] as? Int { return v }; if let v = u[k] as? Double { return Int(v) } }
                        return 0
                    }
                    let tps = (obj["tps"] as? Double) ?? (obj["tps"] as? Int).map(Double.init)
                        ?? (u["tps"] as? Double) ?? (u["tps"] as? Int).map(Double.init)
                    onEvent(.usage(inputTokens: num("prompt_tokens", "input_tokens", "input"),
                                   outputTokens: num("completion_tokens", "output_tokens", "output"),
                                   tokensPerSecond: (obj["tps_available"] as? Bool) == false ? nil : tps,
                                   estimated: obj["estimated"] as? Bool ?? false))
                case "stream_end", "done":
                    if full.isEmpty, let t = (obj["answer"] as? String) ?? (obj["text"] as? String), !t.isEmpty {
                        full = t; onEvent(.token(t))
                    }
                    return full
                case "apperror", "error":
                    throw ChatError.streamFailed(obj["message"] as? String ?? obj["error"] as? String ?? "stream error")
                case "cancel":
                    return full
                default:
                    break
                }
            }
        }
        return full
    }

    private func postJSON(path: String, body: [String: Any]) async throws -> [String: Any] {
        guard BridgeClient.shared.isPaired else { throw ChatError.notPaired }
        guard var request = BridgeClient.shared.authorizedRequest(path: path, timeout: 60) else { throw ChatError.noServer }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await BridgeClient.shared.urlSession.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw ChatError.http(code) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ChatError.badReply }
        return obj
    }

    /// One short line summarising a tool's arguments when the server gives no preview.
    private static func previewArgs(_ args: Any?) -> String {
        guard let dict = args as? [String: Any], !dict.isEmpty else { return "" }
        let parts = dict.keys.sorted().prefix(3).compactMap { key -> String? in
            guard let v = dict[key] else { return nil }
            var text = "\(v)"
            if text.count > 40 { text = String(text.prefix(39)) + "…" }
            return "\(key): \(text)"
        }
        return parts.joined(separator: " · ")
    }

    /// Timestamp of the last real stream event, shared with the watchdog.
    private final class IdleClock: @unchecked Sendable {
        private var last = Date()
        private let lock = NSLock()
        func touch() { lock.lock(); last = Date(); lock.unlock() }
        var idle: TimeInterval { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(last) }
    }

    private static func extractSessionID(_ obj: [String: Any]) -> String? {
        if let s = obj["session_id"] as? String, !s.isEmpty { return s }
        if let inner = obj["session"] as? [String: Any] {
            if let s = inner["session_id"] as? String, !s.isEmpty { return s }
            if let s = inner["id"] as? String, !s.isEmpty { return s }
        }
        return nil
    }
}

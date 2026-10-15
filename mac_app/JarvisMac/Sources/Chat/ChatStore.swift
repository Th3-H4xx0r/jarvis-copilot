import AppKit
import Foundation
import Observation

/// The island's chat. Jarvis answers through the server (the loopback origin
/// jc-client opens, which carries this Mac's session), or a local model on
/// this Mac does (Ollama / LM Studio), for when you'd rather nothing leaves it.
@MainActor
@Observable
final class MacChatStore {
    static let shared = MacChatStore()

    enum Provider: String, CaseIterable, Identifiable {
        case jarvis, ollama, lmStudio
        var id: String { rawValue }
        var label: String {
            switch self {
            case .jarvis: return "Jarvis"
            case .ollama: return "Ollama"
            case .lmStudio: return "LM Studio"
            }
        }
        var base: String? {
            switch self {
            case .jarvis: return nil
            case .ollama: return LocalModel.ollama
            case .lmStudio: return LocalModel.lmStudio
            }
        }
    }

    struct Line: Identifiable, Equatable {
        enum Role { case user, assistant, tool, error }
        let id = UUID()
        let role: Role
        var text: String
    }

    private(set) var lines: [Line] = []
    var draft = ""
    private(set) var attachments: [ChatContext.Attachment] = []
    private(set) var window: ChatContext.Window?
    private(set) var busy = false
    private(set) var localModels: [String] = []
    private(set) var localError: String?

    var provider: Provider {
        didSet { UserDefaults.standard.set(provider.rawValue, forKey: "chat.provider"); loadLocalModels() }
    }
    var localModel: String {
        didSet { UserDefaults.standard.set(localModel, forKey: "chat.localModel") }
    }

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var sessionID: String? {
        get { UserDefaults.standard.string(forKey: "chat.session") }
        set { UserDefaults.standard.set(newValue, forKey: "chat.session") }
    }

    private init() {
        provider = Provider(rawValue: UserDefaults.standard.string(forKey: "chat.provider") ?? "") ?? .jarvis
        localModel = UserDefaults.standard.string(forKey: "chat.localModel") ?? ""
    }

    // MARK: context

    func attach(_ urls: [URL]) {
        for url in urls {
            guard let a = ChatContext.attachment(for: url), !attachments.contains(a) else { continue }
            attachments.append(a)
        }
    }

    func remove(_ a: ChatContext.Attachment) { attachments.removeAll { $0 == a } }

    /// ⌃⌥W: the app and window you were in (and the page, in a browser).
    func captureWindow(from app: NSRunningApplication?) {
        Task { [weak self] in
            let w = await WindowContext.capture(app)
            self?.window = w
        }
    }

    func clearWindow() { window = nil }

    // MARK: sending

    // MARK: demo

    @ObservationIgnored private var stashedLines: [Line]?

    /// Made-up exchanges for the demo tour; nothing is sent.
    func showDemo(_ pairs: [(String, String)]) {
        if stashedLines == nil { stashedLines = lines }
        lines = pairs.flatMap { [Line(role: .user, text: $0.0), Line(role: .assistant, text: $0.1)] }
    }

    func endDemo() {
        if let real = stashedLines { lines = real }
        stashedLines = nil
    }

    func newChat() {
        task?.cancel()
        lines = []
        attachments = []
        window = nil
        busy = false
        sessionID = nil
    }

    func stop() {
        task?.cancel()
        busy = false
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        draft = ""
        let files = attachments, win = window
        attachments = []
        window = nil
        lines.append(Line(role: .user, text: text))
        lines.append(Line(role: .assistant, text: ""))
        busy = true
        let provider = self.provider
        task = Task { [weak self] in
            guard let self else { return }
            do {
                if provider == .jarvis {
                    try await self.sendToJarvis(text, files: files, window: win)
                } else {
                    try await self.sendToLocal(text, files: files, window: win, base: provider.base ?? "")
                }
            } catch is CancellationError {
            } catch {
                self.fail(error.localizedDescription)
            }
            self.busy = false
        }
    }

    private func appendToAnswer(_ s: String) {
        guard let i = lines.lastIndex(where: { $0.role == .assistant }) else { return }
        lines[i].text += s
    }

    private func setAnswer(_ s: String) {
        guard let i = lines.lastIndex(where: { $0.role == .assistant }) else { return }
        lines[i].text = s
    }

    private func fail(_ message: String) {
        if let i = lines.lastIndex(where: { $0.role == .assistant }), lines[i].text.isEmpty { lines.remove(at: i) }
        lines.append(Line(role: .error, text: message))
    }

    // MARK: Jarvis

    private func origin() throws -> String {
        guard let o = AppModel.shared.apiOrigin else {
            throw ChatError("Jarvis isn't connected on this Mac (jc-client).")
        }
        return o
    }

    private func postJSON(_ path: String, _ body: [String: Any], query: String = "") throws -> URLRequest {
        guard let url = URL(string: try origin() + path + query) else { throw ChatError("Bad server address.") }
        var req = URLRequest(url: url, timeoutInterval: 600)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    private func ensureSession() async throws -> String {
        if let id = sessionID, !id.isEmpty { return id }
        let (data, _) = try await URLSession.shared.data(for: try postJSON("/api/session/new", ["title": "Mac island"]))
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let inner = obj["session"] as? [String: Any] ?? [:]
        guard let id = (obj["session_id"] as? String) ?? (inner["session_id"] as? String) ?? (inner["id"] as? String)
                ?? (obj["id"] as? String), !id.isEmpty else { throw ChatError("Couldn't start a chat with Jarvis.") }
        sessionID = id
        return id
    }

    private func upload(_ a: ChatContext.Attachment, session: String) async throws -> [String: Any]? {
        guard ChatContext.canUpload(size: a.size) else {
            lines.insert(Line(role: .tool, text: "\(a.name) is over 50 MB, so it wasn't sent"),
                         at: max(0, lines.count - 1))
            return nil
        }
        let url = a.url
        guard let data = try? await Task.detached(operation: { try Data(contentsOf: url) }).value else { return nil }
        let boundary = "jc-\(UUID().uuidString)"
        var body = Data()
        func line(_ s: String) { body.append(Data(s.utf8)) }
        line("--\(boundary)\r\nContent-Disposition: form-data; name=\"session_id\"\r\n\r\n\(session)\r\n")
        line("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(a.name)\"\r\n")
        line("Content-Type: application/octet-stream\r\n\r\n")
        body.append(data)
        line("\r\n--\(boundary)--\r\n")
        guard let url = URL(string: try origin() + "/api/upload") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (resp, http) = try await URLSession.shared.data(for: req)
        guard (http as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: resp)) as? [String: Any]
    }

    private func sendToJarvis(_ text: String, files: [ChatContext.Attachment], window: ChatContext.Window?) async throws {
        let session = try await ensureSession()
        var uploaded: [[String: Any]] = []
        for a in files where a.inlineText == nil {
            if let u = try await upload(a, session: session) { uploaded.append(u) }
        }
        let inlined = files.filter { $0.inlineText != nil }
        var body: [String: Any] = ["session_id": session,
                                   "message": ChatContext.prompt(text, attachments: inlined, window: window)]
        if !uploaded.isEmpty { body["attachments"] = uploaded }
        let (bytes, response) = try await URLSession.shared.bytes(for: try postJSON("/api/chat/start", body, query: "?stream=1"))
        let type = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
        if type.contains("text/event-stream") {
            try await pump(bytes.lines)
            return
        }
        var raw = Data()
        for try await b in bytes { raw.append(b) }
        let obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] ?? [:]
        guard let stream = obj["stream_id"] as? String,
              let url = URL(string: try origin() + "/api/chat/stream?stream_id=\(stream)") else {
            throw ChatError((obj["error"] as? String) ?? "Jarvis didn't start the reply.")
        }
        let (events, _) = try await URLSession.shared.bytes(from: url)
        try await pump(events.lines)
    }

    private func pump<S: AsyncSequence>(_ lines: S) async throws where S.Element == String {
        var parser = ChatSSE()
        for try await line in lines {
            try Task.checkCancellation()
            // `AsyncLineSequence` drops the blank separator lines; the server's
            // frames are one JSON line each, so a data line ends its event.
            _ = parser.feed(line)
            if line.hasPrefix("data:"), let e = parser.feed(""), handle(e) { return }
        }
        if let e = parser.finish() { _ = handle(e) }
    }

    /// True at the end of the turn.
    private func handle(_ e: ChatSSE.Event) -> Bool {
        if let t = e.token { appendToAnswer(t) }
        if let tool = e.toolName {
            let i = lines.lastIndex(where: { $0.role == .assistant }) ?? lines.endIndex
            lines.insert(Line(role: .tool, text: tool), at: i)
        }
        if let err = e.error { fail(err) }
        return e.isEnd
    }

    // MARK: local

    func loadLocalModels() {
        localError = nil
        guard let base = provider.base, let url = LocalModel.modelsURL(base: base) else { return }
        Task { [weak self] in
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                let models = LocalModel.chatModels(json)
                self?.localModels = models
                if let self, !models.contains(self.localModel) { self.localModel = models.first ?? "" }
                if models.isEmpty { self?.localError = "No chat models on \(self?.provider.label ?? "it") yet." }
            } catch {
                self?.localModels = []
                self?.localError = "\(self?.provider.label ?? "The local server") isn't running."
            }
        }
    }

    private func sendToLocal(_ text: String, files: [ChatContext.Attachment], window: ChatContext.Window?,
                             base: String) async throws {
        guard !localModel.isEmpty, let url = LocalModel.chatURL(base: base) else {
            throw ChatError(localError ?? "Pick a local model first.")
        }
        var history: [[String: String]] = []
        for l in lines.dropLast(2) where l.role == .user || l.role == .assistant {
            history.append(["role": l.role == .user ? "user" : "assistant", "content": l.text])
        }
        history.append(["role": "user", "content": ChatContext.prompt(text, attachments: files, window: window)])
        var req = URLRequest(url: url, timeoutInterval: 600)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": localModel, "messages": history, "stream": true])
        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ChatError("\(provider.label) answered with an error.")
        }
        var raw = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            if LocalModel.isDone(line) { break }
            if let d = LocalModel.delta(line) {
                raw += d
                setAnswer(LocalModel.visible(raw))
            }
        }
    }
}

struct ChatError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

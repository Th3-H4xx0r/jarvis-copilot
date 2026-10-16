import AppKit
import Foundation
import Observation

/// The island's chat. Jarvis answers through the server (the loopback origin
/// jc-client opens, which carries this Mac's session) with the full toolset of
/// the regular chat, or a local model on this Mac does (Ollama / LM Studio),
/// for when you'd rather nothing leaves it.
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

    /// One row of the conversation: what you said, a reply, or a muted note.
    struct Line: Identifiable, Equatable {
        enum Role { case user, assistant, note }
        let id = UUID()
        let role: Role
        /// What you said, or the note; a reply's words live in `turn`.
        var text: String
        var turn = ChatTurn()
        /// What went with your message (files, the window).
        var files: [String] = []

        /// A settled reply (or, empty, one still coming).
        static func reply(_ text: String, tools: [ChatTool] = []) -> Line {
            Line(role: .assistant, text: "", turn: ChatTurn(text: text, tools: tools, streaming: text.isEmpty && tools.isEmpty))
        }
    }

    private(set) var lines: [Line] = []
    var draft = ""
    private(set) var attachments: [ChatContext.Attachment] = []
    private(set) var window: ChatContext.Window?
    private(set) var busy = false
    private(set) var localModels: [String] = []
    private(set) var localError: String?
    /// The reply being streamed, with any approval or question it's waiting on.
    private(set) var live: ChatStreamState?
    /// Why the last answer to an approval or question didn't go through.
    private(set) var answerError: String?

    var pendingApproval: ChatApproval? { demoApproval ?? live?.approval }
    var pendingClarify: ChatClarify? { demoClarify ?? live?.clarify }

    var provider: Provider {
        didSet { UserDefaults.standard.set(provider.rawValue, forKey: "chat.provider"); loadLocalModels() }
    }
    var localModel: String {
        didSet { UserDefaults.standard.set(localModel, forKey: "chat.localModel") }
    }
    /// Who answers the Jarvis chat (Settings → General → Island chat).
    var runChoice: ChatRunChoice {
        didSet {
            guard runChoice != oldValue else { return }
            runChoice.save()
            syncSessionHarness()
        }
    }

    @ObservationIgnored private var task: Task<Void, Never>?
    /// The live reply's row, and the token of the turn allowed to touch it.
    @ObservationIgnored private var liveID: UUID?
    @ObservationIgnored private var turnToken: UUID?
    @ObservationIgnored private var lastEventAt = Date()
    @ObservationIgnored private var sessionID: String? {
        get { UserDefaults.standard.string(forKey: "chat.session") }
        set { UserDefaults.standard.set(newValue, forKey: "chat.session") }
    }

    private init() {
        provider = Provider(rawValue: UserDefaults.standard.string(forKey: "chat.provider") ?? "") ?? .jarvis
        localModel = UserDefaults.standard.string(forKey: "chat.localModel") ?? ""
        runChoice = ChatRunChoice.load()
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

    // MARK: demo

    @ObservationIgnored private var stashedLines: [Line]?
    private var demoApproval: ChatApproval?
    private var demoClarify: ChatClarify?

    /// Made-up exchanges for the demo tour; nothing is sent.
    func showDemo(_ pairs: [(String, String)]) {
        showDemo(lines: pairs.flatMap { [Line(role: .user, text: $0.0), Line.reply($0.1)] })
    }

    /// A made-up conversation, cards included (the tour, the render tests).
    func showDemo(lines demo: [Line], approval: ChatApproval? = nil, clarify: ChatClarify? = nil) {
        if stashedLines == nil { stashedLines = lines }
        lines = demo
        demoApproval = approval
        demoClarify = clarify
    }

    func endDemo() {
        if let real = stashedLines { lines = real }
        stashedLines = nil
        demoApproval = nil
        demoClarify = nil
    }

    // MARK: sending

    func newChat() {
        stop()
        lines = []
        attachments = []
        window = nil
        sessionID = nil
        answerError = nil
    }

    /// Stop the reply: the server's turn is cancelled too, and the reply says
    /// "Stopped" (muted) rather than showing an error.
    func stop() {
        guard busy else { return }
        let stream = live?.streamID
        turnToken = nil  // the turn's task may still be unwinding; it no longer touches anything
        task?.cancel()
        live?.turn.stopped = true
        settle()
        if let stream { cancelOnServer(stream) }
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // A typed reply while Jarvis's question is open answers it.
        if pendingClarify != nil, !text.isEmpty {
            draft = ""
            answerClarify(text)
            return
        }
        guard !text.isEmpty, !busy else { return }
        draft = ""
        let files = attachments, win = window
        attachments = []
        window = nil
        answerError = nil
        lines.append(Line(role: .user, text: text, files: files.map(\.name) + (win.map { [$0.app] } ?? [])))
        let answer = Line(role: .assistant, text: "", turn: ChatTurn(streaming: true))
        lines.append(answer)
        liveID = answer.id
        live = ChatStreamState()
        lastEventAt = Date()
        busy = true
        let token = UUID()
        turnToken = token
        let provider = self.provider
        task = Task { [weak self] in
            guard let self else { return }
            do {
                if provider == .jarvis {
                    try await self.sendToJarvis(text, files: files, window: win)
                } else {
                    try await self.sendToLocal(text, files: files, window: win, base: provider.base ?? "")
                }
            } catch {
                if self.turnToken == token, !Self.isCancellation(error) { self.fail(error.localizedDescription) }
            }
            if self.turnToken == token { self.settle() }
        }
    }

    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    /// The reply is over, however it ended: never a "Thinking…" left behind.
    private func settle() {
        if var state = live {
            state.turn.finish()
            if !state.turn.hasOutput, state.turn.error == nil, !state.turn.stopped, state.turn.note == nil {
                state.turn.note = "No reply"
            }
            live = state
            publish()
        }
        live = nil
        liveID = nil
        turnToken = nil
        busy = false
    }

    /// The live reply's state onto its row.
    private func publish() {
        guard let id = liveID, let state = live, let i = lines.firstIndex(where: { $0.id == id }) else { return }
        if lines[i].turn != state.turn { lines[i].turn = state.turn }
    }

    private func fail(_ message: String) {
        live?.turn.error = message
        live?.end = .failed
        publish()
    }

    private func note(_ text: String) {
        let at = liveID.flatMap { id in lines.firstIndex { $0.id == id } } ?? lines.endIndex
        lines.insert(Line(role: .note, text: text), at: at)
    }

    // MARK: approvals and questions

    func answerApproval(_ choice: ChatApproval.Choice) {
        if demoApproval != nil { demoApproval = nil; return }
        guard let asked = live?.approval, let session = sessionID else { return }
        live?.approval = nil
        lastEventAt = Date()
        answerError = nil
        respond("/api/approval/respond", ChatApproval.respondBody(session: session, choice: choice, approvalID: asked.id)) {
            [weak self] in
            if self?.live != nil, self?.live?.end == nil { self?.live?.approval = asked }
        }
    }

    func answerClarify(_ answer: String) {
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if demoClarify != nil { demoClarify = nil; return }
        guard let asked = live?.clarify, let session = sessionID else { return }
        live?.clarify = nil
        lastEventAt = Date()
        answerError = nil
        respond("/api/clarify/respond", ChatClarify.respondBody(session: session, answer: text)) { [weak self] in
            if self?.live != nil, self?.live?.end == nil { self?.live?.clarify = asked }
        }
    }

    private func respond(_ path: String, _ body: [String: Any], restore: @escaping () -> Void) {
        Task { [weak self] in
            do {
                guard let self else { return }
                let (data, response) = try await URLSession.shared.data(for: try self.postJSON(path, body, timeout: 30))
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                    throw ChatError((obj?["error"] as? String) ?? "Jarvis didn't take the answer.")
                }
            } catch {
                restore()
                self?.answerError = error.localizedDescription
            }
        }
    }

    // MARK: Jarvis

    private func origin() throws -> String {
        guard let o = AppModel.shared.apiOrigin else {
            throw ChatError("Jarvis isn't connected on this Mac (jc-client).")
        }
        return o
    }

    private func postJSON(_ path: String, _ body: [String: Any], query: String = "", timeout: TimeInterval = 600) throws -> URLRequest {
        guard let url = URL(string: try origin() + path + query) else { throw ChatError("Bad server address.") }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    private func ensureSession() async throws -> String {
        if let id = sessionID, !id.isEmpty { return id }
        let (data, _) = try await URLSession.shared.data(for: try postJSON("/api/session/new", ["title": "Mac island"], timeout: 60))
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let inner = obj["session"] as? [String: Any] ?? [:]
        guard let id = (obj["session_id"] as? String) ?? (inner["session_id"] as? String) ?? (inner["id"] as? String)
                ?? (obj["id"] as? String), !id.isEmpty else { throw ChatError("Couldn't start a chat with Jarvis.") }
        sessionID = id
        return id
    }

    /// The chat keeps the harness a turn named, so going back to the Chat
    /// default clears it on the server.
    private func syncSessionHarness() {
        guard provider == .jarvis, let session = sessionID, !session.isEmpty else { return }
        let id: Any = runChoice == .chatDefault ? NSNull() : runChoice.harnessID
        guard let req = try? postJSON("/api/session/harness", ["session_id": session, "harness_id": id], timeout: 20) else { return }
        Task { _ = try? await URLSession.shared.data(for: req) }
    }

    private func cancelOnServer(_ stream: String) {
        guard let o = try? origin(), let url = URL(string: o + "/api/chat/cancel?stream_id=\(stream)") else { return }
        Task { _ = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 20)) }
    }

    private func upload(_ a: ChatContext.Attachment, session: String) async throws -> [String: Any]? {
        guard ChatContext.canUpload(size: a.size) else {
            note("\(a.name) is over 50 MB, so it wasn't sent")
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

    private enum PumpEnd { case ended, closed, stalled }

    private func sendToJarvis(_ text: String, files: [ChatContext.Attachment], window: ChatContext.Window?) async throws {
        var session = ""
        var bytes: URLSession.AsyncBytes?
        var http: HTTPURLResponse?
        // The island keeps its chat across launches; one deleted on the server
        // (404) is replaced by a new one, once.
        for attempt in 0..<2 {
            session = try await ensureSession()
            var uploaded: [[String: Any]] = []
            for a in files where a.inlineText == nil {
                if let u = try await upload(a, session: session) { uploaded.append(u) }
            }
            let inlined = files.filter { $0.inlineText != nil }
            let body = ChatRequest.startBody(session: session,
                                             message: ChatContext.prompt(text, attachments: inlined, window: window),
                                             attachments: uploaded, choice: runChoice)
            let (b, response) = try await URLSession.shared.bytes(for: try postJSON("/api/chat/start", body, query: "?stream=1"))
            bytes = b
            http = response as? HTTPURLResponse
            guard http?.statusCode == 404, attempt == 0 else { break }
            sessionID = nil
        }
        guard let bytes else { throw ChatError("Jarvis didn't start the reply.") }
        var end: PumpEnd
        if (http?.value(forHTTPHeaderField: "Content-Type") ?? "").contains("text/event-stream") {
            end = try await pump(bytes)
        } else {
            let obj = try await Self.json(bytes)
            if let stream = obj["stream_id"] as? String, !stream.isEmpty {
                live?.streamID = stream
                end = try await follow(stream)
            } else if http?.statusCode == 409, let running = await snapshot(session)?.activeStreamID {
                // A turn is already running on this chat: ride along with it.
                live?.streamID = running
                end = try await follow(running)
            } else {
                throw ChatError((obj["error"] as? String) ?? "Jarvis didn't start the reply.")
            }
        }

        // The stream closed or went quiet before the turn ended: re-attach while
        // the server still runs it, else take its stored reply (the phone's rule).
        var reattached = false
        var tries = 0
        while end != .ended, tries < 12, live != nil {
            tries += 1
            guard let snap = await snapshot(session) else { break }
            if let running = snap.activeStreamID {
                live?.streamID = running
                reattached = true
                end = try await follow(running)
                continue
            }
            if let stored = snap.lastAssistantText { adopt(stored, replacing: true) }
            break
        }
        // A turn that said nothing (or whose words we half missed): the server's
        // record is authoritative.
        if let state = live, !state.turn.stopped, state.turn.error == nil, reattached || !state.turn.hasText,
           let stored = await snapshot(session)?.lastAssistantText {
            adopt(stored, replacing: reattached)
        }
    }

    private func adopt(_ text: String, replacing: Bool) {
        guard var state = live, replacing || !state.turn.hasText else { return }
        state.turn.text = text
        live = state
        publish()
    }

    private func snapshot(_ session: String) async -> ChatSnapshot? {
        guard let o = try? origin(), let url = URL(string: o + "/api/session?session_id=\(session)&msg_limit=8") else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 30)),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return ChatSnapshot(json: obj)
    }

    /// `GET /api/chat/stream` — the turn's live frames (a long wait: approvals
    /// and slow tools are minutes, not seconds).
    private func follow(_ stream: String) async throws -> PumpEnd {
        guard let url = URL(string: try origin() + "/api/chat/stream?stream_id=\(stream)") else { return .closed }
        let (bytes, response) = try await URLSession.shared.bytes(for: URLRequest(url: url, timeoutInterval: 600))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return .closed }
        return try await pump(bytes)
    }

    /// Read frames until the turn ends, the socket closes, or it goes quiet.
    private func pump(_ bytes: URLSession.AsyncBytes) async throws -> PumpEnd {
        lastEventAt = Date()
        return try await withThrowingTaskGroup(of: PumpEnd.self) { group in
            group.addTask { try await self.read(bytes) }
            group.addTask {
                while true {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    if await self.stalled() { return .stalled }
                }
            }
            defer { group.cancelAll() }
            return try await group.next() ?? .closed
        }
    }

    private func stalled() -> Bool {
        ChatStall.isStalled(lastEvent: lastEventAt, now: Date(), waitingOnYou: live?.approval != nil || live?.clarify != nil)
    }

    private func read(_ bytes: URLSession.AsyncBytes) async throws -> PumpEnd {
        var parser = ChatSSE()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            // `AsyncLineSequence` drops the blank separator lines; the server's
            // frames are one JSON line each, so a data line ends its event.
            _ = parser.feed(line)
            if line.hasPrefix("data:"), let e = parser.feed(""), handle(e) { return .ended }
        }
        if let e = parser.finish(), handle(e) { return .ended }
        return .closed
    }

    /// True at the end of the turn.
    private func handle(_ e: ChatSSE.Event) -> Bool {
        guard var state = live else { return true }  // stopped
        lastEventAt = Date()
        let before = state.streamID
        if state.apply(e) || state.streamID != before {
            live = state
            publish()
        }
        return state.end != nil
    }

    private static func json(_ bytes: URLSession.AsyncBytes) async throws -> [String: Any] {
        var raw = Data()
        for try await b in bytes { raw.append(b) }
        return (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] ?? [:]
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
        for l in lines.dropLast(2) {
            switch l.role {
            case .user: history.append(["role": "user", "content": l.text])
            case .assistant where l.turn.hasText: history.append(["role": "assistant", "content": l.turn.text])
            default: break
            }
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
                live?.turn.text = LocalModel.visible(raw)
                publish()
            }
        }
    }
}

/// The harnesses and models the server offers, for the island chat's choice
/// (Settings and the chat's chip).
@MainActor
@Observable
final class ChatRunOptions {
    static let shared = ChatRunOptions()

    private(set) var harnesses: [ChatHarnessOption] = []
    private(set) var models: [ChatModelOption] = []
    private(set) var loading = false
    private(set) var error: String?

    /// Providers in the server's order (the model picker's sections).
    var providers: [String] {
        var seen = Set<String>()
        return models.compactMap { seen.insert($0.provider).inserted ? $0.provider : nil }
    }

    func models(for provider: String) -> [ChatModelOption] { models.filter { $0.provider == provider } }

    func refresh() async {
        guard !loading else { return }
        guard let origin = AppModel.shared.apiOrigin else {
            error = "Jarvis isn't connected on this Mac (jc-client)."
            return
        }
        loading = true
        defer { loading = false }
        async let h = Self.get(origin + "/api/harnesses")
        async let m = Self.get(origin + "/api/models")
        let (hj, mj) = await (h, m)
        if let hj { harnesses = ChatCatalog.harnesses(hj) }
        if let mj { models = ChatCatalog.models(mj) }
        error = hj == nil && mj == nil ? "Couldn't reach Jarvis." : nil
    }

    private static func get(_ s: String) async -> [String: Any]? {
        guard let url = URL(string: s),
              let (data, response) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 20)),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

struct ChatError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

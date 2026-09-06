import Foundation

// The realtime transport: `/api/voice/s2s/ws`. The wire format is split out as a
// pure codec so every frame the server can send is unit-testable without a socket.

// MARK: - Server → client

enum VoiceServerFrame: Equatable, Sendable {
    case ready
    /// The user's speech, as the server's STT hears it.
    case transcript(String)
    /// A chunk of the assistant's reply text.
    case assistantText(String)
    case tool(name: String, status: String)
    /// A reply segment is starting; `format` is "pcm_s16le" or "mp3".
    case audioMeta(format: String, sampleRate: Int)
    case audioEnd
    /// The server reports EVERY turn outcome here, including failures, via
    /// `reason` (see `VoiceTurnMachine.failureReasons`).
    case endTurn(reason: String)
    /// The server's end-of-turn timing summary (plan 0.2), span name → ms.
    case latency(turnID: String, spans: [String: Double])
    /// The slow lane finished after we already answered a turn locally.
    case escalationResult(String)
    /// A binary audio frame for the current segment.
    case audio(Data)
    /// A type we don't handle; carried so it can be logged, not dropped silently.
    case other(String)

    static func decode(text: String) -> VoiceServerFrame? {
        guard let data = text.data(using: .utf8),
              let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return decode(object: msg)
    }

    static func decode(object msg: [String: Any]) -> VoiceServerFrame {
        switch msg.string("type") ?? "" {
        case "ready":
            return .ready
        case "transcript":
            return .transcript(msg.string("text") ?? "")
        case "assistant_text":
            return .assistantText(msg.string("text") ?? "")
        case "tool":
            return .tool(name: msg.string("name") ?? "tool",
                         status: msg.string("status") ?? "started")
        case "audio_meta":
            // The server sends `"sample_rate": 0` alongside `"format": "mp3"`
            // (voice.py `_send_audio`) — the container carries its own rate.
            // Zero must never reach the player: `AVAudioFormat(sampleRate: 0)`
            // is nil, which latches gapless playback off for the whole launch,
            // and `AudioQueue` divides by it to size a segment.
            let rate = msg.int("sample_rate") ?? 0
            return .audioMeta(format: msg.string("format") ?? "pcm_s16le",
                              sampleRate: rate > 0 ? rate : 24000)
        case "audio_end":
            return .audioEnd
        case "end_turn":
            return .endTurn(reason: msg.string("reason") ?? "")
        case "latency":
            // Current servers send `{"turn_id":…, "spans":{name: ms, …}}`
            // (voice.py `_finish_turn_timing`); older ones sent a single flat
            // `span`/`ms` pair. Accept both so a mixed fleet still parses.
            var spans: [String: Double] = [:]
            for (name, value) in msg.dict("spans") ?? [:] {
                if let ms = (value as? NSNumber)?.doubleValue { spans[name] = ms }
            }
            if spans.isEmpty, let span = msg.string("span") {
                spans[span] = msg.double("ms") ?? 0
            }
            return .latency(turnID: msg.string("turn_id") ?? "", spans: spans)
        case "escalation_result":
            return .escalationResult(msg.string("text") ?? "")
        case let other:
            return .other(other)
        }
    }
}

// MARK: - Client → server

enum VoiceClientMessage: Equatable, Sendable {
    /// Opens (or resets) the server's per-turn audio buffer.
    case beginTurn(sampleRate: Int, sessionID: String?, model: String?, provider: String?)
    /// Run the agent on this turn. `text` is our on-device transcript when we
    /// have one — the server then skips its own STT.
    ///
    /// `clientTs` / `speechEndTs` let the server line its own spans up with the
    /// moment the user actually stopped talking (plan 0.2). Extra keys are
    /// ignored by older servers, so this stays backward compatible.
    case endTurn(text: String?, clientTs: Int, speechEndTs: Int?, turnID: String?)
    case interrupt

    var payload: [String: Any] {
        switch self {
        case .beginTurn(let sampleRate, let sessionID, let model, let provider):
            var o: [String: Any] = ["type": "begin_turn", "sample_rate": sampleRate]
            if let sessionID, !sessionID.isEmpty { o["session_id"] = sessionID }
            if let model, !model.isEmpty { o["model"] = model }
            if let provider, !provider.isEmpty { o["model_provider"] = provider }
            return o
        case .endTurn(let text, let clientTs, let speechEndTs, let turnID):
            var o: [String: Any] = ["type": "end_turn", "client_ts": clientTs]
            if let text, !text.isEmpty { o["text"] = text }
            if let speechEndTs { o["speech_end_ts"] = speechEndTs }
            if let turnID, !turnID.isEmpty { o["turn_id"] = turnID }
            return o
        case .interrupt:
            return ["type": "interrupt"]
        }
    }

    /// Sorted keys so a test can compare the exact string.
    func encoded() -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }
}

// MARK: - Session

/// Owns one realtime socket and translates frames both ways. Deliberately dumb:
/// it knows the wire, not the FSM (that's `VoiceTurnMachine`).
@MainActor
final class VoiceSession {
    private let voice: VoiceAPI
    private let connector: VoiceSocketConnecting
    private var socket: VoiceSocket?

    var onFrame: ((VoiceServerFrame) -> Void)?
    var onClose: ((Error?) -> Void)?
    /// One privacy-safe trace line per frame, for ``VoiceDiagnostics``. The
    /// session knows the wire, so it is the only place that can report what was
    /// actually put on it (vs. what the store meant to send).
    var onLog: ((String) -> Void)?

    var isOpen: Bool { socket != nil }

    init(voice: VoiceAPI, connector: VoiceSocketConnecting) {
        self.voice = voice
        self.connector = connector
    }

    func open(params: [String: String] = [:]) async throws {
        close()
        let url = try voice.realtimeURL(params: params)
        // Path + auth-header NAMES only: the cookie value and the CF-Access
        // secret must never reach a log the user can screenshot.
        onLog?("ws open \(url.path) auth=\(voice.api.credentials.headers.keys.sorted().joined(separator: ","))")
        let s = try await connector.connect(url: url, headers: voice.api.credentials.headers)
        s.onFrame = { [weak self] frame in
            guard let self else { return }
            switch frame {
            case .text(let t):
                guard let f = VoiceServerFrame.decode(text: t) else {
                    // Not JSON at all. Dropping it silently is how a server that
                    // started sending something else looks like a dead socket.
                    self.onLog?("ws← undecodable text \(t.utf8.count)B")
                    return
                }
                self.onLog?(VoiceDiagnostics.describe(received: f))
                self.onFrame?(f)
            case .binary(let d):
                let f = VoiceServerFrame.audio(d)
                self.onLog?(VoiceDiagnostics.describe(received: f))
                self.onFrame?(f)
            }
        }
        s.onClose = { [weak self] error in
            guard let self else { return }
            self.socket = nil
            self.onLog?("ws closed \(error.map { apiErrorMessage($0) } ?? "(clean)")")
            self.onClose?(error)
        }
        socket = s
    }

    /// False when there is no live socket to send on. A dropped message used to
    /// vanish, leaving the caller waiting on a reply that can never arrive.
    @discardableResult
    func send(_ message: VoiceClientMessage) -> Bool {
        guard let socket else {
            JcLog.voice.error("voice send with no socket: \(message.payload["type"] as? String ?? "?", privacy: .public)")
            onLog?("ws→ DROPPED (no socket) \(message.payload["type"] as? String ?? "?")")
            return false
        }
        onLog?(VoiceDiagnostics.describe(sent: message))
        socket.send(text: message.encoded())
        return true
    }

    @discardableResult
    func send(pcm: Data) -> Bool {
        guard let socket else { return false }
        socket.send(data: pcm)
        return true
    }

    /// Tear down without reporting a close (we asked for it).
    func close() {
        let s = socket
        socket = nil
        s?.onClose = nil
        s?.onFrame = nil
        s?.close()
    }
}

// MARK: - URLSession implementation

/// `URLSessionWebSocketTask`. The Flutter client hand-rolled the HTTP upgrade so
/// it could accept a pinned self-signed certificate; here trust is whatever
/// `URLSession` accepts, matching the rest of `JarvisAPI`.
@MainActor
final class URLSessionVoiceSocketConnector: VoiceSocketConnecting {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session { self.session = session; return }
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)
    }

    func connect(url: URL, headers: [String: String]) async throws -> VoiceSocket {
        var request = URLRequest(url: url)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let task = session.webSocketTask(with: request)
        let socket = URLSessionVoiceSocket(task: task)
        task.resume()
        socket.pump()
        return socket
    }
}

@MainActor
final class URLSessionVoiceSocket: VoiceSocket {
    var onFrame: ((VoiceSocketFrame) -> Void)?
    var onClose: ((Error?) -> Void)?

    private let task: URLSessionWebSocketTask
    private var closed = false
    private var receiver: Task<Void, Never>?

    init(task: URLSessionWebSocketTask) { self.task = task }

    /// One receive loop; the first failure closes us.
    func pump() {
        receiver = Task { @MainActor [weak self] in
            while true {
                guard let self, !self.closed else { return }
                do {
                    switch try await self.task.receive() {
                    case .string(let s): self.onFrame?(.text(s))
                    case .data(let d): self.onFrame?(.binary(d))
                    @unknown default: break
                    }
                } catch {
                    guard !self.closed else { return }
                    self.closed = true
                    self.onClose?(error)
                    return
                }
            }
        }
    }

    /// A send failure is a dead socket: `URLSessionWebSocketTask` reports it in
    /// the completion handler and NOT through `receive()`, so discarding it left
    /// the turn waiting on a reply that could never come.
    func send(text: String) {
        task.send(.string(text)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in self?.fail(error) }
        }
    }

    func send(data: Data) {
        task.send(.data(data)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in self?.fail(error) }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        receiver?.cancel()
        receiver = nil
        task.cancel(with: .goingAway, reason: nil)
    }

    /// Report a socket-level failure exactly once, then stop.
    private func fail(_ error: Error) {
        guard !closed else { return }
        closed = true
        receiver?.cancel()
        receiver = nil
        task.cancel(with: .goingAway, reason: nil)
        onClose?(error)
    }

    /// The receive loop keeps the task alive on its own; without this a socket
    /// the server closed leaks both until the process ends.
    deinit {
        receiver?.cancel()
        task.cancel(with: .goingAway, reason: nil)
    }
}

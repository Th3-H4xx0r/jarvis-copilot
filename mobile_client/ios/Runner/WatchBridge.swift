import Foundation
import UIKit
import WatchConnectivity

// MARK: - Pure, testable relay helpers (no I/O — unit-tested in WatchBridgeTests)

enum WatchRelay {
    /// Parse an SSE buffer in the webui chat-stream format:
    ///   event: <name>\n data: <json>\n\n
    /// The server (webui/api/streaming.py) emits assistant text as `token`
    /// events, signals failures as `apperror`, and terminates the stream with
    /// `stream_end` (`done` carries {session,usage}, no top-level text). We
    /// accept `done` too as a terminator and `cancel`/`error` as failures for
    /// forward-compat. Returns accumulated text, whether the stream ended, and
    /// whether it errored.
    static func accumulateSSE(_ buffer: String) -> (text: String, done: Bool, errored: Bool) {
        var text = ""
        var done = false
        var errored = false
        var currentEvent = ""
        for rawLine in buffer.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix(":") { continue } // heartbeat comment
            if line.hasPrefix("event:") {
                currentEvent = line.dropFirst("event:".count).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                let json = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                guard let d = json.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
                else { continue }
                switch currentEvent {
                case "token": if let t = obj["text"] as? String { text += t }
                case "stream_end", "done": done = true
                case "apperror", "error", "cancel": errored = true
                default: break
                }
            }
        }
        return (text, done, errored)
    }

    /// `/api/session/new` nests the id under `session.session_id`; some endpoints
    /// expose it top-level. Handle both.
    static func extractSessionId(_ obj: [String: Any]) -> String? {
        if let s = obj["session_id"] as? String, !s.isEmpty { return s }
        if let inner = obj["session"] as? [String: Any],
           let s = inner["session_id"] as? String, !s.isEmpty { return s }
        return nil
    }
}

private struct RelayError: Error { let detail: String }

// MARK: - WatchBridge: WCSession delegate + native (engine-free) backend relay

/// Bridges the Apple Watch to the backend. Activated in
/// `AppDelegate.didFinishLaunchingWithOptions` so it's live even when iOS is
/// background-launched by `WCSession.sendMessage`. Performs the backend
/// round-trip natively (cert-pinned async `URLSession`, no Flutter engine) —
/// mirroring `AppDelegate._pushLocationNatively`/`PinnedPoster`. Credentials
/// come from `UserDefaults` (written by the Dart `jarviscopilot/watch` sync).
///
/// The assistant TEXT is returned synchronously via the sendMessage reply; the
/// spoken JARVIS-voice clip is delivered out-of-band via `transferFile` to keep
/// the reply payload small (WCSession reply payloads are size-limited).
final class WatchBridge: NSObject, WCSessionDelegate {
    static let shared = WatchBridge()

    private let stateLock = NSLock()
    private var lastLoggedIn = false
    private var lastStreamPush = Date(timeIntervalSince1970: 0)

    func activate() {
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        s.delegate = self
        s.activate()
    }

    /// Push the current login-state to the watch so it can show its setup
    /// screen before the user taps. Cached so it can be re-pushed once the
    /// session finishes activating (a push during the activation window is
    /// otherwise dropped).
    func pushLoginState(_ loggedIn: Bool) {
        stateLock.lock(); lastLoggedIn = loggedIn; stateLock.unlock()
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        guard s.activationState == .activated else { return }
        try? s.updateApplicationContext(["loggedIn": loggedIn])
    }

    /// Push the partial answer to the watch as tokens stream in, so the reply
    /// builds up live (like the web UI). Throttled (~3/sec) since
    /// `updateApplicationContext` coalesces; the final full text still arrives
    /// authoritatively via the sendMessage reply.
    private func pushStreaming(_ text: String) {
        let now = Date()
        guard now.timeIntervalSince(lastStreamPush) > 0.3 else { return }
        lastStreamPush = now
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        stateLock.lock(); let li = lastLoggedIn; stateLock.unlock()
        try? WCSession.default.updateApplicationContext(["loggedIn": li, "streamingText": text])
    }

    /// Live WCSession state for the phone-app "Watch Companion" screen.
    func status() -> [String: Any] {
        guard WCSession.isSupported() else {
            return ["supported": false, "paired": false,
                    "watchAppInstalled": false, "reachable": false, "activationState": 0]
        }
        let s = WCSession.default
        return [
            "supported": true,
            "paired": s.isPaired,
            "watchAppInstalled": s.isWatchAppInstalled,
            "reachable": s.isReachable,
            "activationState": s.activationState.rawValue,   // 0 notActivated, 1 inactive, 2 activated
        ]
    }

    // MARK: WCSessionDelegate
    func session(_ s: WCSession, activationDidCompleteWith _: WCSessionActivationState, error _: Error?) {
        // Flush the latest login-state once activation completes.
        stateLock.lock(); let loggedIn = lastLoggedIn; stateLock.unlock()
        if s.activationState == .activated {
            try? s.updateApplicationContext(["loggedIn": loggedIn])
        }
    }
    func sessionDidBecomeInactive(_ s: WCSession) {}
    func sessionDidDeactivate(_ s: WCSession) { s.activate() }

    func session(_ s: WCSession, didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        guard (message["type"] as? String) == "ask",
              let text = (message["text"] as? String),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            replyHandler(["ok": false, "error": "network", "detail": "bad request"])
            return
        }
        // Each ask runs in its own Task — no shared queue, no head-of-line blocking.
        Task { await self.runRelay(text: text, replyHandler: replyHandler) }
    }

    // MARK: native async relay
    private func runRelay(text: String, replyHandler: @escaping ([String: Any]) -> Void) async {
        let d = UserDefaults.standard
        var base = (d.string(forKey: "jc_server_url") ?? "").trimmingCharacters(in: .whitespaces)
        let cookie = d.string(forKey: "jc_cookie") ?? ""
        let pin = d.string(forKey: "jc_cert_sha256") ?? ""
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty, !cookie.isEmpty else {
            replyHandler(["ok": false, "error": "not_configured"])
            return
        }

        // Run the whole round-trip in one cancellable task that RETURNS the
        // reply dict. The reply handler is called exactly once, here. The
        // JARVIS-voice clip is included IN the reply (capped) so it plays
        // immediately on the watch; larger replies omit it and the watch
        // speaks the text with its built-in voice.
        let work = Task { () -> [String: Any] in
            let session = URLSession(configuration: .ephemeral,
                                     delegate: PinnedPoster(pinHex: pin), delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            do {
                let sid = try await self.ensureSession(session, base, cookie)
                let streamId = try await self.chatStart(session, base, cookie, sid, text)
                let reply = try await self.streamReply(session, base, cookie, streamId)
                guard !reply.isEmpty else {
                    return ["ok": false, "error": "network", "detail": "empty"]
                }
                var out: [String: Any] = ["ok": true, "replyText": reply]
                // The JARVIS-voice clip is too big for the (size-limited) reply
                // payload, so it's delivered OUT-OF-BAND via `transferFile`; the
                // watch plays it on receipt. `expectsClip` tells the watch a clip
                // is coming (so it doesn't also speak with its built-in voice);
                // `voiceDbg` surfaces what happened (shown on-watch while debugging).
                do {
                    let audio = try await self.synthesize(session, base, cookie, reply)
                    let kb = audio.count / 1024
                    self.sendVoiceClip(audio)
                    out["expectsClip"] = true
                    out["voiceDbg"] = "clip \(kb)KB → file"
                } catch let e as RelayError {
                    out["voiceDbg"] = e.detail
                } catch {
                    out["voiceDbg"] = "synth err"
                }
                return out
            } catch is CancellationError {
                return ["ok": false, "error": "network", "detail": "expired"]
            } catch let e as RelayError {
                return ["ok": false, "error": "network", "detail": e.detail]
            } catch {
                return ["ok": false, "error": "network", "detail": "io"]
            }
        }

        // Keep the process alive for the round-trip; cancel the work if iOS
        // expires our background time (so we don't run suspended/forever).
        let bgId = await MainActor.run {
            UIApplication.shared.beginBackgroundTask(withName: "jcWatchRelay") { work.cancel() }
        }
        replyHandler(await work.value)
        if bgId != .invalid {
            await MainActor.run { UIApplication.shared.endBackgroundTask(bgId) }
        }
    }

    // MARK: HTTP (async; per-request timeouts; cancellation-aware)
    private func httpData(_ session: URLSession, _ req: URLRequest) async throws -> (Data, Int) {
        let (data, resp) = try await session.data(for: req)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private func postJSON(_ session: URLSession, _ url: URL, _ cookie: String,
                          _ body: [String: Any], accept: String = "application/json") async throws -> (Data, Int) {
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(accept, forHTTPHeaderField: "Accept")
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return try await httpData(session, req)
    }

    private func ensureSession(_ session: URLSession, _ base: String, _ cookie: String) async throws -> String {
        let d = UserDefaults.standard
        if let cached = d.string(forKey: "jc_watch_session_id"), !cached.isEmpty { return cached }
        guard let url = URL(string: base + "/api/session/new") else { throw RelayError(detail: "session") }
        let (data, code) = try await postJSON(session, url, cookie, ["title": "Apple Watch"])
        guard code == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sid = WatchRelay.extractSessionId(obj) else { throw RelayError(detail: "session") }
        d.set(sid, forKey: "jc_watch_session_id")
        return sid
    }

    private func chatStart(_ session: URLSession, _ base: String, _ cookie: String,
                           _ sid: String, _ text: String) async throws -> String {
        guard let url = URL(string: base + "/api/chat/start") else { throw RelayError(detail: "chat_start") }
        let (data, code) = try await postJSON(session, url, cookie, ["session_id": sid, "message": text])
        guard code == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streamId = obj["stream_id"] as? String, !streamId.isEmpty else {
            // The cached session may have gone away — drop it so the next ask recreates one.
            UserDefaults.standard.removeObject(forKey: "jc_watch_session_id")
            throw RelayError(detail: "chat_start")
        }
        return streamId
    }

    private func streamReply(_ session: URLSession, _ base: String, _ cookie: String, _ streamId: String) async throws -> String {
        guard var comps = URLComponents(string: base + "/api/chat/stream") else { throw RelayError(detail: "stream") }
        comps.queryItems = [URLQueryItem(name: "stream_id", value: streamId)]
        guard let url = comps.url else { throw RelayError(detail: "stream") }
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        // Consume the SSE INCREMENTALLY and return the instant the terminator
        // arrives — do NOT use data(for:) which waits for the connection to
        // close. The server keeps the stream open with heartbeats for minutes
        // after the answer, which made the watch hang on "thinking". (The webui
        // is fast for the same reason: it stops reading on stream_end.)
        let (bytes, resp) = try await session.bytes(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw RelayError(detail: "stream") }
        var text = ""
        var currentEvent = ""
        for try await line in bytes.lines {
            if line.hasPrefix(":") { continue } // heartbeat comment
            if line.hasPrefix("event:") {
                currentEvent = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                let json = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
                guard let d = json.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                switch currentEvent {
                case "token":
                    if let t = obj["text"] as? String { text += t; pushStreaming(text) }
                case "stream_end", "done": return text          // answer complete — stop reading now
                case "apperror", "error", "cancel": throw RelayError(detail: "stream")
                default: break
                }
            }
        }
        return text
    }

    private func synthesize(_ session: URLSession, _ base: String, _ cookie: String, _ text: String) async throws -> Data {
        guard let url = URL(string: base + "/api/voice/synthesize") else { throw RelayError(detail: "synth: bad url") }
        let (data, code) = try await postJSON(session, url, cookie, ["text": text], accept: "audio/mpeg")
        guard code == 200 else { throw RelayError(detail: "synth HTTP \(code)") }
        guard !data.isEmpty else { throw RelayError(detail: "synth empty") }
        return data
    }

    // MARK: voice-clip out-of-band delivery
    /// Write the MP3 to a temp file and `transferFile` it to the watch (no
    /// payload-size limit, unlike the sendMessage reply). The temp file is
    /// removed in `didFinish` once the transfer completes.
    private func sendVoiceClip(_ data: Data) {
        guard WCSession.isSupported() else { return }
        // Cancel any still-queued clips so a backlog (e.g. from earlier
        // unreachable-watch sends) doesn't all deliver at once and play
        // repeatedly — only the newest reply should play.
        WCSession.default.outstandingFileTransfers.forEach { $0.cancel() }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jc_voice_\(UUID().uuidString).mp3")
        do {
            try data.write(to: url)
            WCSession.default.transferFile(url, metadata: ["type": "voiceClip"])
        } catch { try? FileManager.default.removeItem(at: url) }
    }

    func session(_ s: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error _: Error?) {
        try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
    }
}

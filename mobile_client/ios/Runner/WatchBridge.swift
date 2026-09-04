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

    /// plan 1.6a — incremental sentence splitter fed SSE text deltas as they
    /// arrive, so synthesis of sentence N can start while the stream keeps
    /// going instead of waiting for the whole reply (`WatchBridge.streamReply`
    /// used to accumulate everything first).
    ///
    /// Mirrors the server's `_take_complete_sentences`
    /// (webui/api/voice.py:1105): the FIRST sentence flushes at ANY
    /// terminator (min_len 0 — a near-instant ack), every later one only
    /// once the buffer holds >=110 chars (so we don't fire off a synth call
    /// per word). One call may flush more than one sentence at once — it
    /// takes everything up to the LAST terminator in the buffer, exactly
    /// like the server.
    final class SentenceSplitter {
        /// Non-first-sentence flush threshold. plan 1.6a.
        private static let minLenAfterFirst = 110
        private static let terminator = try! NSRegularExpression(
            pattern: "[.!?](?:[\"')\\]]+)?(?:\\s|$)")

        private var buffer = ""
        private var firstEmitted = false

        /// Feed one text delta; returns zero or more sentence chunks now
        /// ready to speak (usually zero or one).
        func feed(_ delta: String) -> [String] {
            buffer += delta
            var out: [String] = []
            while let chunk = takeComplete() { out.append(chunk) }
            return out
        }

        /// Stream ended — flush whatever remains, even without a terminator.
        func finish() -> String? {
            let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = ""
            return rest.isEmpty ? nil : rest
        }

        private func takeComplete() -> String? {
            let minLen = firstEmitted ? Self.minLenAfterFirst : 0
            guard buffer.count >= minLen else { return nil }
            let ns = buffer as NSString
            let matches = Self.terminator.matches(in: buffer, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { return nil }
            let cut = last.range.location + last.range.length
            let head = ns.substring(to: cut).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = ns.substring(from: cut)
            firstEmitted = true
            return head.isEmpty ? nil : head
        }
    }

    /// plan 1.6c — pure decision logic for the watch's instant spoken ack.
    ///
    /// This is a byte-for-byte port of `AckTimer` in
    /// `JarvisWatch Watch App/AckTimer.swift`. It has to be duplicated rather
    /// than shared: the Watch App and Runner are separate compiled targets
    /// with no common framework between them, and `RunnerTests` (the only
    /// test target that actually exists in project.pbxproj — see the
    /// "no JarvisWatch Watch AppTests target" note in F-report.md) can only
    /// see Runner-visible code. Keep the two copies in sync if the decision
    /// logic ever changes.
    enum AckTimer {
        /// How long the watch waits for the hi-fi clip before falling back to
        /// its own voice. plan 1.6.
        static let localVoiceFallbackMs = 700

        enum Decision: Equatable {
            case wait          // keep waiting for the hi-fi clip
            case speakLocally  // speak the sentence with the built-in voice now
            case clipWon       // the hi-fi clip already arrived — nothing to do
        }

        static func decide(elapsedMs: Int, clipArrived: Bool, preferLocalVoice: Bool) -> Decision {
            if clipArrived { return .clipWon }
            if preferLocalVoice { return .speakLocally }
            return elapsedMs >= localVoiceFallbackMs ? .speakLocally : .wait
        }
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
    /// plan 1.6b/3 — bumped once per `runRelay` call so the pipelined,
    /// unstructured synth `Task`s from a PREVIOUS turn can tell they're
    /// stale (the phone can start a new `ask` while a slow synth from the
    /// last one is still in flight) and drop their clip instead of it
    /// landing after the new turn's audio has already started.
    private var turnCounter = 0
    private var activeTurnId = 0

    /// Register the start of a new turn and return its id.
    private func beginTurn() -> Int {
        stateLock.lock(); defer { stateLock.unlock() }
        turnCounter += 1
        activeTurnId = turnCounter
        return turnCounter
    }

    /// Whether `turnId` is still the most recent turn — false once a later
    /// `ask` has started, meaning this turn's leftover work is stale.
    private func isActiveTurn(_ turnId: Int) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return activeTurnId == turnId
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        s.delegate = self
        s.activate()
        prewarmSession()  // plan 1.6d
    }

    /// plan 1.6d: create/verify the backend session eagerly, OFF the hot
    /// path, so `runRelay` on the next `ask` only pays `chat/start`, not
    /// also `session/new`. Called on activation and again whenever the
    /// watch becomes reachable (`sessionReachabilityDidChange`). Best-effort:
    /// errors are swallowed — `ensureSession` still runs lazily on the hot
    /// path if this hasn't finished (or hasn't run) yet.
    private func prewarmSession() {
        Task {
            let d = UserDefaults.standard
            var base = (d.string(forKey: "jc_server_url") ?? "").trimmingCharacters(in: .whitespaces)
            let cookie = d.string(forKey: "jc_cookie") ?? ""
            let pin = d.string(forKey: "jc_cert_sha256") ?? ""
            while base.hasSuffix("/") { base.removeLast() }
            guard !base.isEmpty, !cookie.isEmpty else { return }
            let session = URLSession(configuration: .ephemeral,
                                     delegate: PinnedPoster(pinHex: pin), delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            _ = try? await self.ensureSession(session, base, cookie)
        }
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
        // plan 1.6c fix: `updateApplicationContext` REPLACES the whole
        // context, not just the keys we pass. Merge onto the current
        // context (like `pushFirstSentence` already does) instead of
        // stomping it wholesale — otherwise a streaming-text tick landing
        // after `pushFirstSentence` but before its clip arrives silently
        // erases `firstSentence`/`firstSentenceNonce`, and the watch's
        // instant-ack timer never gets a nonce to act on for that turn.
        var ctx = WCSession.default.applicationContext
        ctx["loggedIn"] = li
        ctx["streamingText"] = text
        try? WCSession.default.updateApplicationContext(ctx)
    }

    /// plan 1.6c: push the first sentence's TEXT the instant it's known —
    /// UNTHROTTLED (unlike `pushStreaming`), so the watch's instant-ack
    /// countdown starts as early as possible instead of waiting up to 300 ms
    /// for the next streaming-text tick.
    private func pushFirstSentence(_ text: String) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        stateLock.lock(); let li = lastLoggedIn; stateLock.unlock()
        var ctx = WCSession.default.applicationContext
        ctx["loggedIn"] = li
        ctx["firstSentence"] = text
        ctx["firstSentenceNonce"] = Int(Date().timeIntervalSince1970 * 1000)
        try? WCSession.default.updateApplicationContext(ctx)
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

    /// Agent → watch: pulse the watch haptic `count` times. Delivered via
    /// applicationContext (a bumped nonce makes the watch act on it); the watch
    /// plays WKInterfaceDevice haptics in a loop. Best-effort (needs the watch
    /// paired + app installed).
    func sendHaptic(count: Int) {
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        guard s.activationState == .activated else { return }
        stateLock.lock(); let loggedIn = lastLoggedIn; stateLock.unlock()
        var ctx = s.applicationContext
        ctx["loggedIn"] = loggedIn
        ctx["hapticNonce"] = Int(Date().timeIntervalSince1970 * 1000)
        ctx["hapticCount"] = max(1, min(count, 10))
        try? s.updateApplicationContext(ctx)
    }

    /// Agent → watch: play an audio clip (e.g. a JARVIS-voice TTS clip) on the
    /// watch. Reuses the same out-of-band transferFile path the reply audio uses
    /// (metadata type "voiceClip"), so the watch enqueues + plays it.
    func sendClip(_ data: Data) {
        guard WCSession.isSupported(),
              WCSession.default.activationState == .activated else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jc_watch_clip_\(Int(Date().timeIntervalSince1970 * 1000)).m4a")
        do {
            try data.write(to: url)
            WCSession.default.transferFile(url, metadata: ["type": "voiceClip"])
        } catch {}
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

    /// plan 1.6d: the watch just came in reach — pre-warm the session again
    /// so a subsequent `ask` doesn't pay `session/new` on the hot path.
    func sessionReachabilityDidChange(_ s: WCSession) {
        if s.isReachable { prewarmSession() }
    }

    func session(_ s: WCSession, didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        guard (message["type"] as? String) == "ask",
              let text = (message["text"] as? String),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            replyHandler(["ok": false, "error": "network", "detail": "bad request"])
            return
        }
        // plan 1.6c/e: the watch tells us whether it's pinned to its
        // built-in voice, in which case we skip synthesis + clip transfer
        // entirely (it would just be discarded on arrival).
        let preferLocalVoice = (message["preferLocalVoice"] as? Bool) ?? false
        // Each ask runs in its own Task — no shared queue, no head-of-line blocking.
        Task { await self.runRelay(text: text, preferLocalVoice: preferLocalVoice, replyHandler: replyHandler) }
    }

    // MARK: native async relay
    private func runRelay(text: String, preferLocalVoice: Bool,
                          replyHandler: @escaping ([String: Any]) -> Void) async {
        let d = UserDefaults.standard
        var base = (d.string(forKey: "jc_server_url") ?? "").trimmingCharacters(in: .whitespaces)
        let cookie = d.string(forKey: "jc_cookie") ?? ""
        let pin = d.string(forKey: "jc_cert_sha256") ?? ""
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty, !cookie.isEmpty else {
            replyHandler(["ok": false, "error": "not_configured"])
            return
        }

        // plan 1.6b/3: this turn's id — the pipeline's `deliver` closure
        // below checks it before ever touching WCSession, so a synth `Task`
        // still in flight from a turn the phone has since moved on from
        // (the watch fired another `ask` before this one's pipeline drained)
        // can never deliver its clip into the new turn.
        let turnId = beginTurn()

        // Run the whole round-trip in one cancellable task that RETURNS the
        // reply dict. The reply handler is called exactly once, here. The
        // JARVIS-voice clip is ALWAYS synthesized (any length, unless the
        // watch is pinned to its built-in voice) and delivered out-of-band;
        // the watch's built-in voice is only a fallback if synth fails or
        // (plan 1.6c) hasn't arrived within its instant-ack window.
        let work = Task { () -> [String: Any] in
            let session = URLSession(configuration: .ephemeral,
                                     delegate: PinnedPoster(pinHex: pin), delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            do {
                let sid = try await self.ensureSession(session, base, cookie)
                // plan 1.6a/b: sentences are synthesized AS the SSE stream
                // delivers them (up to 2 ahead), not after the whole reply
                // has been accumulated. `seq` is assigned here, synchronously,
                // in the exact order sentences complete — the pipeline
                // delivers clips in that same order regardless of which
                // synth call happens to finish first.
                var seq = 0
                var firstSentenceSent = false
                let pipeline: SentencePipeline? = preferLocalVoice ? nil : SentencePipeline(
                    maxAhead: 2,
                    synthesize: { chunk in try await self.synthesize(session, base, cookie, chunk) },
                    deliver: { [weak self] data, s, isFirst in
                        // plan 1.6/3: drop a clip from a turn the phone has
                        // already moved past — see `turnId` above.
                        guard let self, self.isActiveTurn(turnId) else { return }
                        self.sendVoiceClip(data, seq: s, isFirst: isFirst)
                    })
                let onSentence: (String) -> Void = { sentence in
                    guard self.isActiveTurn(turnId) else { return }
                    if !firstSentenceSent {
                        firstSentenceSent = true
                        // plan 1.6c: push the first sentence's TEXT the
                        // instant it's known (bypassing the streamingText
                        // throttle) so the watch can start its instant-ack
                        // countdown without waiting for the hi-fi clip.
                        self.pushFirstSentence(sentence)
                    }
                    guard let pipeline = pipeline else { return }
                    let mySeq = seq; seq += 1
                    Task { await pipeline.push(seq: mySeq, text: sentence) }
                }
                let reply = try await self.chatStartAndStream(
                    session, base, cookie, sid, text, onSentence: onSentence)
                guard !reply.isEmpty else {
                    return ["ok": false, "error": "network", "detail": "empty"]
                }
                var out: [String: Any] = ["ok": true, "replyText": reply]
                if let pipeline {
                    await pipeline.waitForCompletion()
                    let sentAny = await pipeline.sentAny
                    out["expectsClip"] = sentAny
                    out["voiceDbg"] = sentAny ? "clips → file" : "no audio"
                } else {
                    out["expectsClip"] = false
                    out["voiceDbg"] = "local voice (preferLocalVoice)"
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

    /// Stamp the session cookie AND (when configured) the Cloudflare Access
    /// service-token headers onto a request. The watch relays through this
    /// phone-side native HTTP path; if the server is behind a CF tunnel, every
    /// request needs these headers or Access 302-redirects it → the watch shows
    /// "cannot reach". The token is mirrored into UserDefaults by the Dart side
    /// (WatchSync) under jc_cf_client_id / jc_cf_client_secret.
    private func authHeaders(_ req: inout URLRequest, _ cookie: String) {
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        let d = UserDefaults.standard
        let cfId = (d.string(forKey: "jc_cf_client_id") ?? "").trimmingCharacters(in: .whitespaces)
        let cfSecret = (d.string(forKey: "jc_cf_client_secret") ?? "").trimmingCharacters(in: .whitespaces)
        if !cfId.isEmpty && !cfSecret.isEmpty {
            req.setValue(cfId, forHTTPHeaderField: "CF-Access-Client-Id")
            req.setValue(cfSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
        }
    }

    private func postJSON(_ session: URLSession, _ url: URL, _ cookie: String,
                          _ body: [String: Any], accept: String = "application/json") async throws -> (Data, Int) {
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(accept, forHTTPHeaderField: "Accept")
        authHeaders(&req, cookie)
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

    /// plan 1.6d: try `POST /api/chat/start?stream=1` first — a newer server
    /// (WS-C) streams the SSE reply directly from this same request, so we
    /// never issue the separate `GET /api/chat/stream` at all. Feature-detect
    /// via the response `Content-Type`: an older server just returns JSON
    /// with a `stream_id`, and we fall back to the classic two-step flow —
    /// same request/response shape as before, so this is fully backward
    /// compatible with an older server.
    private func chatStartAndStream(_ session: URLSession, _ base: String, _ cookie: String,
                                    _ sid: String, _ text: String,
                                    onSentence: @escaping (String) -> Void) async throws -> String {
        guard let url = URL(string: base + "/api/chat/start?stream=1") else { throw RelayError(detail: "chat_start") }
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")
        authHeaders(&req, cookie)
        // `voice: true` tells the server this is a spoken turn so it prepends
        // the voice-reply directive (terse, ack-only, no step narration) — the
        // same shape phone/web voice gets.
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["session_id": sid, "message": text, "voice": true])

        let (bytes, resp) = try await session.bytes(for: req)
        guard let http = resp as? HTTPURLResponse else { throw RelayError(detail: "chat_start") }
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        if http.statusCode == 200, contentType.contains("text/event-stream") {
            // New server: `chat/start` IS the stream — consume it directly.
            return try await consumeSSE(bytes, onSentence: onSentence)
        }
        // Old server (or an error) — drain the JSON body, exactly what the
        // classic `chatStart` used to do, then fall back to the separate
        // `GET /api/chat/stream`.
        var data = Data()
        for try await byte in bytes { data.append(byte) }
        guard http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streamId = obj["stream_id"] as? String, !streamId.isEmpty else {
            // The cached session may have gone away — drop it so the next ask recreates one.
            UserDefaults.standard.removeObject(forKey: "jc_watch_session_id")
            throw RelayError(detail: "chat_start")
        }
        return try await streamReply(session, base, cookie, streamId, onSentence: onSentence)
    }

    private func streamReply(_ session: URLSession, _ base: String, _ cookie: String, _ streamId: String,
                             onSentence: @escaping (String) -> Void) async throws -> String {
        guard var comps = URLComponents(string: base + "/api/chat/stream") else { throw RelayError(detail: "stream") }
        comps.queryItems = [URLQueryItem(name: "stream_id", value: streamId)]
        guard let url = comps.url else { throw RelayError(detail: "stream") }
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        authHeaders(&req, cookie)
        // Consume the SSE INCREMENTALLY and return the instant the terminator
        // arrives — do NOT use data(for:) which waits for the connection to
        // close. The server keeps the stream open with heartbeats for minutes
        // after the answer, which made the watch hang on "thinking". (The webui
        // is fast for the same reason: it stops reading on stream_end.)
        let (bytes, resp) = try await session.bytes(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw RelayError(detail: "stream") }
        return try await consumeSSE(bytes, onSentence: onSentence)
    }

    /// Shared SSE-consumption loop for both the classic `GET /api/chat/stream`
    /// and the streamed `POST /api/chat/start?stream=1` body. Feeds each
    /// `token` delta into a `WatchRelay.SentenceSplitter` (plan 1.6a) and
    /// calls `onSentence` the instant a sentence completes, instead of
    /// waiting for `stream_end` — that's what lets synthesis start while the
    /// stream is still going (plan 1.6b).
    private func consumeSSE(_ bytes: URLSession.AsyncBytes,
                            onSentence: @escaping (String) -> Void) async throws -> String {
        var full = ""
        var currentEvent = ""
        let splitter = WatchRelay.SentenceSplitter()
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
                    if let t = obj["text"] as? String {
                        full += t
                        pushStreaming(full)
                        for sentence in splitter.feed(t) { onSentence(sentence) }
                    }
                case "stream_end", "done":               // answer complete — stop reading now
                    if let tail = splitter.finish() { onSentence(tail) }
                    return full
                case "apperror", "error", "cancel": throw RelayError(detail: "stream")
                default: break
                }
            }
        }
        if let tail = splitter.finish() { onSentence(tail) }
        return full
    }

    private func synthesize(_ session: URLSession, _ base: String, _ cookie: String, _ text: String) async throws -> Data {
        guard let url = URL(string: base + "/api/voice/synthesize") else { throw RelayError(detail: "synth: bad url") }
        // ALWAYS use the JARVIS voice regardless of reply length — the clip is
        // delivered out-of-band via transferFile (no payload-size cap), so there's
        // no length gate. Retry a few times so a transient TTS hiccup doesn't drop
        // us to the watch's built-in voice; built-in is the LAST resort only after
        // every attempt fails.
        var lastDetail = "synth"
        for attempt in 0..<3 {
            do {
                let (data, code) = try await postJSON(session, url, cookie, ["text": text], accept: "audio/mpeg")
                guard code == 200 else { lastDetail = "synth HTTP \(code)"; throw RelayError(detail: lastDetail) }
                guard !data.isEmpty else { lastDetail = "synth empty"; throw RelayError(detail: lastDetail) }
                return data
            } catch is CancellationError {
                throw CancellationError()
            } catch let e as RelayError {
                lastDetail = e.detail
            } catch {
                lastDetail = "synth io"
            }
            if attempt < 2 {
                try? await Task.sleep(nanoseconds: 600_000_000)  // 0.6s backoff
            }
        }
        throw RelayError(detail: lastDetail)
    }

    // MARK: voice-clip out-of-band delivery
    /// plan 1.6e: clip-size threshold under which `sendMessageData` (delivered
    /// immediately, reachable-only) is preferred over `transferFile` (queued,
    /// can lag by seconds but has no size limit and works while unreachable).
    private static let smallClipBytes = 60 * 1024

    /// Deliver one synthesized clip to the watch. Small clips go over
    /// `sendMessageData` for the lowest latency when the watch is reachable;
    /// anything bigger, or a message send that fails, falls back to
    /// `transferFile` (no payload-size limit, unlike the sendMessage reply).
    private func sendVoiceClip(_ data: Data, seq: Int = 0, isFirst: Bool = true) {
        guard WCSession.isSupported() else { return }
        // Only the FIRST chunk of a reply cancels still-queued transfers (stale
        // clips from an earlier reply); later chunks of the SAME reply must NOT
        // cancel their siblings, or only the first chunk would survive.
        if isFirst {
            WCSession.default.outstandingFileTransfers.forEach { $0.cancel() }
        }
        if data.count < Self.smallClipBytes, WCSession.default.isReachable {
            // Frame as [version:1][isFirst:1][seq:1][mp3 bytes...] — sendMessageData
            // carries a raw blob only, no metadata dict alongside it.
            var framed = Data(capacity: data.count + 3)
            framed.append(0x01)
            framed.append(isFirst ? 1 : 0)
            // Aliasing assumption: `seq` is clamped into a single byte, so
            // sentence 255 and every sentence after it collide on the wire
            // (256, 511, ... all read back as 255). A reply would need
            // >255 synthesized sentences to hit this — far beyond any real
            // spoken answer — so it's accepted rather than widened to 2
            // bytes. If replies ever get that long, widen this to UInt16.
            framed.append(UInt8(min(seq, 255)))
            framed.append(data)
            WCSession.default.sendMessageData(framed, replyHandler: nil) { [weak self] _ in
                // Reachability can flip mid-send — fall back to the reliable path.
                self?.transferClipFile(data, seq: seq)
            }
            return
        }
        transferClipFile(data, seq: seq)
    }

    private func transferClipFile(_ data: Data, seq: Int) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jc_voice_\(UUID().uuidString).mp3")
        do {
            try data.write(to: url)
            WCSession.default.transferFile(url, metadata: ["type": "voiceClip", "seq": seq])
        } catch { try? FileManager.default.removeItem(at: url) }
    }

    func session(_ s: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error _: Error?) {
        try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
    }
}

// MARK: - Pipelined sentence-by-sentence synthesis (plan 1.6b)

/// Synthesizes sentences AS they complete during streaming, up to `maxAhead`
/// concurrently, while still delivering the resulting clips to the watch
/// STRICTLY in order (a later sentence's synth call can finish first, but
/// the watch must hear them in reading order). `seq` is assigned by the
/// caller, synchronously, in SSE-reading order — this actor only reorders
/// delivery, never renumbers.
private actor SentencePipeline {
    private let maxAhead: Int
    private let synthesize: (String) async throws -> Data
    private let deliver: (Data, Int, Bool) -> Void

    private var totalPushed = 0
    private var inFlight = 0
    private var nextDeliverSeq = 0
    private var readyClips: [Int: Data] = [:]
    private var failedSeqs: Set<Int> = []
    private(set) var sentAny = false
    private var slotWaiters: [CheckedContinuation<Void, Never>] = []
    private var doneWaiters: [CheckedContinuation<Void, Never>] = []

    init(maxAhead: Int, synthesize: @escaping (String) async throws -> Data,
         deliver: @escaping (Data, Int, Bool) -> Void) {
        self.maxAhead = maxAhead
        self.synthesize = synthesize
        self.deliver = deliver
    }

    /// Enqueue sentence `seq` for synthesis. Suspends only when `maxAhead`
    /// are already outstanding, so the SSE reader itself is never blocked.
    func push(seq: Int, text: String) async {
        totalPushed = max(totalPushed, seq + 1)
        while inFlight >= maxAhead {
            await withCheckedContinuation { slotWaiters.append($0) }
        }
        inFlight += 1
        Task { [weak self] in
            guard let self else { return }
            let data = try? await self.synthesize(text)
            await self.finish(seq: seq, data: data)
        }
    }

    private func finish(seq: Int, data: Data?) {
        inFlight -= 1
        if let data, !data.isEmpty { readyClips[seq] = data; sentAny = true }
        else { failedSeqs.insert(seq) }
        if !slotWaiters.isEmpty { slotWaiters.removeFirst().resume() }
        deliverReady()
    }

    private func deliverReady() {
        while true {
            if let data = readyClips.removeValue(forKey: nextDeliverSeq) {
                deliver(data, nextDeliverSeq, nextDeliverSeq == 0)
                nextDeliverSeq += 1
            } else if failedSeqs.remove(nextDeliverSeq) != nil {
                nextDeliverSeq += 1  // this sentence's synth failed — skip it, keep order
            } else {
                break
            }
        }
        if nextDeliverSeq >= totalPushed && inFlight == 0 {
            let waiters = doneWaiters; doneWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    /// Wait until every pushed sentence has finished synthesizing and (if it
    /// succeeded) been delivered.
    func waitForCompletion() async {
        if nextDeliverSeq >= totalPushed && inFlight == 0 { return }
        await withCheckedContinuation { doneWaiters.append($0) }
    }
}

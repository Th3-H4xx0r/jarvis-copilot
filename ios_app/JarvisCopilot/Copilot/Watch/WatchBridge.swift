import Foundation
import UIKit
import WatchConnectivity

/// The phone half of the Apple Watch companion.
///
/// Ported from the Flutter client's `Runner/WatchBridge.swift`, which spoke to
/// the server through 400 lines of its own `URLSession` code: cookie headers,
/// session creation, SSE parsing, TTS. All of that is now the app's own job, so
/// this class keeps only what is genuinely watch-specific — the WCSession
/// protocol, the sentence pipeline and clip delivery — and runs the turn
/// through `ChatAPI` and `VoiceAPI` like every other surface.
///
/// The wire protocol is unchanged, so the watch app needs no edits:
///   watch → phone  `sendMessage(["type":"ask","text":…,"preferLocalVoice":Bool])`
///   phone → watch  application context: `loggedIn`, `streamingText`,
///                  `hapticNonce`/`hapticCount`, `firstSentence`/`firstSentenceNonce`
///   phone → watch  clips: `sendMessageData` framed `[0x01][isFirst][seq][mp3…]`,
///                  or `transferFile` with metadata `{type:"voiceClip", seq:Int}`
@MainActor
final class WatchBridge: NSObject, ObservableObject {
    static let shared = WatchBridge()

    /// The watch keeps its OWN conversation so a dictated turn never lands in
    /// the middle of whatever is open on the phone. It still shows up in Chats.
    private static let sessionKey = "watch.sessionId"
    /// Read by the WATCH app (`WatchConnector.preferLocalVoice`) and sent with
    /// every turn; declared here so the phone's settings page can toggle it.
    static let preferLocalVoiceKey = "watch.preferLocalVoice"
    static let sessionTitle = "Watch"

    @Published private(set) var isPaired = false
    @Published private(set) var isReachable = false
    @Published private(set) var lastError: String?

    private let api: JarvisAPI
    private let chat: ChatAPI
    private let voice: VoiceAPI
    private let defaults: UserDefaults

    /// Bumped per turn; a reply from an abandoned turn is dropped.
    private var turnCounter = 0
    private var activeTurn = 0
    // Seeded from the clock: the watch dedupes on `nonce != last`, so restarting
    // at 0 each launch could silently swallow the first haptic or ack.
    private var hapticNonce = Int(Date().timeIntervalSince1970 * 1000)
    private var firstSentenceNonce = Int(Date().timeIntervalSince1970 * 1000)

    init(api: JarvisAPI = .shared, defaults: UserDefaults = .standard) {
        self.api = api
        self.chat = ChatAPI(api: api)
        self.voice = VoiceAPI(api: api)
        self.defaults = defaults
        super.init()
    }

    // MARK: - The reply the watch decodes

    /// `AskResult.from` (JarvisWatch/AskResult.swift) reads exactly these keys.
    /// Built here, and covered by tests, because getting them wrong fails
    /// silently: a reply under the wrong key simply arrives blank.
    enum Failure: Equatable {
        case notConfigured
        case network(String)
    }

    nonisolated static func reply(text: String, sentClip: Bool) -> [String: Any] {
        ["ok": true, "replyText": text, "expectsClip": sentClip]
    }

    nonisolated static func failure(_ failure: Failure) -> [String: Any] {
        switch failure {
        case .notConfigured:
            // The watch matches this string exactly to show its setup screen.
            return ["ok": false, "error": "not_configured"]
        case .network(let detail):
            return ["ok": false, "error": "network", "detail": detail]
        }
    }

    // MARK: - Lifecycle

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        refreshState(session)
    }

    /// Tell the watch whether the phone is paired, so it can show its setup
    /// screen instead of failing every turn.
    func pushLoginState() {
        guard WCSession.isSupported() else { return }
        // `preferLocalVoice` is set on the PHONE but read on the watch, which
        // has its own UserDefaults — without carrying it across, the toggle
        // did nothing at all.
        push(["loggedIn": api.isPaired,
              "preferLocalVoice": defaults.bool(forKey: Self.preferLocalVoiceKey)])
    }

    private func refreshState(_ session: WCSession) {
        isPaired = session.isPaired && session.isWatchAppInstalled
        isReachable = session.isReachable
    }

    /// The live preview, at ~3/s. `updateApplicationContext` is rate-limited
    /// and re-serializes the whole context, so pushing every token dropped
    /// updates on the floor.
    private var lastStreamPush = Date.distantPast
    private func pushStreaming(_ text: String) {
        let now = Date()
        guard now.timeIntervalSince(lastStreamPush) >= 0.3 else { return }
        lastStreamPush = now
        push(["streamingText": text])
    }

    private func push(_ values: [String: Any]) {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        var merged = session.applicationContext
        for (k, v) in values { merged[k] = v }
        do { try session.updateApplicationContext(merged) }
        catch { JcLog.dropped(JcLog.services, "watch application context", error) }
    }

    // MARK: - Agent → watch

    /// Buzz the watch. Deduped by nonce on the far side so a repeated context
    /// update doesn't buzz twice.
    func sendHaptic(count: Int) {
        hapticNonce += 1
        push(["hapticNonce": hapticNonce, "hapticCount": max(1, min(count, 10))])
    }

    // MARK: - The turn

    private func beginTurn() -> Int {
        turnCounter += 1
        activeTurn = turnCounter
        return activeTurn
    }

    /// Run one dictated turn and return the reply for `sendMessage`'s ack.
    /// Sentences are synthesized and delivered as they complete, so the watch
    /// starts speaking while the rest of the answer is still being written.
    func runTurn(text: String, preferLocalVoice: Bool) async -> [String: Any] {
        guard api.isPaired else { return Self.failure(.notConfigured) }
        let turn = beginTurn()
        push(["streamingText": ""])

        let sessionID: String
        do { sessionID = try await watchSessionID() }
        catch {
            lastError = apiErrorMessage(error)
            // A bad/deleted session id must not be reused for every later turn.
            startNewSession()
            return Self.failure(.network(lastError ?? "could not start the turn"))
        }

        /// Set from the delivery closure, read after the stream ends.
        final class ClipFlag { var sent = false }
        let clipFlag = ClipFlag()
        let splitter = WatchRelay.SentenceSplitter()
        let pipeline = SentencePipeline(voice: voice, preferLocalVoice: preferLocalVoice) { [weak self] data, seq, isFirst in
            // A clip synthesized for an ABANDONED turn must not play over the
            // new one: the SSE loop's guard doesn't cover a slow synthesis.
            guard let self, self.isActive(turn) else { return }
            clipFlag.sent = true
            self.sendVoiceClip(data, seq: seq, isFirst: isFirst)
        }
        var reply = ""
        var sawFirstSentence = false

        do {
            stream: for try await event in chat.sendMessage(sessionID: sessionID, text: text) {
                guard isActive(turn) else { break }
                switch event.event {
                case "token", "delta", "text":
                    // Match ChatStreamReducer's names and key fallbacks — a
                    // `delta`-shaped server produced a silent, empty turn.
                    guard let delta = event.string("text") ?? event.string("delta")
                            ?? event.string("content"), !delta.isEmpty else { continue }
                    reply += delta
                    pushStreaming(reply)
                    for sentence in splitter.feed(delta) {
                        if !sawFirstSentence {
                            sawFirstSentence = true
                            firstSentenceNonce += 1
                            // Lets the watch start its instant-ack countdown.
                            push(["firstSentence": sentence, "firstSentenceNonce": firstSentenceNonce])
                        }
                        await pipeline.push(text: sentence)
                    }
                case "apperror", "error", "cancel":
                    let detail = event.string("text") ?? event.string("error") ?? "the turn failed"
                    lastError = detail
                    return Self.failure(.network(detail))
                case "stream_end", "done", "complete":
                    // `break` in a switch leaves the SWITCH; the stream has to
                    // stop here or a server that holds the socket open hangs
                    // the watch until its reply handler times out.
                    break stream
                default:
                    break
                }
            }
        } catch {
            lastError = apiErrorMessage(error)
            return Self.failure(.network(lastError ?? "the turn failed"))
        }

        if let tail = splitter.finish() {
            if !sawFirstSentence {
                sawFirstSentence = true
                firstSentenceNonce += 1
                push(["firstSentence": tail, "firstSentenceNonce": firstSentenceNonce])
            }
            await pipeline.push(text: tail)
        }
        await pipeline.waitForCompletion()
        push(["streamingText": ""])

        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Self.failure(.network("the reply was empty"))
        }
        // The clips already went out of band; the ack carries the text and
        // whether audio is on its way, so the watch knows not to speak it.
        return Self.reply(text: trimmed, sentClip: clipFlag.sent)
    }

    private func isActive(_ turn: Int) -> Bool { turn == activeTurn }

    /// The watch's own chat session, created once and remembered.
    private func watchSessionID() async throws -> String {
        if let stored = defaults.string(forKey: Self.sessionKey), !stored.isEmpty {
            return stored
        }
        let created = try await api.post("/api/session/new",
                                         json: ["title": Self.sessionTitle]).object()
        let id = WatchRelay.extractSessionId(created) ?? ""
        guard !id.isEmpty else { throw APIError.badResponse("could not create the Watch session") }
        defaults.set(id, forKey: Self.sessionKey)
        return id
    }

    /// Forget the remembered session, so the next turn starts a fresh one.
    func startNewSession() { defaults.removeObject(forKey: Self.sessionKey) }

    // MARK: - Background assertion

    private func beginBackgroundAssertion() -> UIBackgroundTaskIdentifier {
        var identifier = UIBackgroundTaskIdentifier.invalid
        identifier = UIApplication.shared.beginBackgroundTask(withName: "jc.watch.turn") { [weak self] in
            // Out of time: abandon the turn so the expiring assertion can end.
            Task { @MainActor in self?.abandonActiveTurn() }
        }
        return identifier
    }

    private func endBackgroundAssertion(_ identifier: UIBackgroundTaskIdentifier) {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
    }

    /// Stop attributing work to the running turn (its clips are then dropped).
    private func abandonActiveTurn() { activeTurn = 0 }

    // MARK: - Clip delivery

    /// Small clips go over `sendMessageData` (immediate, reachable-only); the
    /// rest over `transferFile` (queued, survives an unreachable watch). Both
    /// carry `seq` so the watch plays them in reading order whichever arrives
    /// first.
    private static let inlineClipLimit = 60_000

    private func sendVoiceClip(_ data: Data, seq: Int, isFirst: Bool) {
        guard WCSession.isSupported(), !data.isEmpty else { return }
        let session = WCSession.default
        if isFirst {
            // Queued clips from the previous answer would otherwise play over
            // this one — `transferFile` survives the turn that made it.
            for transfer in session.outstandingFileTransfers { transfer.cancel() }
        }
        if session.isReachable && data.count <= Self.inlineClipLimit {
            var framed = Data([0x01, isFirst ? 1 : 0, UInt8(clamping: seq)])
            framed.append(data)
            session.sendMessageData(framed, replyHandler: nil) { [weak self] _ in
                Task { @MainActor in self?.transferClipFile(data, seq: seq) }
            }
            return
        }
        transferClipFile(data, seq: seq)
    }

    private func transferClipFile(_ data: Data, seq: Int) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jc-watch-\(UUID().uuidString).mp3")
        do { try data.write(to: url) } catch {
            JcLog.dropped(JcLog.services, "watch clip write", error)
            return
        }
        WCSession.default.transferFile(url, metadata: ["type": "voiceClip", "seq": seq])
    }
}

// MARK: - WCSessionDelegate

extension WatchBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith state: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in
            self.refreshState(session)
            self.pushLoginState()
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.refreshState(session) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        guard (message["type"] as? String) == "ask" else {
            replyHandler(["ok": false, "error": "unknown"])
            return
        }
        let text = (message["text"] as? String) ?? ""
        let preferLocal = (message["preferLocalVoice"] as? Bool) ?? false
        Task { @MainActor in
            // iOS background-launches us to deliver this message, and will
            // suspend us mid-turn without an assertion — the watch then waits
            // out its reply handler and reports "can't reach the phone".
            let assertion = await self.beginBackgroundAssertion()
            let reply = await self.runTurn(text: text, preferLocalVoice: preferLocal)
            replyHandler(reply)
            await self.endBackgroundAssertion(assertion)
        }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer,
                             error: Error?) {
        // The temp file has served its purpose either way.
        try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
    }
}

// MARK: - Pipelined synthesis

/// Synthesizes sentences concurrently but DELIVERS them in order, so sentence
/// two never reaches the watch before sentence one. Ported from the Flutter
/// bridge's `ClipPipeline`, with `VoiceAPI` doing the synthesis.
private actor SentencePipeline {
    private let voice: VoiceAPI
    private let preferLocalVoice: Bool
    private let deliver: @MainActor (Data, Int, Bool) -> Void

    private var nextSeq = 0
    private var nextToDeliver = 0
    private var ready: [Int: Data] = [:]
    private var tasks: [Task<Void, Never>] = []

    init(voice: VoiceAPI, preferLocalVoice: Bool,
         deliver: @escaping @MainActor (Data, Int, Bool) -> Void) {
        self.voice = voice
        self.preferLocalVoice = preferLocalVoice
        self.deliver = deliver
    }

    func push(text: String) {
        // The watch was asked to use its own voice — synthesizing would be
        // wasted work and a wasted transfer.
        guard !preferLocalVoice else { return }
        let seq = nextSeq
        nextSeq += 1
        let task = Task { [voice] in
            let data = await voice.synthesizeOrEmpty(text: text)
            await self.finish(seq: seq, data: data)
        }
        tasks.append(task)
    }

    private func finish(seq: Int, data: Data) {
        ready[seq] = data
        drain()
    }

    private func drain() {
        while let data = ready.removeValue(forKey: nextToDeliver) {
            let seq = nextToDeliver
            nextToDeliver += 1
            guard !data.isEmpty else { continue }
            let isFirst = seq == 0
            Task { @MainActor in self.deliver(data, seq, isFirst) }
        }
    }

    func waitForCompletion() async {
        for task in tasks { _ = await task.value }
        drain()
    }
}

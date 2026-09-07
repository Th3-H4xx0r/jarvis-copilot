import Foundation
import UIKit
import WatchConnectivity

/// The phone half of the Apple Watch companion.
///
/// A watch turn runs the PHONE'S VOICE PIPELINE, not a private one: the same
/// `/api/voice/quality-turn` the push-to-talk path uses, with the same voice
/// session and the same voice model fields. That endpoint runs the shared
/// `_run_agent_turn_via_chat`, so the watch inherits the voice system prompt,
/// the fast lane and the model you picked for voice — change the phone's voice
/// flow and the watch changes with it. There is no second implementation here:
/// the server already returns text segments with their audio, so nothing is
/// re-synthesized or re-ordered on this side.
///
/// The wire protocol to the WATCH is unchanged:
///   watch → phone  `sendMessage(["type":"ask","text":…,"preferLocalVoice":Bool])`
///   phone → watch  application context: `loggedIn`, `preferLocalVoice`,
///                  `streamingText`, `hapticNonce`/`hapticCount`,
///                  `firstSentence`/`firstSentenceNonce`
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
    /// The shared voice conversation both surfaces write to.
    static let sessionTitle = "Voice"

    @Published private(set) var isPaired = false
    @Published private(set) var isReachable = false
    @Published private(set) var lastError: String?

    private let api: JarvisAPI
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

    /// Run one dictated turn through the phone's voice pipeline and return the
    /// reply for `sendMessage`'s ack. Segments arrive already spoken, in order.
    func runTurn(text: String, preferLocalVoice: Bool) async -> [String: Any] {
        guard api.isPaired else { return Self.failure(.notConfigured) }
        let turn = beginTurn()
        push(["streamingText": ""])

        let sessionID: String
        do { sessionID = try await watchSessionID() }
        catch {
            lastError = apiErrorMessage(error)
            return Self.failure(.network(lastError ?? "could not start the turn"))
        }

        var reply = ""
        var seq = 0
        var sawFirstSentence = false
        var sentAnyClip = false

        // The voice model the PHONE is set to — the watch has no picker of its
        // own and shouldn't: whatever voice answers on the phone answers here.
        var extra = voiceTurnModelFields()
        extra["text"] = text

        do {
            for try await event in voice.qualityTurn(audio: Data(), sessionID: sessionID, extra: extra) {
                guard isActive(turn) else { break }
                switch event.type {
                case "segment":
                    guard event.kind == "text" else { continue }   // tool frames aren't spoken
                    let piece = (event.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !piece.isEmpty {
                        reply += reply.isEmpty ? piece : " " + piece
                        // Straight to the watch, NOT through application
                        // context: that is rate-limited and coalesced, so the
                        // acknowledgement and every sentence only surfaced once
                        // the whole turn (tool calls and all) had finished.
                        sendSegment(piece, isFirst: !sawFirstSentence)
                        pushStreaming(reply)
                        if !sawFirstSentence {
                            sawFirstSentence = true
                            firstSentenceNonce += 1
                            // Belt and braces for a watch that wasn't reachable
                            // at the moment the segment went out.
                            push(["firstSentence": piece, "firstSentenceNonce": firstSentenceNonce])
                        }
                    }
                    // The server already synthesized this segment in the JARVIS
                    // voice; send it straight on unless the watch asked to speak
                    // for itself.
                    if !preferLocalVoice, let audio = event.audio, !audio.isEmpty {
                        sendVoiceClip(audio, seq: seq, isFirst: seq == 0)
                        sentAnyClip = true
                        seq += 1
                    }
                case "error":
                    let detail = event.error ?? event.text ?? "the turn failed"
                    lastError = detail
                    return Self.failure(.network(detail))
                case "done":
                    break
                default:
                    break
                }
            }
        } catch {
            lastError = apiErrorMessage(error)
            return Self.failure(.network(lastError ?? "the turn failed"))
        }

        push(["streamingText": ""])
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Self.failure(.network("the reply was empty")) }
        return Self.reply(text: trimmed, sentClip: sentAnyClip)
    }

    private func isActive(_ turn: Int) -> Bool { turn == activeTurn }

    /// The very session the phone's voice uses — same conversation, same
    /// history, same model binding. Resolved by the shared voice transport, so
    /// the session picker in the Voice tab governs the watch too.
    private func watchSessionID() async throws -> String {
        try await VoiceSessionResolver.shared.ensureSession(voice: voice)
    }

    /// Ask for a fresh voice session on the next turn.
    func startNewSession() { VoiceSessionResolver.shared.invalidate() }

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

    /// One reply segment, delivered immediately. `sendMessage` reaches a
    /// reachable watch at once, which is exactly the case during a turn it
    /// started.
    private func sendSegment(_ text: String, isFirst: Bool) {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(["type": "segment", "text": text, "first": isFirst],
                            replyHandler: nil) { _ in
            // Best effort: the application-context push and the final reply
            // both still carry the text.
        }
    }

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
        let kind = (message["type"] as? String) ?? ""
        // Everything the watch can ask for beyond a turn is answered from the
        // phone's own hub and API — see WatchDataProvider.
        switch kind {
        case "sessions":
            Task { @MainActor in replyHandler(await WatchDataProvider.sessions(api: self.api)) }
            return
        case "session_select":
            Task { @MainActor in
                replyHandler(WatchDataProvider.selectSession((message["id"] as? String) ?? ""))
            }
            return
        case "session_new":
            Task { @MainActor in replyHandler(await WatchDataProvider.newSession(api: self.api)) }
            return
        case "wearables":
            Task { @MainActor in replyHandler(WatchDataProvider.wearables()) }
            return
        case "wearable_connect":
            Task { @MainActor in
                replyHandler(await WatchDataProvider.connect((message["id"] as? String) ?? ""))
            }
            return
        case "wearable_invoke":
            Task { @MainActor in
                replyHandler(await WatchDataProvider.invoke(
                    deviceID: (message["device"] as? String) ?? "",
                    action: (message["action"] as? String) ?? ""))
            }
            return
        case "ask":
            break
        default:
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

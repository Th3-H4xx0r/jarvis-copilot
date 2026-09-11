import Foundation
import UIKit
import WatchConnectivity

/// The phone half of the Apple Watch companion.
///
/// A watch turn runs the phone's own voice pipeline (`VoiceStore`) in the voice
/// session, so the watch inherits the voice model, prompt, tools and history.
///
/// Wire protocol:
///   watch → phone  `sendMessage(["type":"ask","text":…,"preferLocalVoice":Bool])`
///   phone → watch  application context: `loggedIn`, `preferLocalVoice`, `streamingText`
///   phone → watch  `sendMessage(["type":"segment","text":…,"first":Bool])` per sentence
///   phone → watch  clips: `sendMessageData` framed `[0x01][isFirst][seq][mp3…]`,
///                  or `transferFile` with metadata `{type:"voiceClip", seq:Int}`
@MainActor
final class WatchBridge: NSObject, ObservableObject {
    static let shared = WatchBridge()

    /// Read by the WATCH app (`WatchConnector.preferLocalVoice`) and sent with
    /// every turn; declared here so the phone's settings page can toggle it.
    static let preferLocalVoiceKey = "watch.preferLocalVoice"

    @Published private(set) var isPaired = false
    @Published private(set) var isReachable = false
    @Published private(set) var lastError: String?

    // MARK: - Link statistics
    //
    // Watch problems are almost always the LINK, not the code: a turn that
    // silently did nothing looks the same as one that never left the wrist.
    // These make the connection legible on the phone's Apple Watch page.
    @Published private(set) var turnsRun = 0
    @Published private(set) var turnsFailed = 0
    @Published private(set) var messagesIn = 0
    @Published private(set) var messagesOut = 0
    @Published private(set) var segmentsSent = 0
    @Published private(set) var clipsSent = 0
    @Published private(set) var clipBytesSent = 0
    /// Wall-clock of the last completed turn.
    @Published private(set) var lastTurnSeconds: Double?
    @Published private(set) var lastTurnAt: Date?
    /// Files still queued for a watch that wasn't reachable.
    var queuedTransfers: Int {
        WCSession.isSupported() ? WCSession.default.outstandingFileTransfers.count : 0
    }

    func resetStatistics() {
        turnsRun = 0; turnsFailed = 0; messagesIn = 0; messagesOut = 0
        segmentsSent = 0; clipsSent = 0; clipBytesSent = 0
        lastTurnSeconds = nil; lastError = nil
    }

    private let api: JarvisAPI
    private let defaults: UserDefaults

    /// Bumped per turn; a reply from an abandoned turn is dropped.
    private var turnCounter = 0
    private var activeTurn = 0

    init(api: JarvisAPI = .shared, defaults: UserDefaults = .standard) {
        self.api = api
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

    // MARK: - The turn

    private func beginTurn() -> Int {
        turnCounter += 1
        activeTurn = turnCounter
        return activeTurn
    }

    /// Run one dictated turn by driving the PHONE'S OWN voice store — the same
    /// realtime socket, `begin_turn` model fields, server prompt, tools and
    /// speech a turn spoken at the phone gets. There is no watch-specific turn
    /// logic left: this hands the text over and mirrors what comes back.
    func runTurn(text: String, preferLocalVoice: Bool) async -> [String: Any] {
        guard api.isPaired else { return Self.failure(.notConfigured) }
        let turn = beginTurn()
        let startedAt = Date()
        turnsRun += 1
        push(["streamingText": ""])

        // The one app-wide voice store — the same object the Voice tab drives.
        let store = VoiceStore.shared
        var seq = 0
        var sawFirst = false
        var streamed = ""

        let outcome: WatchTurnOutcome = await withCheckedContinuation { continuation in
            var finished = false
            store.onWatchSegment = { [weak self] piece, audio in
                guard let self, self.isActive(turn) else { return }
                let text = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    streamed += streamed.isEmpty ? text : " " + text
                    self.sendSegment(text, isFirst: !sawFirst)
                    self.pushStreaming(streamed)
                    sawFirst = true
                }
                // The phone already synthesized this in the JARVIS voice.
                if !preferLocalVoice, let audio, !audio.isEmpty {
                    self.sendVoiceClip(audio, seq: seq, isFirst: seq == 0)
                    seq += 1
                }
            }
            store.onWatchFinished = { result in
                guard !finished else { return }
                finished = true
                store.onWatchSegment = nil
                store.onWatchFinished = nil
                continuation.resume(returning: result)
            }
            store.startWatchTurn(text: text)
        }

        push(["streamingText": ""])
        lastTurnSeconds = Date().timeIntervalSince(startedAt)
        lastTurnAt = Date()

        switch outcome {
        case .answered(let reply):
            let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = trimmed.isEmpty ? streamed.trimmingCharacters(in: .whitespacesAndNewlines) : trimmed
            guard !body.isEmpty else {
                turnsFailed += 1
                return Self.failure(.network("the turn produced no reply"))
            }
            return Self.reply(text: body, sentClip: seq > 0)
        case .failed(let detail):
            turnsFailed += 1
            lastError = detail
            return Self.failure(.network(detail))
        }
    }

    private func isActive(_ turn: Int) -> Bool { turn == activeTurn }

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
        messagesOut += 1
        segmentsSent += 1
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
        clipsSent += 1
        clipBytesSent += data.count
        messagesOut += 1
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
        Task { @MainActor in self.messagesIn += 1 }
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

import Combine
import Foundation
import WatchConnectivity
import WatchKit

/// The watch's WCSession client. Sends one dictated turn at a time, receives
/// the login-state (pushed by the phone via application context), and plays the
/// spoken reply clip that arrives out-of-band via `transferFile`.
@MainActor
final class WatchConnector: NSObject, ObservableObject, WCSessionDelegate {
    /// Optimistic until the phone's application context says otherwise, so a
    /// freshly-launched, already-paired watch doesn't flash the setup screen.
    @Published var loggedIn: Bool = true
    /// The partial answer pushed by the phone as tokens stream in (live preview).
    @Published var streamingText: String = ""
    /// Last agent-haptic command id we acted on (dedupe applicationContext repeats).
    private var lastHapticNonce: Int = 0
    /// Last "first sentence known" nonce we acted on (dedupe applicationContext repeats).
    private var lastFirstSentenceNonce: Int = 0
    /// Instant on-watch ack (plan 1.6c): waits briefly for the hi-fi clip,
    /// falls back to the built-in voice, then hands off to the clip.
    let ack = AckCoordinator()

    /// `watch.preferLocalVoice` (default false): always use the built-in
    /// voice and skip clip transfer entirely. plan 1.6c.
    static let preferLocalVoiceKey = "watch.preferLocalVoice"
    static var preferLocalVoice: Bool { UserDefaults.standard.bool(forKey: preferLocalVoiceKey) }

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    /// Send one dictated turn; resolves with the decoded reply or an error.
    /// We do NOT pre-gate on `isReachable`: calling `sendMessage` is what wakes
    /// a backgrounded/force-quit iPhone app, and `isReachable` is typically
    /// false in exactly that state. We let the errorHandler classify a genuine
    /// "can't reach the phone" as `.unreachable`.
    func ask(text: String) async -> Result<AskResult, AskError> {
        guard WCSession.isSupported() else { return .failure(.unreachable) }
        streamingText = ""   // clear last turn's live preview
        AudioPlayer.shared.resetClips()  // drop any leftover clips from the previous reply
        ack.reset()          // invalidate any still-pending instant-ack timer from the last turn
        return await withCheckedContinuation { cont in
            WCSession.default.sendMessage(
                ["type": "ask", "text": text, "preferLocalVoice": Self.preferLocalVoice]
            ) { reply in
                cont.resume(returning: AskResult.from(reply))
            } errorHandler: { _ in
                cont.resume(returning: .failure(.unreachable))
            }
        }
    }

    // MARK: WCSessionDelegate (nonisolated — hop back to the main actor)
    nonisolated func session(_ s: WCSession,
                             activationDidCompleteWith _: WCSessionActivationState,
                             error _: Error?) {}

    nonisolated func session(_ s: WCSession, didReceiveApplicationContext ctx: [String: Any]) {
        let v = ctx["loggedIn"] as? Bool
        let streaming = ctx["streamingText"] as? String
        let hapticNonce = ctx["hapticNonce"] as? Int
        let hapticCount = ctx["hapticCount"] as? Int
        let firstSentence = ctx["firstSentence"] as? String
        let firstSentenceNonce = ctx["firstSentenceNonce"] as? Int
        Task { @MainActor in
            if let v { self.loggedIn = v }
            if let streaming { self.streamingText = streaming }
            // Agent → watch haptic command (deduped by nonce so we buzz once).
            if let nonce = hapticNonce, nonce != self.lastHapticNonce {
                self.lastHapticNonce = nonce
                let n = max(1, min(hapticCount ?? 3, 10))
                for i in 0..<n {
                    WKInterfaceDevice.current().play(.notification)
                    if i < n - 1 { try? await Task.sleep(nanoseconds: 600_000_000) }
                }
            }
            // plan 1.6c: the first sentence's text is known — start the
            // instant-ack countdown (deduped by nonce, one per turn).
            if let nonce = firstSentenceNonce, nonce != self.lastFirstSentenceNonce,
               let text = firstSentence, !text.isEmpty {
                self.lastFirstSentenceNonce = nonce
                self.ack.firstSentenceKnown(text, preferLocalVoice: Self.preferLocalVoice)
            }
        }
    }

    /// The JARVIS-voice clip arrives here (out-of-band `transferFile`, used
    /// as the fallback for clips too big for `sendMessageData` or sent while
    /// unreachable). The temp `fileURL` is deleted after this returns, so
    /// read it NOW, then play.
    nonisolated func session(_ s: WCSession, didReceive file: WCSessionFile) {
        guard (file.metadata?["type"] as? String) == "voiceClip",
              let data = try? Data(contentsOf: file.fileURL), !data.isEmpty else { return }
        // plan 1.6/2: reply audio can arrive over `transferFile` (this path,
        // queued, can lag) interleaved with `sendMessageData` (immediate) —
        // enqueue by `seq` so AudioPlayer plays them in READING order, not
        // whichever transport happened to deliver first.
        let seq = (file.metadata?["seq"] as? Int) ?? 0
        Task { @MainActor in
            self.ack.clipDidArrive()
            AudioPlayer.shared.enqueueClip(data, seq: seq)
        }
    }

    /// plan 1.6e: the low-latency path for a small clip — `sendMessageData`,
    /// reachable-only, delivered immediately (no transfer queue). Framed as
    /// [version:1][isFirst:1][seq:1][mp3 bytes...] by `WatchBridge.sendVoiceClip`.
    nonisolated func session(_ s: WCSession, didReceiveMessageData messageData: Data) {
        guard messageData.count > 3, messageData[0] == 0x01 else { return }
        let seq = Int(messageData[2])
        let audio = messageData.subdata(in: 3..<messageData.count)
        guard !audio.isEmpty else { return }
        Task { @MainActor in
            self.ack.clipDidArrive()
            AudioPlayer.shared.enqueueClip(audio, seq: seq)
        }
    }
}

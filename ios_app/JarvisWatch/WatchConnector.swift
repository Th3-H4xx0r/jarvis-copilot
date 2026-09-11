import Combine
import Foundation
import WatchConnectivity

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
    /// The instant spoken ack: waits for the JARVIS clip, falls back to the
    /// built-in voice, then hands off to the clip.
    let ack = AckCoordinator()

    /// `watch.preferLocalVoice` (default false): always use the built-in
    /// voice and skip clip transfer entirely.
    static let preferLocalVoiceKey = "watch.preferLocalVoice"
    static var preferLocalVoice: Bool { UserDefaults.standard.bool(forKey: preferLocalVoiceKey) }

    /// Adopt the phone's setting. The toggle lives on the iPhone (the watch has
    /// no settings screen), and the two devices have separate UserDefaults, so
    /// without this the toggle did nothing at all.
    static func adoptPreferLocalVoice(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: preferLocalVoiceKey)
    }

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
        // Same rule as the menu: sending before activation is a crash, not an
        // error callback.
        guard WCSession.default.activationState == .activated else {
            WCSession.default.activate()
            return .failure(.unreachable)
        }
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
        let prefersLocal = ctx["preferLocalVoice"] as? Bool
        let streaming = ctx["streamingText"] as? String
        Task { @MainActor in
            if let v { self.loggedIn = v }
            if let prefersLocal { Self.adoptPreferLocalVoice(prefersLocal) }
            if let streaming { self.streamingText = streaming }
        }
    }

    /// The JARVIS-voice clip arrives here (out-of-band `transferFile`, used
    /// as the fallback for clips too big for `sendMessageData` or sent while
    /// unreachable). The temp `fileURL` is deleted after this returns, so
    /// read it NOW, then play.
    nonisolated func session(_ s: WCSession, didReceive file: WCSessionFile) {
        guard (file.metadata?["type"] as? String) == "voiceClip",
              let data = try? Data(contentsOf: file.fileURL), !data.isEmpty else { return }
        // Reply audio can arrive over `transferFile` (this path,
        // queued, can lag) interleaved with `sendMessageData` (immediate) —
        // enqueue by `seq` so AudioPlayer plays them in READING order, not
        // whichever transport happened to deliver first.
        let seq = (file.metadata?["seq"] as? Int) ?? 0
        Task { @MainActor in
            self.ack.clipDidArrive()
            AudioPlayer.shared.enqueueClip(data, seq: seq)
        }
    }

    /// A reply segment, pushed the moment the model produced it. The first one
    /// starts the instant-ack countdown.
    nonisolated func session(_ s: WCSession, didReceiveMessage message: [String: Any]) {
        guard (message["type"] as? String) == "segment",
              let text = message["text"] as? String, !text.isEmpty else { return }
        let isFirst = (message["first"] as? Bool) ?? false
        Task { @MainActor in
            self.streamingText = self.streamingText.isEmpty ? text : self.streamingText + " " + text
            if isFirst {
                // Start the instant-ack countdown now, not when the whole turn
                // is done.
                self.ack.firstSentenceKnown(text, preferLocalVoice: Self.preferLocalVoice)
            }
        }
    }

    /// The low-latency path for a small clip: `sendMessageData`, framed as
    /// `[version][isFirst][seq][mp3…]` by `WatchBridge.sendVoiceClip`.
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

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
        return await withCheckedContinuation { cont in
            WCSession.default.sendMessage(["type": "ask", "text": text]) { reply in
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
        if let v = ctx["loggedIn"] as? Bool {
            Task { @MainActor in self.loggedIn = v }
        }
    }

    /// The spoken JARVIS-voice clip for the last ask. Read the inbox file
    /// promptly — the system removes it after this returns.
    nonisolated func session(_ s: WCSession, didReceive file: WCSessionFile) {
        guard let data = try? Data(contentsOf: file.fileURL) else { return }
        AudioPlayer.shared.play(data: data)
    }
}

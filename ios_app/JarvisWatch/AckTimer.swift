import Foundation

/// The watch's instant spoken acknowledgement. Once the first sentence's text is
/// known, the watch waits for the JARVIS-voice clip; if it hasn't landed in time
/// the watch speaks the sentence itself, and stops as soon as the clip arrives.
@MainActor
final class AckCoordinator {
    /// A failure backstop, not a race: a real turn synthesizes on the server and
    /// is relayed by the phone, which takes a few seconds. Long enough that the
    /// clip normally wins, short enough that a turn whose audio never arrives is
    /// still spoken.
    static let localVoiceFallbackMs = 6000

    private var nonce = 0
    private var clipArrived = false
    private var speakingLocally = false

    /// A new turn is starting: a stale timer from the last one must never fire.
    func reset() {
        nonce += 1
        clipArrived = false
        if speakingLocally { Speaker.shared.stop(); speakingLocally = false }
    }

    /// The JARVIS clip arrived (file transfer or `sendMessageData`).
    func clipDidArrive() {
        clipArrived = true
        if speakingLocally { Speaker.shared.stop(); speakingLocally = false }
    }

    /// The first sentence's text is known for this turn. `clipArrived` is not
    /// cleared here: the clip can land before the text does.
    func firstSentenceKnown(_ text: String, preferLocalVoice: Bool) {
        nonce += 1
        let myNonce = nonce
        let waitMs = preferLocalVoice ? 0 : Self.localVoiceFallbackMs
        Task { [weak self] in
            if waitMs > 0 { try? await Task.sleep(nanoseconds: UInt64(waitMs) * 1_000_000) }
            guard let self, self.nonce == myNonce, !self.clipArrived else { return }
            self.speakingLocally = true
            Speaker.shared.speak(text)
        }
    }
}

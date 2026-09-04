import Foundation

/// Pure decision logic for the watch's "instant spoken ack" (plan 1.6c): once
/// the first sentence's TEXT is known — pushed early via
/// `updateApplicationContext`, ahead of the hi-fi TTS clip — the watch waits
/// briefly for the clip to arrive; if it hasn't landed in time, the watch
/// speaks the sentence itself with the built-in `AVSpeechSynthesizer`, then
/// stops that synthesizer and plays the clip whenever it finally arrives.
/// No I/O here — pure function, unit-tested directly. `AckCoordinator` below
/// wires it to real time + WCSession events and is not itself unit-tested.
enum AckTimer {
    /// How long the watch waits for the hi-fi clip before falling back to
    /// its own voice. plan 1.6.
    static let localVoiceFallbackMs = 700

    enum Decision: Equatable {
        case wait          // keep waiting for the hi-fi clip
        case speakLocally  // speak the sentence with the built-in voice now
        case clipWon       // the hi-fi clip already arrived — nothing to do
    }

    /// - Parameters:
    ///   - elapsedMs: milliseconds since the first sentence's text became known.
    ///   - clipArrived: whether the hi-fi TTS clip has already arrived.
    ///   - preferLocalVoice: `watch.preferLocalVoice` setting — always use
    ///     the built-in voice, never wait for a clip.
    static func decide(elapsedMs: Int, clipArrived: Bool, preferLocalVoice: Bool) -> Decision {
        if clipArrived { return .clipWon }
        if preferLocalVoice { return .speakLocally }
        return elapsedMs >= localVoiceFallbackMs ? .speakLocally : .wait
    }
}

/// Orchestrates `AckTimer.decide` against real time and WCSession events.
/// Deliberately thin: all the actual decision-making is the pure function
/// above, which is what's unit-tested.
@MainActor
final class AckCoordinator {
    private var nonce = 0
    private var clipArrived = false
    private var speakingLocally = false

    /// Call when a new turn starts (before the `ask` goes out) so a stale
    /// timer from the previous turn can never fire.
    func reset() {
        nonce += 1
        clipArrived = false
        if speakingLocally { Speaker.shared.stop(); speakingLocally = false }
    }

    /// Call when the hi-fi clip arrives (file transfer or sendMessageData).
    func clipDidArrive() {
        clipArrived = true
        if speakingLocally { Speaker.shared.stop(); speakingLocally = false }
    }

    /// Call as soon as the first sentence's text is known for this turn.
    func firstSentenceKnown(_ text: String, preferLocalVoice: Bool) {
        nonce += 1
        let myNonce = nonce
        clipArrived = false
        let waitMs = preferLocalVoice ? 0 : AckTimer.localVoiceFallbackMs
        Task { [weak self] in
            if waitMs > 0 {
                try? await Task.sleep(nanoseconds: UInt64(waitMs) * 1_000_000)
            }
            guard let self, self.nonce == myNonce else { return }
            let decision = AckTimer.decide(elapsedMs: waitMs, clipArrived: self.clipArrived,
                                            preferLocalVoice: preferLocalVoice)
            if decision == .speakLocally {
                self.speakingLocally = true
                Speaker.shared.speak(text)
            }
        }
    }
}

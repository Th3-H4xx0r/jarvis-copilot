import AVFoundation
import Foundation

/// The voice stack's claim on `AVAudioSession`, expressed through
/// `AudioSessionArbiter`.
///
/// A conversation wants `.playAndRecord` + `.videoChat`, kept ACTIVE for the
/// whole turn like a phone/Discord call. `.videoChat` routes to the loud speaker
/// (speakerphone) AND runs echo cancellation, so the loud reply doesn't feed
/// back into the live mic — which is how calling apps get full volume with a
/// simultaneous mic. (`.default` gave the quiet "call-volume" earpiece route,
/// the original complaint.)
///
/// Nothing in the voice stack may touch the session directly: two owners
/// reconfiguring one session is where every past volume/route regression came
/// from, including the mic-stop-on-background dropping us to the earpiece. And
/// the voice stack is not the only owner in the PROCESS either — the background
/// keepalive holds the same session under `.playback` — which is why the actual
/// `setCategory`/`setActive` calls live in the arbiter and this class only
/// raises and lowers a claim.
@MainActor
final class DefaultAudioSessionControlling: AudioSessionControlling {

    /// What a conversation needs. Kept here as the voice-facing names; the
    /// arbiter owns the values because it also has to know them to compute the
    /// union with the keepalive.
    static var category: AVAudioSession.Category { AudioSessionArbiter.voicePlan.category }
    static var mode: AVAudioSession.Mode { AudioSessionArbiter.voicePlan.mode }
    static var options: AVAudioSession.CategoryOptions { AudioSessionArbiter.voicePlan.options }

    var onInterruption: ((AudioInterruption) -> Void)?
    /// `nonisolated(unsafe)`: `deinit` is nonisolated and has to release this.
    nonisolated(unsafe) private var observer: NSObjectProtocol?
    nonisolated(unsafe) private let center: NotificationCenter
    private let arbiter: AudioSessionArbiter

    /// `arbiter:` is an optional rather than a defaulted `.shared`: a default
    /// argument cannot touch a `@MainActor` singleton.
    init(center: NotificationCenter = .default, arbiter: AudioSessionArbiter? = nil) {
        self.center = center
        self.arbiter = arbiter ?? .shared
        observer = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                self.onInterruption?(type == .began ? .began : .ended)
            }
        }
    }

    deinit {
        if let observer { center.removeObserver(observer) }
    }

    /// Raise the voice claim. Idempotent, and idempotent against the SESSION —
    /// not against a `configured` flag.
    ///
    /// `AVAudioSession` is process-wide and this class is not its only writer:
    /// `BackgroundKeepalive` parks it in `.playback` (which cannot record at all)
    /// whenever bridge mode arms, and `SkillBoundariesMedia` sets
    /// `.playAndRecord`/`.default` (which loses the speakerphone route and the
    /// echo cancellation). A one-shot latch meant the FIRST turn of the launch
    /// configured the session and every turn after it silently inherited whatever
    /// the last writer left — a dead mic under `.playback`, or a reply out of the
    /// earpiece with no AEC (so the barge-in detector cuts off our own voice).
    /// The arbiter re-checks the live session on every claim for exactly that
    /// reason.
    func configureForConversation() throws {
        try arbiter.hold(.voice)
    }

    /// `true` claims the session for voice (re-asserting the activation even if
    /// we believe it is already active — after an interruption iOS has
    /// deactivated us under the belief). `false` DROPS the voice claim rather
    /// than deactivating: while the background keepalive still holds the session
    /// the process must keep it, or the app loses its background allowance the
    /// moment a turn ends.
    func setActive(_ active: Bool) throws {
        if active {
            try arbiter.hold(.voice, reassert: true)
        } else {
            try arbiter.release(.voice)
        }
    }
}

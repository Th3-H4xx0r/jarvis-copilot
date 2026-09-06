import AVFoundation
import Foundation

// The one writer of the process-wide `AVAudioSession`.
//
// The app has three clients that all need it and want DIFFERENT things from it:
//
//  * `BackgroundKeepalive` — silent audio under `.playback`, held for the whole
//    launch on a paired phone, which is what stops iOS suspending us and keeps
//    the bridge socket and the BLE link alive in the background;
//  * the voice stack — `.playAndRecord` + `.videoChat` for the length of a turn;
//  * the `record_audio` skill (`DefaultAudioRecorder`) — `.playAndRecord` +
//    `.default` for the length of one clip.
//
// They used to write the session directly, and the session is process-wide, so
// whoever wrote last won. Both losses are silent:
//
//  * keepalive last → `.playback`, which cannot record: `AVAudioEngine`'s
//    `inputNode` has no input route and every turn dies with "Could not start
//    recording: no input route";
//  * voice teardown last → `setActive(false)` while the keepalive's silent
//    engine is still running, so the app quietly loses its background allowance
//    until the next `didBecomeActive`.
//
// The fix is one arbiter holding the union of the claims: voice wins the
// category while a turn is live (`.playAndRecord` earns background execution
// too, so the keepalive loses nothing by it), and the session only deactivates
// once NOBODY holds it.

/// Who wants the session. Not an `OptionSet` on purpose — the plan is chosen by
/// precedence, not by OR-ing flags together.
enum AudioSessionClient: CaseIterable, Sendable {
    case keepalive
    case voice
    /// The `record_audio` skill's clip capture.
    case recording
}

/// The session configuration one set of claims adds up to.
struct AudioSessionPlan: Equatable, Sendable {
    var category: AVAudioSession.Category
    var mode: AVAudioSession.Mode
    var options: AVAudioSession.CategoryOptions
    var active: Bool
}

/// The `AVAudioSession` boundary, behind a protocol so the arbitration is
/// testable without CoreAudio (`MockAudioSessionApplying` in the tests).
@MainActor
protocol AudioSessionApplying: AnyObject {
    var category: AVAudioSession.Category { get }
    var mode: AVAudioSession.Mode { get }
    var categoryOptions: AVAudioSession.CategoryOptions { get }
    func setCategory(_ category: AVAudioSession.Category,
                     mode: AVAudioSession.Mode,
                     options: AVAudioSession.CategoryOptions) throws
    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws
}

@MainActor
final class SystemAudioSession: AudioSessionApplying {
    private let session = AVAudioSession.sharedInstance()

    var category: AVAudioSession.Category { session.category }
    var mode: AVAudioSession.Mode { session.mode }
    var categoryOptions: AVAudioSession.CategoryOptions { session.categoryOptions }

    func setCategory(_ category: AVAudioSession.Category,
                     mode: AVAudioSession.Mode,
                     options: AVAudioSession.CategoryOptions) throws {
        try session.setCategory(category, mode: mode, options: options)
    }

    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
        try session.setActive(active, options: options)
    }
}

@MainActor
final class AudioSessionArbiter {
    static let shared = AudioSessionArbiter()

    /// `.videoChat` routes to the loud speaker AND runs echo cancellation, which
    /// is how calling apps get full volume with a simultaneous live mic.
    /// `.mixWithOthers` stays in the set so the keepalive's silent engine (and
    /// anything else the user is listening to) survives a turn.
    static let voicePlan = AudioSessionPlan(
        category: .playAndRecord,
        mode: .videoChat,
        options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP, .mixWithOthers],
        active: true)

    /// `.playback` is what earns background execution; `.mixWithOthers` keeps us
    /// from ducking whatever the user is actually listening to and from taking
    /// over the lock-screen media controls.
    static let keepalivePlan = AudioSessionPlan(
        category: .playback, mode: .default, options: [.mixWithOthers], active: true)

    /// A `record_audio` clip. `.playAndRecord` rather than `.record` so a capture
    /// doesn't tear down the keepalive's silent playback, `.default` because a
    /// clip is a recording and not a conversation (`.videoChat`'s echo
    /// cancellation would process the very audio the caller asked us to capture),
    /// and `.mixWithOthers` for the same reason it is in every other plan.
    static let recordingPlan = AudioSessionPlan(
        category: .playAndRecord, mode: .default,
        options: [.mixWithOthers, .defaultToSpeaker], active: true)

    /// Nobody wants the session. The category is irrelevant while inactive; only
    /// `active` is acted on.
    static let idlePlan = AudioSessionPlan(
        category: .playback, mode: .default, options: [.mixWithOthers], active: false)

    /// The union rule, as a pure function.
    ///
    /// Precedence, strongest first:
    ///
    ///  * **voice** — a live conversation. `.playAndRecord` is also a
    ///    background-audio category, so a keepalive running underneath a turn
    ///    keeps its allowance, while the reverse (`.playback` under a turn) has
    ///    no input route at all. `.videoChat` also satisfies everything a clip
    ///    capture needs, so a `record_audio` running during a turn rides along.
    ///  * **recording** — a clip capture, which likewise cannot happen under the
    ///    keepalive's `.playback`.
    ///  * **keepalive** — the cheapest claim, and the only one that is content
    ///    with `.playback`.
    static func plan(for holders: Set<AudioSessionClient>) -> AudioSessionPlan {
        if holders.contains(.voice) { return voicePlan }
        if holders.contains(.recording) { return recordingPlan }
        if holders.contains(.keepalive) { return keepalivePlan }
        return idlePlan
    }

    private(set) var holders: Set<AudioSessionClient> = []
    /// What we last applied successfully — the belief `apply` short-circuits on.
    private(set) var applied: AudioSessionPlan?

    private let session: AudioSessionApplying
    private var isActive = false

    /// `session:` is an optional rather than a defaulted `SystemAudioSession()`:
    /// a default argument cannot call a `@MainActor` initialiser.
    init(session: AudioSessionApplying? = nil) {
        self.session = session ?? SystemAudioSession()
    }

    var plan: AudioSessionPlan { Self.plan(for: holders) }

    func holds(_ client: AudioSessionClient) -> Bool { holders.contains(client) }

    /// Claim the session for `client` and apply whatever the union now asks for.
    ///
    /// `reassert` re-activates the live session even when we believe it is
    /// already active — after an interruption or a media-services reset iOS has
    /// deactivated us and our belief is stale. (The category needs no such flag:
    /// it is always compared against the live session, which a reset also
    /// rewrites.)
    func hold(_ client: AudioSessionClient, reassert: Bool = false) throws {
        let held = holders.contains(client)
        holders.insert(client)
        do {
            try apply(forceActivation: reassert)
        } catch {
            // A claim we could not apply is not a claim: leaving it in the set
            // would make a later release deactivate a session this client never
            // got.
            if !held { holders.remove(client) }
            // Then put the live session back on what the surviving claims want.
            // A half-applied plan (category switched, activation refused) would
            // otherwise sit there until somebody else's next hold noticed.
            try? apply()
            throw error
        }
    }

    /// Give up `client`'s claim. Deactivates ONLY when it was the last one — the
    /// bug this class exists to prevent is a voice teardown pulling the session
    /// out from under a running keepalive.
    func release(_ client: AudioSessionClient) throws {
        guard holders.contains(client) else { return }
        holders.remove(client)
        try apply()
    }

    /// Re-apply the current union to the live session (interruption ended,
    /// media services reset, back to foreground).
    func reassert() throws {
        guard !holders.isEmpty else { return }
        try apply(forceActivation: true)
    }

    private func apply(forceActivation: Bool = false) throws {
        let plan = self.plan
        guard plan.active else {
            if isActive {
                // `.notifyOthersOnDeactivation` so whatever we mixed with can
                // come back up to full volume.
                try session.setActive(false, options: [.notifyOthersOnDeactivation])
                isActive = false
            }
            applied = plan
            return
        }
        // Compared against the LIVE session, not against `applied`: this class is
        // not the only thing in the process that can touch the session (a media
        // services reset rewrites it behind our back), and `setCategory` on a
        // session that already matches is a no-op inside CoreAudio anyway.
        if !matches(plan) {
            try session.setCategory(plan.category, mode: plan.mode, options: plan.options)
        }
        if forceActivation || !isActive {
            try session.setActive(true, options: [])
        }
        isActive = true
        applied = plan
    }

    /// `options` is compared as a superset: iOS adds implicit flags of its own
    /// (and refuses some on certain routes), so demanding equality would re-apply
    /// the category on every call.
    private func matches(_ plan: AudioSessionPlan) -> Bool {
        session.category == plan.category
            && session.mode == plan.mode
            && session.categoryOptions.isSuperset(of: plan.options)
    }
}

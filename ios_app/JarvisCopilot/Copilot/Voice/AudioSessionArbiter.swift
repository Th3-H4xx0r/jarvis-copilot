#if os(iOS)
import AVFoundation
#endif
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
    /// Live Jarvis's ambient conversation capture. A SEPARATE claim from `.voice`
    /// on purpose — see `ambientPlan` for why it must not inherit the voice plan.
    case ambient
}

#if os(iOS)

/// The session configuration one set of claims adds up to.
///
/// `sampleRate` and `ioBufferDuration` are what the session COSTS to hold, and
/// every plan states both rather than leaving them at whatever the last holder
/// asked for. They are hardware-wide: a keepalive that quietly left the session
/// at 8 kHz would have the next voice turn capturing the mic at 8 kHz, because
/// `AudioInputEngine` reads `inputFormat(forBus:)` and converts from whatever it
/// finds there.
struct AudioSessionPlan: Equatable, Sendable {
    var category: AVAudioSession.Category
    var mode: AVAudioSession.Mode
    var options: AVAudioSession.CategoryOptions
    var active: Bool
    /// What the hardware should run at while this plan holds.
    var sampleRate: Double
    /// How much audio each render callback covers. This is the wakeup rate: the
    /// audio thread runs once per buffer, so 5 ms costs 200 CPU wakeups a second
    /// and 100 ms costs 10. iOS clamps the request to what the route allows.
    var ioBufferDuration: TimeInterval
}

/// The pair of hardware requests a plan carries, compared as one value so an
/// unchanged plan re-states neither.
struct AudioSessionPreferences: Equatable, Sendable {
    var sampleRate: Double
    var ioBufferDuration: TimeInterval
}

extension AudioSessionPlan {
    var preferences: AudioSessionPreferences {
        AudioSessionPreferences(sampleRate: sampleRate, ioBufferDuration: ioBufferDuration)
    }
}

/// What a plan that is doing real work asks for: 48 kHz, and a buffer short
/// enough that a conversation does not feel laggy.
private let liveSampleRate: Double = 48_000
private let liveBufferDuration: TimeInterval = 0.02

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
    func setPreferredSampleRate(_ rate: Double) throws
    func setPreferredIOBufferDuration(_ duration: TimeInterval) throws
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

    func setPreferredSampleRate(_ rate: Double) throws {
        try session.setPreferredSampleRate(rate)
    }

    func setPreferredIOBufferDuration(_ duration: TimeInterval) throws {
        try session.setPreferredIOBufferDuration(duration)
    }
}

#endif

@MainActor
final class AudioSessionArbiter {
    static let shared = AudioSessionArbiter()

    #if os(iOS)

    /// `.videoChat` routes to the loud speaker AND runs echo cancellation, which
    /// is how calling apps get full volume with a simultaneous live mic.
    /// `.mixWithOthers` stays in the set so the keepalive's silent engine (and
    /// anything else the user is listening to) survives a turn.
    static let voicePlan = AudioSessionPlan(
        category: .playAndRecord,
        mode: .videoChat,
        options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP, .mixWithOthers],
        active: true,
        sampleRate: liveSampleRate, ioBufferDuration: liveBufferDuration)

    /// `.playback` is what earns background execution; `.mixWithOthers` keeps us
    /// from ducking whatever the user is actually listening to and from taking
    /// over the lock-screen media controls.
    ///
    /// 8 kHz and a tenth of a second per buffer because this plan renders SILENCE
    /// and nothing else: iOS grants the background allowance for rendering audio,
    /// not for rendering it often or well. At the default buffer the silent engine
    /// woke the CPU 40-200 times a second for as long as the app was backgrounded,
    /// which is most of a day; this asks for ten.
    static let keepalivePlan = AudioSessionPlan(
        category: .playback, mode: .default, options: [.mixWithOthers], active: true,
        sampleRate: keepaliveSampleRate, ioBufferDuration: 0.1)

    /// The rate the silent engine renders at, so its buffer matches the hardware
    /// and the mixer has no rate conversion to do.
    static let keepaliveSampleRate: Double = 8_000

    /// A `record_audio` clip. `.playAndRecord` rather than `.record` so a capture
    /// doesn't tear down the keepalive's silent playback, `.default` because a
    /// clip is a recording and not a conversation (`.videoChat`'s echo
    /// cancellation would process the very audio the caller asked us to capture),
    /// and `.mixWithOthers` for the same reason it is in every other plan.
    static let recordingPlan = AudioSessionPlan(
        category: .playAndRecord, mode: .default,
        options: [.mixWithOthers, .defaultToSpeaker], active: true,
        sampleRate: liveSampleRate, ioBufferDuration: liveBufferDuration)

    /// Live Jarvis's ambient capture — a room, for hours.
    ///
    /// Three deliberate differences from `voicePlan`, all from design §5.1:
    ///
    ///  * **`.default`, NOT `.videoChat`.** `.videoChat` is echo cancellation plus
    ///    noise suppression plus automatic gain control, tuned for one person
    ///    talking close into the phone. Everything it is good at is wrong here: it
    ///    treats a voice across the room as the noise it is built to remove, so the
    ///    distant speakers ambient mode exists to hear are the ones it attenuates.
    ///  * **`.allowBluetooth`** earns the hands-free profile, which is what makes
    ///    AirPods (and any other Bluetooth headset) selectable as an INPUT rather
    ///    than output-only. `voicePlan` has it too, but here it is load-bearing: it
    ///    is the whole capture-source picker for anything not built into the phone.
    ///  * **A tenth of a second per buffer**, like the keepalive and unlike the
    ///    voice turn's 20 ms. The audio thread wakes once per buffer, so this is 10
    ///    wakeups a second instead of 50 — and a capture that may run all day pays
    ///    that bill continuously. Nothing is waiting on a reply, so the latency the
    ///    long buffer costs buys real battery. (§11 lists battery as an open risk;
    ///    this is the cheap half of the answer.)
    ///
    /// It stays `.playAndRecord` rather than `.record`: a Live session can speak a
    /// reply (`speak: true`, `reply_mode: "spoken"`), and `.playAndRecord` is also
    /// a background-audio category, so capture survives the screen locking.
    static let ambientPlan = AudioSessionPlan(
        category: .playAndRecord,
        mode: .default,
        options: [.mixWithOthers, .defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP],
        active: true,
        sampleRate: liveSampleRate, ioBufferDuration: 0.1)

    /// Nobody wants the session. The category is irrelevant while inactive; only
    /// `active` is acted on.
    static let idlePlan = AudioSessionPlan(
        category: .playback, mode: .default, options: [.mixWithOthers], active: false,
        sampleRate: liveSampleRate, ioBufferDuration: liveBufferDuration)

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
    ///  * **ambient** — Live Jarvis. Below `recording` because a clip capture is a
    ///    short, explicitly-asked-for thing and `recordingPlan` is recordable
    ///    anyway, so ambient capture rides along under it rather than fighting it.
    ///    Above `keepalive`, which cannot record at all. A voice turn taken DURING
    ///    an ambient capture does win the category, which means far-field quality
    ///    degrades for the length of that turn — the honest trade: the conversation
    ///    the user is having right now outranks the room they are in.
    ///  * **keepalive** — the cheapest claim, and the only one that is content
    ///    with `.playback`.
    static func plan(for holders: Set<AudioSessionClient>) -> AudioSessionPlan {
        if holders.contains(.voice) { return voicePlan }
        if holders.contains(.recording) { return recordingPlan }
        if holders.contains(.ambient) { return ambientPlan }
        if holders.contains(.keepalive) { return keepalivePlan }
        return idlePlan
    }

    #endif

    private(set) var holders: Set<AudioSessionClient> = []

    #if os(iOS)

    private let session: AudioSessionApplying
    private var isActive = false

    /// `session:` is an optional rather than a defaulted `SystemAudioSession()`:
    /// a default argument cannot call a `@MainActor` initialiser.
    init(session: AudioSessionApplying? = nil) {
        self.session = session ?? SystemAudioSession()
    }

    var plan: AudioSessionPlan { Self.plan(for: holders) }

    /// The last rate/buffer pair we asked for, so an unchanged plan does not
    /// re-request them on every hold and release.
    private var appliedPreferences: AudioSessionPreferences?

    #endif

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

    #if os(iOS)

    private func apply(forceActivation: Bool = false) throws {
        let plan = self.plan
        guard plan.active else {
            if isActive {
                // `.notifyOthersOnDeactivation` so whatever we mixed with can
                // come back up to full volume.
                try session.setActive(false, options: [.notifyOthersOnDeactivation])
                isActive = false
            }
            return
        }
        // Compared against the LIVE session: this class is
        // not the only thing in the process that can touch the session (a media
        // services reset rewrites it behind our back), and `setCategory` on a
        // session that already matches is a no-op inside CoreAudio anyway.
        if !matches(plan) {
            try session.setCategory(plan.category, mode: plan.mode, options: plan.options)
        }
        // Preferences, not commands: iOS clamps both to what the current route
        // allows and may ignore them outright, so they are never compared against
        // the live session — only re-stated whenever the plan changes. Applied
        // before activation, which is when they take effect. A refusal is not
        // fatal: the wrong buffer size costs battery, a throw here would cost the
        // whole claim.
        if appliedPreferences != plan.preferences {
            try? session.setPreferredSampleRate(plan.sampleRate)
            try? session.setPreferredIOBufferDuration(plan.ioBufferDuration)
            appliedPreferences = plan.preferences
        }
        if forceActivation || !isActive {
            try session.setActive(true, options: [])
        }
        isActive = true
    }

    /// `options` is compared as a superset: iOS adds implicit flags of its own
    /// (and refuses some on certain routes), so demanding equality would re-apply
    /// the category on every call.
    private func matches(_ plan: AudioSessionPlan) -> Bool {
        session.category == plan.category
            && session.mode == plan.mode
            && session.categoryOptions.isSuperset(of: plan.options)
    }

    #else

    /// macOS has no process-wide audio session: there is no `AVAudioSession`, no
    /// category to lose and nothing for the three clients to clobber — CoreAudio
    /// picks the default input and output devices itself. The claims are still
    /// tracked, because `holds(_:)` and the hold/release pairing are shared code
    /// the voice stack relies on; applying them is simply nothing.
    private func apply(forceActivation: Bool = false) throws {}

    #endif
}

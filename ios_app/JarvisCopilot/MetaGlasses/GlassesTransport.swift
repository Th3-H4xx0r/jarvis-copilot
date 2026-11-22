import Foundation

/// The lifecycle state of a glasses link, as the session sees it through a `GlassesTransport`.
///
/// This abstracts away whether the bytes move over a real BLE L2CAP channel
/// (`MetaGlassesTransport`) or an in-memory `SimulatedGlassesTransport`.
enum GlassesLinkState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case trusted          // AirShield owner-trust proven (real) / assumed (simulated)
    case ready            // link up, trusted, wake word armable
    case failed(String)
}

/// A logical event the glasses push up to the phone. These are the *decoded meanings* of the
/// protocol's inbound frames — NOT the AirShield wire format (that stays in the real transport).
/// The simulator emits these directly so the session logic can be exercised with no hardware.
enum GlassesInboundEvent: Sendable {
    /// The link's lifecycle changed. Used for runtime drops/reconnects; `MetaGlassesSession.start()`
    /// drives the initial connect→trusted→ready itself.
    case linkState(GlassesLinkState)
    /// The on-glasses "Hey Jarvis" detector fired. Starts a voice turn.
    case wake
    /// On-device speech recognition result for the current utterance (Gen 2 sends text, plan §4).
    case userTranscript(text: String, isFinal: Bool)
    /// Raw follow-up microphone PCM (16 kHz mono Int16) from the glasses.
    case userAudio(Data)
    /// The assistant's answer to render on the lens. In production this is produced by
    /// `VoiceStore` on the phone; the simulator supplies a canned reply so the render path can
    /// be driven without a live turn.
    case assistantAnswer(text: String, isFinal: Bool)
    /// A still captured by the glasses camera, as JPEG bytes (plan §6.2).
    case photo(Data)
    /// A touchpad gesture on the glasses arm (plan §6.5).
    case touch(MetaTouchGesture)
    /// A video clip finished (cap reached, stopped, or cut short — `stopReason` says why).
    case video(MetaClip)
    /// One live-stream frame (JPEG, ≤720×1280).
    case liveFrame(Data)
}

/// A recorded clip as the glasses report it.
struct MetaClip: Equatable, Sendable {
    var seconds: Double
    var mode: MetaVideoMode
    var bytes: Int64
    /// The movie file once imported to the phone (nil for a test-scene clip with no real video).
    var fileURL: URL?
    /// Set when the glasses ended it early (LED covered, too hot, battery low, storage full…).
    var stopReason: String?
}

/// Media keys the glasses send the phone (AVRCP) — their touchpad defaults.
enum MetaMediaCommand: String, Sendable {
    case playPause, next, previous
}

/// A logical frame the phone sends down to the glasses. Again, these are *meanings*; the real
/// transport seals them into AirShield frames, the simulator just records them for assertions.
enum GlassesFrame: Equatable, Sendable {
    case enableWakeWord
    case showTranscript(text: String, isFinal: Bool)
    case showAnswer(text: String, isFinal: Bool)
    case setSpeaking(Bool)
    case capturePhoto(question: String?)
    case closeAssistant
    case startVideo(seconds: Int)
    case stopVideo
    case startLiveStream
    case stopLiveStream
    /// Say text through the glasses' open-ear speakers.
    case speak(text: String)
    case setVolume(Int)
    case setClipLength(Int)
    case setVideoMode(MetaVideoMode)
}

/// A touchpad gesture on the glasses arm.
enum MetaTouchGesture: String, Sendable, CaseIterable {
    case tap, doubleTap, tripleTap, hold, swipeForward, swipeBackward, capture
}

/// What a touch gesture does ON THE GLASSES. These defaults can't be suppressed (research doc);
/// a Jarvis action bound to the gesture runs in addition (plan §6.5).
enum MetaTouchAction: Equatable, Sendable {
    case none
    case startAssistant
    case endAssistant
    case capturePhoto
    case nextTrack
    case previousTrack
    case playPause
    case volumeUp
    case volumeDown
}

enum MetaTouchBinding {
    /// The glasses' own gesture map: tap = play/pause, double = next, triple = previous,
    /// hold = the assistant (Jarvis, since Jarvis owns the glasses), swipes = volume, the
    /// capture button = a photo (hold it for video).
    static func defaultAction(for gesture: MetaTouchGesture) -> MetaTouchAction {
        switch gesture {
        case .tap: return .playPause
        case .doubleTap: return .nextTrack
        case .tripleTap: return .previousTrack
        case .hold: return .startAssistant
        case .swipeForward: return .volumeUp
        case .swipeBackward: return .volumeDown
        case .capture: return .capturePhoto
        }
    }

    static func label(_ gesture: MetaTouchGesture) -> String {
        switch gesture {
        case .tap: return "Tap"
        case .doubleTap: return "Double tap"
        case .tripleTap: return "Triple tap"
        case .hold: return "Touch and hold"
        case .swipeForward: return "Swipe forward"
        case .swipeBackward: return "Swipe back"
        case .capture: return "Capture button"
        }
    }

    static func label(_ action: MetaTouchAction) -> String {
        switch action {
        case .none: return "Nothing"
        case .startAssistant: return "Jarvis"
        case .endAssistant: return "End Jarvis"
        case .capturePhoto: return "Photo"
        case .nextTrack: return "Next track"
        case .previousTrack: return "Previous track"
        case .playPause: return "Play / pause"
        case .volumeUp: return "Volume up"
        case .volumeDown: return "Volume down"
        }
    }

    static var defaults: [MetaTouchGesture: MetaTouchAction] {
        var map: [MetaTouchGesture: MetaTouchAction] = [:]
        for gesture in MetaTouchGesture.allCases { map[gesture] = defaultAction(for: gesture) }
        return map
    }
}

/// Errors specific to the Meta glasses device/session. Kept local so the shared
/// `DeviceError.confirmationRequired` (whose message is bottle/UV-lamp specific) is not
/// mis-reused for the camera shutter.
enum MetaGlassesError: LocalizedError {
    case notReady
    case shutterConfirmationRequired
    case busy(String)
    case timedOut(String)
    case transportUnavailable(String)
    /// The glasses themselves refused (a hardware limit: LED covered, too hot, folded…).
    case refused(String)

    var errorDescription: String? {
        switch self {
        case .notReady:
            return "the Meta glasses link is not ready"
        case .shutterConfirmationRequired:
            return "meta_glasses_photo captures from the glasses camera — pass confirm=true to take the photo (the capture LED stays on)"
        case .busy(let what):
            return "Meta glasses busy: \(what)"
        case .timedOut(let what):
            return "Meta glasses timed out: \(what)"
        case .transportUnavailable(let why):
            return "Meta glasses transport unavailable: \(why)"
        case .refused(let why):
            return why
        }
    }
}

/// The lowest layer the session talks to: deliver frames down, surface events up, report link
/// state. One implementation is the real CoreBluetooth L2CAP transport (`MetaGlassesTransport`,
/// a documented skeleton); the other is the in-memory `SimulatedGlassesTransport` used by tests.
@MainActor
protocol GlassesTransport: AnyObject {
    var linkState: GlassesLinkState { get }
    /// The inbound event stream. Consumed once, by the owning `MetaGlassesSession`.
    var inbound: AsyncStream<GlassesInboundEvent> { get }
    /// Establish the link (and, for the real transport, run the AirShield handshake + owner
    /// trust). Resolves when the link is ready, or throws.
    func connect() async throws
    /// Send one logical frame to the glasses.
    func send(_ frame: GlassesFrame) async throws
    /// Tear the link down and finish the inbound stream.
    func disconnect() async
    /// Battery, heat, storage, worn/folded… as the glasses report it. Nil until known.
    var hardware: MetaHardwareState? { get }
}

extension GlassesTransport {
    var hardware: MetaHardwareState? { nil }
}

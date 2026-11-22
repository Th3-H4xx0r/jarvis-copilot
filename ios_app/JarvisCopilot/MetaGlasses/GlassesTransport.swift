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
}

/// A touchpad gesture on the glasses arm.
enum MetaTouchGesture: String, Sendable, CaseIterable {
    case tap, doubleTap, tripleTap, hold, swipeForward, swipeBackward, capture
}

/// What a touch gesture is bound to do. A small-scale stand-in for the shared Ring action idea
/// (plan §6.5) without pulling the Ring picker into scaffolding.
enum MetaTouchAction: Equatable, Sendable {
    case none
    case startAssistant
    case endAssistant
    case capturePhoto
    case nextTrack
    case previousTrack
}

enum MetaTouchBinding {
    /// The default gesture→action map. Music gestures keep A2DP playback (plan §6.3); the
    /// assistant is reached with a double tap, matching the Meta default most closely.
    static func defaultAction(for gesture: MetaTouchGesture) -> MetaTouchAction {
        switch gesture {
        case .tap: return .none
        case .doubleTap: return .startAssistant
        case .tripleTap: return .endAssistant
        case .hold: return .startAssistant
        case .swipeForward: return .nextTrack
        case .swipeBackward: return .previousTrack
        case .capture: return .capturePhoto
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
}

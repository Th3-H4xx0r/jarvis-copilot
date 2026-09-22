import ActivityKit
import Foundation

/// Live Jarvis recording the room, on the Lock Screen and in the Dynamic
/// Island. Shared by the app (which captures) and the widget (which draws it).
///
/// **The elapsed clock is in the ATTRIBUTES, not the state.** `startedAt` is
/// fixed for the life of the activity, so the widget hands it to
/// `Text(timerInterval:)` and the SYSTEM renders the ticking clock with no
/// pushes from us at all. The alternative — pushing a new elapsed figure every
/// second — is the one thing iOS's update budget will not tolerate: it throttles
/// the app, and the update it drops is usually the one that mattered (see
/// `VoiceLiveActivityThrottle`, which exists because the island got stuck on
/// "Listening" after Stop).
///
/// Everything in `ContentState` therefore changes on an EVENT, never on a tick:
/// the mic being taken, the retained-audio figure moving, the state qualifier.
struct LiveCaptureAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// True while another app holds the mic (a call, Siri). The widget then
        /// freezes the clock at `pausedElapsed` and says "Paused" in words.
        var paused: Bool = false
        /// Seconds captured when the pause began. Only read while `paused`.
        var pausedElapsed: TimeInterval = 0
        /// The retained-audio figure in the store's own words — "2.4 MB stored".
        /// Passed through rather than re-derived: the app is the only thing that
        /// knows how the server accounts for the bytes.
        var kept: String = ""
        /// A qualifier that must be stated rather than implied — "Buffer not
        /// saved to disk", "Jarvis isn't receiving audio". "" = nothing to add.
        var detail: String = ""
    }

    /// The instant capture began. Immutable, which is the whole point.
    var startedAt: Date
    /// Always "Live Jarvis" today; a field so the island can name a source
    /// later ("Live Jarvis · AirPods") without a new activity type.
    var title: String = "Live Jarvis"

    /// Both strings are clamped to this before they go on the wire. The ~4 KB
    /// `ContentState` budget is a HARD failure — iOS drops the update silently —
    /// so the figures are bounded at the source rather than hoped about.
    static let maxTextChars = 64
}

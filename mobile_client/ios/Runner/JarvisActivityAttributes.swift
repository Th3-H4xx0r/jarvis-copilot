import ActivityKit
import Foundation

/// Attributes for the JARVIS Live Activity (Dynamic Island + Lock Screen).
///
/// Shared between the Runner app (which starts/ends the activity via ActivityKit)
/// and the JarvisWidget extension (which renders it). Member of BOTH targets.
/// Intentionally minimal — a static title, no dynamic content state.
@available(iOS 16.2, *)
struct JarvisActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// Voice FSM: idle | listening | thinking | speaking | error.
        var state: String = "idle"
        /// What YOU said this turn (shown in the expanded view). May be empty.
        var transcript: String = ""
        /// JARVIS's side — a reply snippet or a tool status like
        /// "Searching the web…". May be empty.
        var activity: String = ""
        /// Server link status (drives the Connected / Offline footer).
        var connected: Bool = true
        /// Apple Watch paired + app installed (shown in the devices strip).
        var watchPresent: Bool = false
        /// Apple Watch currently reachable.
        var watchOnline: Bool = false
    }
    var title: String = "JARVIS"
}

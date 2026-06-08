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
        /// Icon kinds for every ONLINE connected device, rendered as a centered
        /// strip — e.g. ["laptop","phone","watch"]. Sourced from the server's
        /// /api/devices (online only); the Apple Watch is folded in natively from
        /// WCSession since it relays through the phone rather than the server.
        var devices: [String] = []

        // ── Coding mode ──────────────────────────────────────────────────────
        // When voice is idle and there are live Claude Code sessions, the same
        // activity flips to a fleet view (Scheme 4). When voice is active it
        // stays "voice" and the fields above drive the (unchanged) voice UI.
        /// "voice" (existing UI) or "coding" (the Claude Code fleet view).
        var mode: String = "voice"
        /// Up to ~4 spotlight sessions, each encoded "name\u{1f}state" where
        /// state ∈ working|waiting|idle. Decoded by the widget.
        var sessions: [String] = []
        /// Total live sessions (drives the header "N sessions").
        var sessionTotal: Int = 0
        /// Total legend ENTRIES (projects + ungrouped sessions) — drives the
        /// "+N more" overflow (sessions is capped at 4). Distinct from
        /// sessionTotal because a project can hold several sessions.
        var entryTotal: Int = 0
        /// How many sessions are waiting on you (drives the header accent).
        var waitingCount: Int = 0
        /// 5-hour / weekly usage percent, 0–100 (-1 = unknown → render "—").
        var usage5: Int = -1
        var usageWeek: Int = -1
        /// Short reset hints, e.g. "2h 10m" / "Mon" ("" = hide).
        var usage5Resets: String = ""
        var usageWeekResets: String = ""
    }
    var title: String = "JARVIS"
}

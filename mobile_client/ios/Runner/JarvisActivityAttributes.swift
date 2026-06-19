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
        /// "voice" (existing UI), "coding" (the Claude Code fleet view), or
        /// "custom" (a data-driven design rendered by JCDesignView from a layout
        /// tree cached on-device by `designId`).
        var mode: String = "voice"
        /// Up to ~4 spotlight sessions, each encoded "name\u{1f}state[\u{1f}subs]"
        /// where state ∈ working|waiting|idle and the optional 3rd field is a
        /// comma-joined per-session sub-state list (shorthand w/p/i) present only
        /// when a project has 2+ live sessions (drives the split bar). Decoded by
        /// the widget.
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

        // ── Custom mode (Dynamic Island Designs) ─────────────────────────────
        // When `mode == "custom"`, JCDesignView (in JarvisWidget) renders a
        // data-driven layout tree instead of the voice/coding views. The tree
        // itself is NOT in the ContentState (it would blow the ~4KB cap) — it is
        // cached on-device under the App Group `island/design-<designId>.json`
        // (written via the `jarviscopilot/island` channel). The state carries
        // only the design selector + the live values to bind into it.
        //
        // IMPORTANT: Swift synthesizes NO defaults for missing Codable keys, so
        // every pusher (Dart coordinator, coding_la_push, island_la_push, the
        // resting state) must ALWAYS send these three keys. The defaults here are
        // only the in-process fallback for a struct built without them.
        /// Id of the cached design to render. "" → fall back (never crash/blank).
        var designId: String = ""
        /// Version of the cached design; lets the widget pick the right cached
        /// file / a future cache to ignore a stale design. 0 = unset.
        var designVersion: Int = 0
        /// JSON-encoded object string of the live values bound into the design
        /// (resolved ValueRefs: `{"$":"key"}` reads keys from this object).
        /// Kept as a string so the 4KB cap is measured on the wire, not on a
        /// nested Codable. "" → no bindings (render literals / placeholders).
        var data: String = ""
    }
    var title: String = "JARVIS"
}

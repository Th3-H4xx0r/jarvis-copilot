import ActivityKit
import Foundation

/// Attributes for the JARVIS Live Activity (Dynamic Island + Lock Screen).
///
/// Shared between the app (which starts/ends the activity via ActivityKit)
/// and the JarvisWidget extension (which renders it). Compiled into BOTH targets.
/// The `ContentState` is the whole wire format between them.
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
        // (written via `AppGroupIslandDesignCache`). The state carries
        // only the design selector + the live values to bind into it.
        //
        // IMPORTANT: Swift synthesizes NO defaults for missing Codable keys, so
        // every pusher (`LiveActivityCoordinator`, the server’s push-to-update payloads, the
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

        // ── Coding mode: the most urgent agent session (hook-tracked) ────────
        /// "Claude Code", "Codex"… ("" → no lead session; the fleet view only).
        var leadAgent: String = ""
        var leadProject: String = ""
        /// working | thinking | approval | question | finished | error | ratelimit | idle
        var leadState: String = ""
        /// What it is doing right now, e.g. "Bash: npm test" (≤ 60 chars).
        var leadStep: String = ""
        /// The waiting approval's fingerprint: the Allow / Deny buttons answer this one.
        var leadFingerprint: String = ""
        /// "approval" | "question" | "" — which buttons the waiting request gets.
        var leadKind: String = ""
        /// When the lead session started its turn (Unix seconds; 0 = unknown).
        var leadSince: Double = 0
        /// The engine key, for the tap's deep link.
        var leadKey: String = ""
    }
    var title: String = "JARVIS"
}

extension JarvisActivityAttributes.ContentState {
    /// Every key is optional on the wire: a payload from an older server (or a
    /// pusher that doesn't know a newer field) decodes with the defaults instead
    /// of failing — a failed decode leaves the Live Activity frozen.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? d.state
        transcript = try c.decodeIfPresent(String.self, forKey: .transcript) ?? d.transcript
        activity = try c.decodeIfPresent(String.self, forKey: .activity) ?? d.activity
        connected = try c.decodeIfPresent(Bool.self, forKey: .connected) ?? d.connected
        devices = try c.decodeIfPresent([String].self, forKey: .devices) ?? d.devices
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? d.mode
        sessions = try c.decodeIfPresent([String].self, forKey: .sessions) ?? d.sessions
        sessionTotal = try c.decodeIfPresent(Int.self, forKey: .sessionTotal) ?? d.sessionTotal
        entryTotal = try c.decodeIfPresent(Int.self, forKey: .entryTotal) ?? d.entryTotal
        waitingCount = try c.decodeIfPresent(Int.self, forKey: .waitingCount) ?? d.waitingCount
        usage5 = try c.decodeIfPresent(Int.self, forKey: .usage5) ?? d.usage5
        usageWeek = try c.decodeIfPresent(Int.self, forKey: .usageWeek) ?? d.usageWeek
        usage5Resets = try c.decodeIfPresent(String.self, forKey: .usage5Resets) ?? d.usage5Resets
        usageWeekResets = try c.decodeIfPresent(String.self, forKey: .usageWeekResets) ?? d.usageWeekResets
        designId = try c.decodeIfPresent(String.self, forKey: .designId) ?? d.designId
        designVersion = try c.decodeIfPresent(Int.self, forKey: .designVersion) ?? d.designVersion
        data = try c.decodeIfPresent(String.self, forKey: .data) ?? d.data
        leadAgent = try c.decodeIfPresent(String.self, forKey: .leadAgent) ?? d.leadAgent
        leadProject = try c.decodeIfPresent(String.self, forKey: .leadProject) ?? d.leadProject
        leadState = try c.decodeIfPresent(String.self, forKey: .leadState) ?? d.leadState
        leadStep = try c.decodeIfPresent(String.self, forKey: .leadStep) ?? d.leadStep
        leadFingerprint = try c.decodeIfPresent(String.self, forKey: .leadFingerprint) ?? d.leadFingerprint
        leadKind = try c.decodeIfPresent(String.self, forKey: .leadKind) ?? d.leadKind
        leadSince = try c.decodeIfPresent(Double.self, forKey: .leadSince) ?? d.leadSince
        leadKey = try c.decodeIfPresent(String.self, forKey: .leadKey) ?? d.leadKey
    }
}

import Foundation

/// Everything the Live Activity shows, in one value.
///
/// The Flutter coordinator built an untyped `Map<String, dynamic>` and deduped on
/// its JSON encoding; a struct gets the same collision-proof dedupe for free from
/// `Equatable` (a session title containing the delimiter can't fake a match the
/// way a `join()` would) and stops a typo from silently dropping a field.
///
/// Mirrors `JarvisActivityAttributes.ContentState` field for field.
struct LiveActivityState: Equatable, Sendable {
    // Voice
    /// idle | listening | thinking | speaking | error.
    var state = "idle"
    var transcript = ""
    var activity = ""
    var connected = true
    var devices: [String] = []

    /// "voice" | "coding" | "custom".
    var mode = "voice"

    // Coding fleet
    var sessions: [String] = []
    var sessionTotal = 0
    var entryTotal = 0
    var waitingCount = 0
    var usage5 = -1
    var usageWeek = -1
    var usage5Resets = ""
    var usageWeekResets = ""

    // Custom design
    var designId = ""
    var designVersion = 0
    var data = ""

    /// The widget only ever starts an activity for something that is happening:
    /// a live voice turn, live coding sessions, or a selected custom design.
    /// Anything else would put an empty island on the user's Lock Screen.
    var isWorthStarting: Bool {
        if mode == "coding" && sessionTotal > 0 { return true }
        if mode == "custom" && !designId.isEmpty { return true }
        return state != "idle"
    }
}

/// The coding half of the island: up to four spotlight rows plus the counts the
/// header renders. Pure, so the whole encoding is testable off one fixture.
///
/// Port of `LiveActivityCoordinator._applyFleet`.
struct LiveFleet: Equatable, Sendable {
    /// `"name␟state[␟subs]"`, at most 4, spotlight-sorted.
    var sessions: [String] = []
    /// Total live sessions — the header's "N sessions".
    var sessionTotal = 0
    /// Total legend ROWS (projects + ungrouped), which drives "+N more" because
    /// `sessions` is capped at 4. Distinct from `sessionTotal`: one project can
    /// hold several sessions.
    var entryTotal = 0
    /// How many sessions are waiting on the user (drives the header accent).
    var waitingCount = 0

    static let empty = LiveFleet()

    /// Unit separator. Chosen because it cannot appear in a project name.
    static let separator = "\u{1f}"
    /// Beyond this the row is unreadable at island width, and the ~4 KB
    /// ContentState cap starts to matter.
    static let labelLimit = 22
    static let maxRows = 4
    static let maxSubStates = 8

    static func from(_ view: CodingProjectsView) -> LiveFleet {
        struct Entry {
            var label: String
            var state: String
            var recency: Double
            var subs: [String]
        }
        var entries: [Entry] = []
        var total = 0
        var waiting = 0

        for project in view.projects {
            // One legend row per PROJECT, labelled by the project (a repo/folder)
            // — NOT the session title, which can be a transcript artefact like
            // "<local-command-stdout>".
            let live = project.sessions.filter { $0.isLive && !$0.isTranscriptIdle }
            guard !live.isEmpty else { continue }
            total += live.count
            waiting += live.filter { $0.liveState == "waiting" }.count
            let subs = live.map(\.fleetState)
                .sorted { statePriority($0) < statePriority($1) }
                .prefix(maxSubStates)
            entries.append(Entry(label: project.name,
                                 state: aggregateState(live),
                                 recency: live.map(\.recencyTs).max() ?? 0,
                                 subs: Array(subs)))
        }

        for session in view.ungrouped where session.isLive && !session.isTranscriptIdle {
            total += 1
            if session.liveState == "waiting" { waiting += 1 }
            entries.append(Entry(label: folderName(session),
                                 state: session.fleetState,
                                 recency: session.recencyTs,
                                 subs: [session.fleetState]))
        }

        entries.sort { a, b in
            let pa = statePriority(a.state), pb = statePriority(b.state)
            if pa != pb { return pa < pb }
            return a.recency > b.recency      // newer first within a tier
        }

        let rows = entries.prefix(maxRows).map { entry -> String in
            var encoded = sanitize(entry.label) + separator + entry.state
            // The third field (per-session sub-states) is added only for a
            // project with 2+ live sessions, so a single-session row still
            // renders as one solid segment.
            if entry.subs.count > 1 { encoded += separator + encodeSubs(entry.subs) }
            return encoded
        }

        return LiveFleet(sessions: Array(rows), sessionTotal: total,
                         entryTotal: entries.count, waitingCount: waiting)
    }

    /// waiting > working > idle > dim. `dim` is a forgotten detached+idle
    /// session, which sorts last so it never takes a spotlight row from live work.
    static func statePriority(_ state: String) -> Int {
        switch state {
        case "waiting": return 0
        case "working": return 1
        case "idle":    return 2
        default:        return 3
        }
    }

    static func aggregateState(_ live: [CodingSession]) -> String {
        if live.contains(where: { $0.fleetState == "waiting" }) { return "waiting" }
        if live.contains(where: { $0.fleetState == "working" }) { return "working" }
        if live.contains(where: { $0.fleetState == "idle" }) { return "idle" }
        return "dim"
    }

    static func encodeSubs(_ subs: [String]) -> String {
        subs.prefix(maxSubStates).map { shortState[$0] ?? "i" }.joined(separator: ",")
    }

    private static let shortState = [
        "working": "w", "waiting": "p", "idle": "i", "dim": "d",
    ]

    static func folderName(_ session: CodingSession) -> String {
        let cwd = (session.cwd ?? "").trimmingCharacters(in: .whitespaces)
        if !cwd.isEmpty {
            var trimmed = cwd
            while trimmed.hasSuffix("/") { trimmed.removeLast() }
            if let base = trimmed.split(separator: "/").last, !base.isEmpty {
                return String(base)
            }
        }
        return "session"
    }

    static func sanitize(_ text: String) -> String {
        var out = text.replacingOccurrences(of: separator, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if out.count > labelLimit { out = String(out.prefix(labelLimit - 1)) + "…" }
        return out
    }
}

/// Starting, updating and ending the OS-level activity.
///
/// Behind a protocol because `ActivityKit` needs a real device context (and iOS
/// 16.2+), so every policy decision above it is asserted against a fake instead.
@MainActor
protocol ActivityControlling: AnyObject {
    /// False when the user has Live Activities switched off system-wide, or the
    /// OS is too old. The coordinator still tracks state; it just never pushes.
    var areActivitiesEnabled: Bool { get }
    /// Create the activity on the first state worth showing, else update the
    /// running one. Never ends it — the island lingers as a tap-to-talk launcher
    /// (the Flutter client pushes an explicit "idle" on stop).
    func update(_ state: LiveActivityState)
    func end()
    /// Called with each activity's APNs push token, so the server can
    /// push-to-update while the app is suspended. Tokens rotate.
    var onPushToken: ((String) -> Void)? { get set }
}

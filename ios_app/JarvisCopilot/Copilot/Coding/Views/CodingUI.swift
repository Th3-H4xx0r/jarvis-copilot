import SwiftUI

/// The Coding tab's pure presentation rules: the colours a fleet state paints,
/// the labels a sync status reads as, how the Projects→Sessions tree is grouped,
/// how a timestamp is written, and how a terminal viewport is measured.
///
/// Everything here is a pure function of its inputs so the views stay dumb and
/// the rules are unit-tested (`JarvisCopilotTests/CodingUI/`). The colour
/// values are the Flutter page's literals, not `JcTheme` lookups, wherever the
/// Dart code used a literal — the fleet's green/purple/grey ladder is a
/// deliberate scheme of its own ("Scheme 4" in `coding_page.dart`).
enum CodingUI {

    // MARK: - Palette

    /// Working — a live turn is in flight.
    static let green = Color(jcHex: 0x34D399)
    /// Waiting — Claude is asking for input. Also the approval/subagent accent.
    static let purple = Color(jcHex: 0xC084FC)
    /// Idle — alive but nothing happening.
    static let grey = Color(jcHex: 0x838B97)
    /// Forgotten (detached + idle) — de-emphasised, not hidden.
    static let dimGrey = Color(jcHex: 0x5A6068)
    /// The terminal / code-block ground, matching the WebUI pane.
    static let pane = Color(jcHex: 0x0A0D13)
    /// Monospace foreground inside panes and tool output.
    static let paneText = Color(jcHex: 0xD7DAE0)
    static let paneMuted = Color(jcHex: 0xB9BFC9)
    /// Diff add / delete.
    static let diffAdd = Color(jcHex: 0x34D399)
    static let diffDel = Color(jcHex: 0xF87171)

    // MARK: - Fleet state

    /// Dot colour for `CodingSession.fleetState`
    /// (working | waiting | idle | dim | history | running | done | error | stopped).
    static func stateColor(_ state: String) -> Color {
        switch state {
        case "working": return green
        case "waiting": return purple
        case "running": return JcTheme.success
        case "done":    return JcTheme.primaryBlue
        case "error":   return JcTheme.danger
        case "idle":    return grey
        case "dim":     return dimGrey
        default:        return JcTheme.muted
        }
    }

    /// One word for the state, used by the row's accessibility label and the
    /// group header's summary.
    static func stateLabel(_ state: String) -> String {
        switch state {
        case "working": return "working"
        case "waiting": return "needs input"
        case "history": return "history"
        case "dim":     return "detached"
        default:        return state
        }
    }

    /// The host/source badge colour (`CodingSession.badge.kind`).
    static func badgeColor(kind: String) -> Color {
        switch kind {
        case "discovered": return JcTheme.cyan
        case "desktop":    return JcTheme.accent
        case "history":    return JcTheme.muted
        default:           return JcTheme.primaryBlueHi
        }
    }

    /// The lifecycle pill colour in the session header.
    static func statusColor(_ status: String) -> Color {
        switch status {
        case "running":            return JcTheme.success
        case "starting", "idle":   return JcTheme.primaryBlue
        case "error":              return JcTheme.danger
        default:                   return JcTheme.muted
        }
    }

    /// The chat header's live chip: label + colour + whether it spins.
    static func stateChip(activityState: String?, live: Bool) -> (label: String, color: Color, spinning: Bool) {
        switch activityState {
        case "working": return ("Working", green, true)
        case "waiting": return ("Needs input", purple, false)
        case "idle":    return ("Idle", grey, false)
        default:
            return live ? ("Live", JcTheme.primaryBlueHi, false) : ("Offline", JcTheme.muted, false)
        }
    }

    /// The context gauge ramps blue → amber → red as it nears auto-compact.
    static func contextColor(pct: Int) -> Color {
        if pct >= 92 { return Color(jcHex: 0xF87171) }
        if pct >= 80 { return Color(jcHex: 0xFBBF24) }
        return JcTheme.primaryBlueHi
    }

    // MARK: - Sync

    /// The sync card's status line. Offline overrides everything except an
    /// explicit "disconnected" (which already says the same thing).
    static func syncLabel(_ s: CodingSyncStatus) -> String {
        if !s.deviceOnline && s.status != "disconnected" { return "Device offline" }
        switch s.status {
        case "synced":                 return "Up to date"
        case "syncing":                return "Syncing…"
        case "opening", "connecting":  return "Connecting…"
        case "conflicts":
            return s.conflicts > 1
                ? "\(s.conflicts) conflicts (auto-resolving…)"
                : "\(s.conflicts) conflict (auto-resolving…)"
        case "idle":                   return s.deviceOnline ? "Idle" : "Waiting for device"
        case "disconnected":           return "Device offline"
        case "error":                  return "Error"
        default:                       return s.status
        }
    }

    /// The line under the progress bar while a sync pass runs, or nil when it
    /// isn't syncing.
    static func syncProgressLabel(_ s: CodingSyncStatus) -> String? {
        guard s.isSyncing else { return nil }
        guard s.total > 0 else { return "Syncing…" }
        return "\(s.done)/\(s.total) files · \(s.pct)%"
    }

    // MARK: - Devices

    /// Whether a sync-capable desktop is reachable, for the fleet header's
    /// indicator. Nil when no desktop has ever been paired (nothing to say).
    static func desktopIndicator(_ devices: [CodingDevice]) -> (label: String, online: Bool)? {
        guard !devices.isEmpty else { return nil }
        if let up = devices.first(where: { $0.online }) { return (up.name, true) }
        return (devices[0].name, false)
    }

    /// Options for the sync "Device" select. Mirrors the Flutter dropdown: a
    /// leading empty option, every known device (offline ones labelled), and a
    /// synthetic entry preserving a saved value whose device isn't listed now.
    static func deviceOptions(_ devices: [CodingDevice], selected: String) -> [PickerOption<String>] {
        var out: [PickerOption<String>] = [PickerOption("", "— choose a device —")]
        for d in devices {
            out.append(PickerOption(d.id, d.online ? d.name : "\(d.name) (offline)",
                                    symbol: d.online ? "desktopcomputer" : "desktopcomputer.trianglebadge.exclamationmark"))
        }
        let sel = selected.trimmingCharacters(in: .whitespaces)
        // Settings may have stored an id OR a name, so match on both.
        let known = devices.contains { $0.id == sel || $0.name == sel }
        if !sel.isEmpty && !known {
            out.append(PickerOption(sel, "\(sel) (not connected)", symbol: "questionmark.circle"))
        }
        return out
    }

    /// Options for the launch sheet's "Project" select: an explicit "no project"
    /// row first, then every registered project (subtitled with its repo path).
    static func projectOptions(_ projects: [CodingProject]) -> [PickerOption<String>] {
        [PickerOption("", "No project (ungrouped)", symbol: "tray")]
            + projects.map {
                PickerOption($0.id, $0.name.isEmpty ? $0.id : $0.name,
                             subtitle: $0.repoPath, symbol: "folder")
            }
    }

    // MARK: - Approvals

    /// The monospace line inside an approval card — the summary, or the bare
    /// tool name when the server didn't summarise it.
    static func approvalSummary(_ p: PendingPermission) -> String {
        p.summary.isEmpty ? p.tool : p.summary
    }

    /// The card's trailing meta: the project, plus "+N" when more are queued.
    static func approvalMeta(_ p: PendingPermission, extra: Int) -> String {
        extra > 0 ? "\(p.projectLabel) · +\(extra)" : p.projectLabel
    }

    // MARK: - Usage

    /// A quota ring's label, or nil when the server couldn't compute it (-1).
    static func usageLabel(pct: Int, resets: String) -> String? {
        guard pct >= 0 else { return nil }
        let r = resets.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.isEmpty ? "\(pct)%" : "\(pct)% · resets \(r)"
    }

    /// Quota rings go amber then red as the window fills.
    static func usageColor(pct: Int) -> Color {
        if pct >= 90 { return JcTheme.danger }
        if pct >= 75 { return JcTheme.amber }
        return JcTheme.primaryBlueHi
    }

    // MARK: - Time

    /// "now" / "5m" / "3h" / "2d" / "Mar 4" for a session's recency, or "" when
    /// the server never reported one.
    static func relativeTime(_ ts: Double, now: Date) -> String {
        guard ts > 0 else { return "" }
        let delta = now.timeIntervalSince1970 - ts
        // A clock skew (the server ahead of the phone) must read as "now", not
        // as a huge negative age.
        if delta < 45 { return "now" }
        if delta < 3600 { return "\(Int(delta / 60))m" }
        if delta < 86_400 { return "\(Int(delta / 3600))h" }
        if delta < 7 * 86_400 { return "\(Int(delta / 86_400))d" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d"
        return f.string(from: Date(timeIntervalSince1970: ts))
    }

    /// A message's timestamp: "HH:mm" today, "MM/dd HH:mm" otherwise. Nil when
    /// the transcript carried no usable time.
    static func messageTime(_ ts: Double?, now: Date, calendar: Calendar = .current) -> String? {
        guard let ts, ts > 0 else { return nil }
        let date = Date(timeIntervalSince1970: ts)
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let sameDay = calendar.isDate(date, inSameDayAs: now)
        func two(_ v: Int?) -> String { String(format: "%02d", v ?? 0) }
        let time = "\(two(c.hour)):\(two(c.minute))"
        return sameDay ? time : "\(two(c.month))/\(two(c.day)) \(time)"
    }

    /// Whitespace-trimmed. The server treats an empty string as "set it to
    /// empty", which is never what a blank optional form field means — every
    /// sheet trims through here before deciding whether to send a key at all.
    static func trim(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Terminal geometry

    /// How many rows/cols of `cell` fit in `size`, clamped to values a PTY will
    /// accept. A zero-sized SwiftUI layout pass (which happens on the first
    /// frame) falls back to the classic 24×80 rather than resizing the tmux to
    /// nothing.
    static func terminalViewport(size: CGSize, cell: CGSize) -> (rows: Int, cols: Int) {
        guard size.width > 0, size.height > 0, cell.width > 0, cell.height > 0 else {
            return (24, 80)
        }
        let cols = min(400, max(20, Int(size.width / cell.width)))
        let rows = min(200, max(4, Int(size.height / cell.height)))
        return (rows, cols)
    }
}

// MARK: - Projects → Sessions grouping

/// One group in the fleet tree: a real project, or the synthetic "Ungrouped"
/// bucket (`project == nil`), with its sessions already sorted newest-first.
struct CodingSessionGroup: Identifiable, Equatable {
    let key: String
    let name: String
    let subtitle: String?
    let project: CodingProject?
    let sessions: [CodingSession]

    var id: String { key }
    /// Ungrouped has no project to launch into or configure.
    var hasProjectActions: Bool { project != nil }
}

extension CodingUI {
    /// Build the tree the fleet renders: every project (even an empty one, so
    /// its "+" is reachable) followed by Ungrouped when it has anything.
    ///
    /// Older backends return no projects at all; the flat `sessions` list is
    /// then folded into Ungrouped so nothing is hidden.
    ///
    /// `@MainActor` only because it sorts with `CodingStore.byRecency`, which is
    /// isolated to the store's actor — every caller (views, tests) already is.
    @MainActor
    static func groups(projects: [CodingProject],
                       ungrouped: [CodingSession],
                       sessions: [CodingSession]) -> [CodingSessionGroup] {
        var out: [CodingSessionGroup] = projects.map { p in
            CodingSessionGroup(
                key: p.id,
                name: p.name.isEmpty ? (p.repoPath ?? "project \(p.id)") : p.name,
                subtitle: p.repoPath,
                project: p,
                sessions: p.sessions.sorted(by: CodingStore.byRecency))
        }
        var loose = ungrouped
        if projects.isEmpty && ungrouped.isEmpty && !sessions.isEmpty { loose = sessions }
        if !loose.isEmpty {
            out.append(CodingSessionGroup(
                key: CodingStore.ungroupedKey,
                name: "Ungrouped",
                subtitle: nil,
                project: nil,
                sessions: loose.sorted(by: CodingStore.byRecency)))
        }
        return out
    }
}

import Foundation

/// Data models for the Coding tab.
///
/// Port of `coding/coding_models.dart`. These mirror the server's
/// `coding_sessions` control plane (`agent/coding_session_db.py`): a session is a
/// tmux-backed Claude Code run on the server or a paired desktop, optionally
/// file-synced with another device.
///
/// Everything decodes from `[String: Any]` rather than `Codable` on purpose —
/// the payloads come out of SQLite, so booleans arrive as `0/1`, numbers arrive
/// as strings, and absent keys mean "use the default". The Dart parser's exact
/// tolerances are load-bearing, so they're reproduced in `CodingJSON` and
/// exercised directly by `CodingModelsTests`.

// MARK: - Permission requests

/// A remote tool-permission request awaiting the user's verdict (from the
/// PreToolUse relay). Shown as an approval card; answered allow/deny/reply.
struct PendingPermission: Identifiable, Equatable {
    let requestId: String
    let tool: String
    /// One line, e.g. "Bash: rm -rf build/".
    let summary: String
    let sessionId: String
    let cwd: String

    var id: String { requestId }

    init(requestId: String, tool: String, summary: String, sessionId: String = "", cwd: String = "") {
        self.requestId = requestId
        self.tool = tool
        self.summary = summary
        self.sessionId = sessionId
        self.cwd = cwd
    }

    var projectLabel: String {
        let base = CodingJSON.basename(cwd)
        return base.isEmpty ? "session" : base
    }

    /// Nil when the payload isn't an object or carries no `request_id` — the
    /// pending list is skipped over such rows rather than showing a dead card.
    static func from(_ o: Any?) -> PendingPermission? {
        guard let j = o as? [String: Any] else { return nil }
        let rid = CodingJSON.text(j["request_id"])
        guard !rid.isEmpty else { return nil }
        return PendingPermission(
            requestId: rid,
            tool: CodingJSON.text(j["tool"], "tool"),
            summary: CodingJSON.text(j["summary"]),
            sessionId: CodingJSON.text(j["session_id"]),
            cwd: CodingJSON.text(j["cwd"]))
    }
}

// MARK: - Composer attachments

/// A composer attachment the user picked but hasn't sent yet. On send it's
/// uploaded to the session's host and referenced in the message as `@path`.
struct PendingAttachment: Identifiable, Equatable {
    let id: UUID
    let name: String
    let data: Data
    let isImage: Bool

    init(id: UUID = UUID(), name: String, data: Data, isImage: Bool? = nil) {
        self.id = id
        self.name = name
        self.data = data
        self.isImage = isImage ?? Self.looksImage(name)
    }

    var size: Int { data.count }

    static func looksImage(_ name: String) -> Bool {
        let n = name.lowercased()
        return [".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic"].contains { n.hasSuffix($0) }
    }
}

// MARK: - Sync config

/// Cross-device file sync config for a session (`sync: {enabled, device, remote_path}`).
struct CodingSync: Equatable {
    var enabled: Bool
    var device: String?
    var remotePath: String?

    init(enabled: Bool = false, device: String? = nil, remotePath: String? = nil) {
        self.enabled = enabled
        self.device = device
        self.remotePath = remotePath
    }

    /// Nil when `sync` is absent or not an object.
    static func from(_ v: Any?) -> CodingSync? {
        guard let m = v as? [String: Any] else { return nil }
        return CodingSync(enabled: CodingJSON.bool(m["enabled"]),
                          device: CodingJSON.str(m["device"]),
                          remotePath: CodingJSON.str(m["remote_path"]))
    }

    var json: [String: Any] {
        var out: [String: Any] = ["enabled": enabled]
        if let device, !device.isEmpty { out["device"] = device }
        if let remotePath, !remotePath.isEmpty { out["remote_path"] = remotePath }
        return out
    }
}

// MARK: - Sessions

/// The host/source badge shown on a session row.
struct SessionBadge: Equatable {
    let kind: String
    let label: String
}

/// A coding session row (`GET /api/coding/sessions`, `/api/coding/session/{id}`).
struct CodingSession: Identifiable, Equatable {
    let id: String
    var title: String?
    /// starting | running | idle | stopped | error
    var status: String
    /// server | desktop
    var host: String?
    var cwd: String?
    var branch: String?
    var claudeSessionId: String?
    /// chat | manual | discovered-tmux | discovered-transcript
    var source: String?
    var model: String?
    var skipPermissions: Bool
    var sync: CodingSync?
    /// Epoch seconds (SQLite REAL).
    var createdAt: Double?

    // ── Projects / discovery ──

    /// The owning project's id (nil ⇒ Ungrouped).
    var projectId: String?
    /// True for device-discovered sessions (a live tmux or a past transcript
    /// surfaced from a paired desktop). Drives the "discovered/live" badge.
    var external: Bool
    /// The device that owns a discovered session (used by resume, informational).
    var deviceId: String?
    /// The tmux session name backing a live session (informational).
    var tmuxName: String?
    /// Last activity timestamp — preferred sort key over `createdAt`. May be an
    /// epoch number or an ISO string; kept as a string for robust comparison.
    var lastActivityAt: String?
    /// Live activity sub-state of a running session: working | waiting | idle.
    /// Nil = unknown / not running.
    var activityState: String?
    /// Whether a tmux client is attached to a discovered session. Defaults to
    /// true (the server stores 1/NULL = attached; only an explicit 0 = detached)
    /// so we never wrongly dim. Drives `isDim`.
    var attached: Bool

    init(id: String, title: String? = nil, status: String = "starting", host: String? = nil,
         cwd: String? = nil, branch: String? = nil, claudeSessionId: String? = nil,
         source: String? = nil, model: String? = nil, skipPermissions: Bool = false,
         sync: CodingSync? = nil, createdAt: Double? = nil, projectId: String? = nil,
         external: Bool = false, deviceId: String? = nil, tmuxName: String? = nil,
         lastActivityAt: String? = nil, activityState: String? = nil, attached: Bool = true) {
        self.id = id
        self.title = title
        self.status = status
        self.host = host
        self.cwd = cwd
        self.branch = branch
        self.claudeSessionId = claudeSessionId
        self.source = source
        self.model = model
        self.skipPermissions = skipPermissions
        self.sync = sync
        self.createdAt = createdAt
        self.projectId = projectId
        self.external = external
        self.deviceId = deviceId
        self.tmuxName = tmuxName
        self.lastActivityAt = lastActivityAt
        self.activityState = activityState
        self.attached = attached
    }

    init(json j: [String: Any]) {
        self.init(
            id: CodingJSON.text(j["id"]),
            title: CodingJSON.str(j["title"]),
            status: CodingJSON.text(j["status"], "starting"),
            host: CodingJSON.str(j["host"]),
            cwd: CodingJSON.str(j["cwd"]),
            branch: CodingJSON.str(j["branch"]),
            claudeSessionId: CodingJSON.str(j["claude_session_id"]),
            source: CodingJSON.str(j["source"]),
            model: CodingJSON.str(j["model"]),
            skipPermissions: CodingJSON.bool(j["skip_permissions"]),
            sync: CodingSync.from(j["sync"]),
            createdAt: CodingJSON.double(j["created_at"]),
            projectId: CodingJSON.str(j["project_id"]),
            external: CodingJSON.bool(j["external"]),
            deviceId: CodingJSON.str(j["device_id"]),
            tmuxName: CodingJSON.str(j["tmux_name"]),
            lastActivityAt: CodingJSON.str(j["last_activity_at"]),
            activityState: CodingJSON.str(j["activity_state"]),
            attached: CodingJSON.bool(j["attached"], or: true))
    }

    var displayTitle: String {
        let t = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        let dir = (cwd ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !dir.isEmpty { return String(dir.split(separator: "/").last ?? "") }
        return "Session \(id.isEmpty ? "" : String(id.prefix(8)))"
    }

    var isLive: Bool { status == "running" || status == "starting" || status == "idle" }

    /// Normalised status bucket, mirroring the WebUI's `_cdgStatusClass`:
    /// running | done | error | stopped | idle.
    var statusClass: String {
        switch status.lowercased() {
        case "running", "active", "busy": return "running"
        case "done", "completed", "finished": return "done"
        case "error", "failed": return "error"
        case "stopped", "cancelled", "canceled": return "stopped"
        default: return "idle"
        }
    }

    /// Display state for the dot/label: a live session refines into
    /// working | waiting | idle via `activityState`; other lifecycle states pass
    /// through. Mirrors the WebUI's `_cdgDisplayState`.
    var liveState: String {
        if isTranscriptIdle { return "history" }
        // The server detects activity_state for any LIVE session (running,
        // starting or idle lifecycle), so refine all of them — otherwise a
        // session whose lifecycle is idle/starting but whose pane is a permission
        // prompt would show grey instead of the purple "waiting" signal.
        if isLive {
            switch (activityState ?? "").lowercased() {
            case "waiting": return "waiting"
            case "working": return "working"
            case "idle": return "idle"
            default:
                // No detected sub-state yet: a running session is presumably
                // working; a starting/idle lifecycle with no pane reading stays idle.
                return statusClass == "running" ? "working" : "idle"
            }
        }
        return statusClass
    }

    /// A FORGOTTEN session: a discovered tmux with NO client attached, sitting
    /// idle. De-emphasized (dimmed + sorted last) in the fleet — not hidden.
    /// Mirrors the server's `_is_dim` in `agent/coding_la_push.py`.
    var isDim: Bool {
        (source ?? "").hasPrefix("discovered-tmux") && !attached && liveState == "idle"
    }

    /// Per-session fleet state: `dim` for a forgotten detached+idle session, else
    /// `liveState`.
    var fleetState: String { isDim ? "dim" : liveState }

    /// A transcript-only (`discovered-transcript`) session that isn't currently
    /// running — a PAST conversation with no live tmux. It can be **resumed** on
    /// its device. Mirrors the WebUI's `_codingIsTranscriptIdle`.
    var isTranscriptIdle: Bool {
        source == "discovered-transcript" && statusClass != "running"
    }

    /// A live (tmux) session that ENDED — claude quit / its tmux is gone, so the
    /// server reconciled it to stopped (a discovered Mac session) or
    /// stopped/error (a server-launched session whose tmux died). It has no live
    /// terminal to attach; offer the recovery actions instead. Mirrors
    /// `_codingIsEnded`.
    var isEnded: Bool {
        let src = source ?? ""
        if src == "discovered-transcript" { return false } // that's transcript-idle
        let cls = statusClass
        if src.hasPrefix("discovered") && cls == "stopped" { return true }
        let h = (host ?? "").isEmpty ? "server" : host!
        return h == "server" && (cls == "stopped" || cls == "error")
    }

    /// Epoch SECONDS used to sort sessions newest-first. Prefers
    /// `last_activity_at`, falls back to `created_at`. Handles numeric epochs
    /// (seconds OR milliseconds) and ISO strings; 0 when unknown. (A plain string
    /// compare mis-ordered these.)
    var recencyTs: Double {
        var raw = lastActivityAt ?? ""
        if raw.isEmpty { raw = createdAt.map { CodingJSON.stringify(NSNumber(value: $0)) } ?? "" }
        if raw.isEmpty { return 0 }
        if let n = Double(raw) { return n > 1e12 ? n / 1000 : n } // normalise ms → s
        return CodingJSON.date(raw)?.timeIntervalSince1970 ?? 0
    }

    /// Resolve the host/source badge shown on the session row. Priority:
    /// history (idle transcript) > discovered/live (external) > desktop > server.
    var badge: SessionBadge {
        if isTranscriptIdle { return SessionBadge(kind: "history", label: "history") }
        if external {
            let live = source == "discovered-transcript" && statusClass == "running"
            return SessionBadge(kind: "discovered", label: live ? "live" : "discovered")
        }
        if (host ?? "").lowercased() == "desktop" {
            return SessionBadge(kind: "desktop", label: "desktop")
        }
        return SessionBadge(kind: "server", label: "server")
    }
}

/// The `/api/coding/session/{id}` payload — we only consume `session` (the
/// `subagents` UI was dropped to match the web).
struct CodingSessionDetail: Equatable {
    let session: CodingSession

    init(session: CodingSession) { self.session = session }

    /// Tolerates a bare session object (no `session` wrapper).
    init(json j: [String: Any]) {
        session = CodingSession(json: (j["session"] as? [String: Any]) ?? j)
    }
}

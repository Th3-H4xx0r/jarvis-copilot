import Foundation

/// Projects, paired devices, sync status and account usage — the rest of
/// `coding/coding_models.dart`. Split out of `CodingModels.swift` (sessions) to
/// keep both files readable.

// MARK: - Projects

/// A registered coding project with its nested sessions
/// (`GET /api/coding/projects?expand=sessions`).
struct CodingProject: Identifiable, Equatable {
    let id: String
    var name: String
    var repoPath: String?
    var host: String?
    var deviceId: String?
    var syncEnabled: Bool
    var syncDesktopPath: String?
    var ignoreRules: String?
    var defaultBranch: String?
    var sessions: [CodingSession]

    init(id: String, name: String, repoPath: String? = nil, host: String? = nil,
         deviceId: String? = nil, syncEnabled: Bool = false, syncDesktopPath: String? = nil,
         ignoreRules: String? = nil, defaultBranch: String? = nil,
         sessions: [CodingSession] = []) {
        self.id = id
        self.name = name
        self.repoPath = repoPath
        self.host = host
        self.deviceId = deviceId
        self.syncEnabled = syncEnabled
        self.syncDesktopPath = syncDesktopPath
        self.ignoreRules = ignoreRules
        self.defaultBranch = defaultBranch
        self.sessions = sessions
    }

    init(json j: [String: Any]) {
        self.init(
            id: CodingJSON.text(j["id"]),
            name: CodingJSON.text(j["name"]),
            repoPath: CodingJSON.str(j["repo_path"]),
            host: CodingJSON.str(j["host"]),
            deviceId: CodingJSON.str(j["device_id"]),
            syncEnabled: CodingJSON.bool(j["sync_enabled"]),
            syncDesktopPath: CodingJSON.str(j["sync_desktop_path"]),
            ignoreRules: CodingJSON.str(j["ignore_rules"]),
            defaultBranch: CodingJSON.str(j["default_branch"]),
            sessions: CodingJSON.maps(j["sessions"]).map(CodingSession.init(json:)))
    }
}

/// The expanded `/projects?expand=sessions` payload: projects (each with their
/// nested sessions) plus the synthetic Ungrouped bucket of project-less sessions
/// (legacy rows + discovered sessions).
struct CodingProjectsView: Equatable {
    var projects: [CodingProject]
    var ungrouped: [CodingSession]

    init(projects: [CodingProject] = [], ungrouped: [CodingSession] = []) {
        self.projects = projects
        self.ungrouped = ungrouped
    }
}

// MARK: - Devices

/// A paired/registered device (`GET /api/devices`), used to populate the sync
/// "Device" dropdown. Offline devices are still listed but labelled.
struct CodingDevice: Identifiable, Equatable {
    let id: String
    var name: String
    var online: Bool
    /// browser | desktop | mobile-ios | mobile-android
    var kind: String?
    /// True when the device holds a live jc-client desktop agent WS.
    var bridgeConnected: Bool
    /// Server-computed: can run Mutagen sync.
    var syncCapable: Bool?

    init(id: String, name: String, online: Bool = true, kind: String? = nil,
         bridgeConnected: Bool = false, syncCapable: Bool? = nil) {
        self.id = id
        self.name = name
        self.online = online
        self.kind = kind
        self.bridgeConnected = bridgeConnected
        self.syncCapable = syncCapable
    }

    /// Mobile pairings can NEVER run Mutagen file sync, yet they hold a bridge WS
    /// too (notifications/phone-control). Exclude ONLY these — a desktop
    /// jc-client usually registers with the default kind 'browser', so excluding
    /// 'browser' would drop the real desktop. Actual web browsers never hold a
    /// bridge, so they're filtered by `syncCapable`/`bridgeConnected`, not kind.
    private static let mobileKinds: Set<String> = ["mobile-ios", "mobile-android", "mobile"]

    /// Only desktops that can actually sync. Prefer the server's `syncCapable`
    /// flag; always exclude mobile kinds even if they hold a bridge.
    var desktopCapable: Bool {
        if let kind, Self.mobileKinds.contains(kind) { return false }
        if let syncCapable { return syncCapable }
        return kind == "desktop" || bridgeConnected
    }

    init(json j: [String: Any]) {
        let id = CodingJSON.text(j["id"], CodingJSON.text(j["device_id"]))
        let name = CodingJSON.str(j["name"]) ?? CodingJSON.str(j["device_name"])
            ?? (id.isEmpty ? "device" : id)
        self.init(
            id: id,
            name: name,
            // Default online=true when absent (mirrors the web's `online !== false`).
            online: CodingJSON.bool(j["online"], or: true),
            kind: CodingJSON.str(j["kind"])?.lowercased(),
            bridgeConnected: CodingJSON.bool(j["bridge_connected"]),
            syncCapable: (j["sync_capable"] == nil || j["sync_capable"] is NSNull)
                ? nil : CodingJSON.bool(j["sync_capable"]))
    }
}

// MARK: - Sync status

/// Live cross-device sync status for a session
/// (`GET /api/coding/session/{id}/sync`).
struct CodingSyncStatus: Equatable {
    /// off | disconnected | idle | opening | syncing | synced | error
    var status: String
    var enabled: Bool
    var device: String?
    var deviceOnline: Bool
    var total: Int
    var done: Int
    var conflicts: Int
    /// Conflicts the client auto-resolved (newest-edit-wins, loser backed up).
    var healed: Int
    /// Epoch seconds.
    var lastSyncAt: Double?
    var error: String?

    init(enabled: Bool = false, device: String? = nil, deviceOnline: Bool = false,
         status: String = "off", total: Int = 0, done: Int = 0, conflicts: Int = 0,
         healed: Int = 0, lastSyncAt: Double? = nil, error: String? = nil) {
        self.enabled = enabled
        self.device = device
        self.deviceOnline = deviceOnline
        self.status = status
        self.total = total
        self.done = done
        self.conflicts = conflicts
        self.healed = healed
        self.lastSyncAt = lastSyncAt
        self.error = error
    }

    init(json j: [String: Any]) {
        self.init(
            enabled: CodingJSON.bool(j["enabled"]),
            device: CodingJSON.str(j["device"]),
            deviceOnline: CodingJSON.bool(j["device_online"]),
            status: CodingJSON.text(j["status"], "off"),
            total: CodingJSON.int(j["total"]),
            done: CodingJSON.int(j["done"]),
            conflicts: CodingJSON.int(j["conflicts"]),
            healed: CodingJSON.int(j["healed"]),
            lastSyncAt: CodingJSON.double(j["last_sync_at"]),
            error: CodingJSON.str(j["error"]))
    }

    var isSyncing: Bool { status == "syncing" || status == "opening" || status == "connecting" }

    /// Percent complete from Mutagen's staging progress (done/total files).
    var pct: Int {
        if isSyncing && total > 0 { return Int(((Double(done) / Double(total)) * 100).rounded()) }
        return status == "synced" ? 100 : 0
    }
}

// MARK: - Account usage

/// The account-quota block the server nests in `/api/coding/sessions` and
/// returns from `/api/coding/usage`. `-1` means "unknown" (the Live Activity
/// coordinator's sentinel) so a missing percentage doesn't render as 0%.
struct CodingUsage: Equatable {
    var fiveHourPct: Int
    var weeklyPct: Int
    var fiveHourResets: String
    var weeklyResets: String

    init(fiveHourPct: Int = -1, weeklyPct: Int = -1,
         fiveHourResets: String = "", weeklyResets: String = "") {
        self.fiveHourPct = fiveHourPct
        self.weeklyPct = weeklyPct
        self.fiveHourResets = fiveHourResets
        self.weeklyResets = weeklyResets
    }

    /// Nil when the server couldn't compute usage (`usage: null`).
    static func from(_ o: Any?) -> CodingUsage? {
        guard let j = o as? [String: Any] else { return nil }
        return CodingUsage(
            fiveHourPct: CodingJSON.int(j["five_hour_pct"], or: -1),
            weeklyPct: CodingJSON.int(j["weekly_pct"], or: -1),
            fiveHourResets: CodingJSON.text(j["five_hour_resets"]),
            weeklyResets: CodingJSON.text(j["weekly_resets"]))
    }
}

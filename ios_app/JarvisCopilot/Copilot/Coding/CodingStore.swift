import Foundation
import Observation

/// Drives the Coding tab: the Projects→Sessions tree, the selected session's
/// detail + sync status, the launch/stop/restart/delete/settings actions, the
/// remote permission-approval queue, and the paired-device list.
///
/// Port of `coding/coding_controller.dart`. The per-session chat/terminal work
/// lives in `CodingSessionStore`, which this store vends and caches so a
/// terminal survives a chat↔terminal mode toggle (Flutter had one controller for
/// both, and the attach guard was keyed on the selected id).
///
/// Both poll loops do network work only while `isVisible()` says so — inject
/// `{ tab == .coding && scenePhase == .active }`, which is the Flutter build's
/// `activeTabIndex` + `AppLifecycle.isForeground` gate.
@Observable @MainActor
final class CodingStore {

    // MARK: - Dependencies

    let api: CodingSessionsAPI
    private let isVisible: () -> Bool
    private let now: () -> Date

    init(api: CodingSessionsAPI = CodingSessionsAPI(),
         attachments: CodingAttachments? = nil,
         isVisible: @escaping () -> Bool = { true },
         now: @escaping () -> Date = Date.init,
         detailPollEvery: TimeInterval = CodingStore.detailPollInterval,
         listPollEvery: TimeInterval = CodingStore.listPollInterval) {
        self.api = api
        self.isVisible = isVisible
        self.now = now
        self.detailPollEvery = detailPollEvery
        self.listPollEvery = listPollEvery
        self.attachments = attachments ?? CodingAttachments(api: api)
    }

    deinit {
        detailPollHandle.cancel()
        listPollHandle.cancel()
        rediscoverHandle.cancel()
    }

    static let detailPollInterval: TimeInterval = 4
    static let listPollInterval: TimeInterval = 5
    /// Injectable so the poll-loop tests don't have to sleep for real seconds.
    private let detailPollEvery: TimeInterval
    private let listPollEvery: TimeInterval

    /// How many consecutive "transient" failures before a poll-driven blip stops
    /// being treated as a blip and gets a banner.
    static let transientFailureLimit = 3

    // MARK: - Projects → Sessions tree

    /// Registered projects, each carrying their nested sessions.
    var projects: [CodingProject] = []
    /// Project-less sessions (the synthetic "Ungrouped" bucket): legacy rows +
    /// device-discovered sessions.
    var ungrouped: [CodingSession] = []
    /// Flat list derived from `projects` + `ungrouped`, newest first.
    var sessions: [CodingSession] = []

    var loading = false
    var error: String?

    /// Project ids (and `ungroupedKey`) the user has collapsed in the tree.
    /// UI-only; lives as long as the store.
    var collapsed: Set<String> = []
    /// Sentinel key for the synthetic Ungrouped group.
    static let ungroupedKey = "__ungrouped__"

    /// Project create/update/delete/discover in flight.
    var busyProjects = false

    /// Paired/registered devices for the sync "Device" dropdown, populated
    /// best-effort from `/api/devices`. Empty on error; never throws.
    var devices: [CodingDevice] = []

    // MARK: - Selection

    var selectedId: String?
    var selected: CodingSession?
    var detailLoading = false
    /// Live cross-device sync status for the selected session, polled alongside
    /// the detail refresh. Nil until the first poll returns (or when the endpoint
    /// isn't available). Render the Sync card only when `sync.enabled`.
    var sync: CodingSyncStatus?

    var hasSelection: Bool { !(selectedId ?? "").isEmpty }

    // MARK: - Action state

    var launching = false
    var sending = false
    /// stop/restart/delete/resume in flight.
    var busy = false

    // MARK: - Composer attachments

    let attachments: CodingAttachments

    // MARK: - Per-session stores

    /// Not `private`: `CodingStoreActions.swift` tears a session's terminal down
    /// on delete/restart.
    var sessionStores: [String: CodingSessionStore] = [:]

    /// Least-recently-used first. Each cached store holds a transcript, a 2000
    /// line terminal buffer and its poll loop, so the map can't grow with every
    /// session the user glances at.
    private var storeOrder: [String] = []
    static let maxCachedSessionStores = 3

    /// The chat/terminal store for one session, created on demand and cached so
    /// its live terminal isn't torn down when the view is rebuilt.
    func sessionStore(_ id: String) -> CodingSessionStore {
        touchSessionStore(id)
        if let existing = sessionStores[id] { return existing }
        let store = CodingSessionStore(sessionId: id, api: api,
                                       attachments: attachments,
                                       isVisible: isVisible, now: now)
        sessionStores[id] = store
        evictStaleSessionStores()
        return store
    }

    private func touchSessionStore(_ id: String) {
        storeOrder.removeAll { $0 == id }
        storeOrder.append(id)
    }

    private func evictStaleSessionStores() {
        while storeOrder.count > Self.maxCachedSessionStores {
            // The open session is never the victim, however long ago it was last
            // resolved from the map.
            guard let victim = storeOrder.first(where: { $0 != selectedId }) else { return }
            storeOrder.removeAll { $0 == victim }
            releaseSessionStore(victim)
        }
    }

    /// Stop the polls and hand the single-viewer PTY back, then drop the store.
    /// Not `private`: `delete()` in `CodingStoreActions.swift` calls it.
    func releaseSessionStore(_ id: String) {
        storeOrder.removeAll { $0 == id }
        guard let store = sessionStores.removeValue(forKey: id) else { return }
        store.stop()
        store.detachTerminal()
    }

    // MARK: - Sessions list

    /// Load the Projects→Sessions tree (`/projects?expand=sessions`) and derive
    /// the flat `sessions` list. Falls back to the flat `/sessions` endpoint when
    /// the projects payload is empty (older backends) so the page never breaks.
    func loadSessions() async {
        loading = true
        error = nil
        do {
            let view = try await api.listProjectsExpanded()
            projects = view.projects
            ungrouped = view.ungrouped
            var flat = Self.flatten(view)
            if flat.isEmpty {
                // Older backend without the projects payload — flat list instead.
                // A failure here leaves the (empty) projects view, which still renders.
                do {
                    let list = try await api.listSessions()
                    ungrouped = list
                    flat = list
                } catch {
                    JcLog.dropped(JcLog.coding, "flat sessions fallback", error)
                }
            }
            adopt(flat)
        } catch {
            self.error = "Could not load coding sessions: \(apiErrorMessage(error))"
        }
        loading = false
    }

    /// Quiet refresh (no spinner) used by the list poll so the status dots stay
    /// live without a pull-to-refresh. Transient failures keep the current data.
    func refreshSessionsQuiet() async {
        let view: CodingProjectsView
        do {
            view = try await api.listProjectsExpanded()
        } catch {
            JcLog.dropped(JcLog.coding, "quiet sessions refresh", error)
            return
        }
        let flat = Self.flatten(view)
        // Don't wipe a good list on an empty/old payload.
        guard !flat.isEmpty else { return }
        projects = view.projects
        ungrouped = view.ungrouped
        adopt(flat)
    }

    private func adopt(_ flat: [CodingSession]) {
        sessions = flat.sorted(by: Self.byRecency)
        // If the selected session vanished from the list, clear it.
        if let id = selectedId, !sessions.contains(where: { $0.id == id }) { clearSelection() }
    }

    static func flatten(_ view: CodingProjectsView) -> [CodingSession] {
        view.projects.flatMap(\.sessions) + view.ungrouped
    }

    /// Newest-first by numeric recency (epoch seconds; a string compare
    /// mis-ordered these). Prefers `last_activity_at`, falls back to `created_at`.
    static func byRecency(_ a: CodingSession, _ b: CodingSession) -> Bool {
        a.recencyTs > b.recencyTs
    }

    /// Toggle a project group's collapsed state in the tree (UI-only).
    func toggleCollapsed(_ key: String) {
        if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
    }

    func isCollapsed(_ key: String) -> Bool { collapsed.contains(key) }

    /// Best-effort refresh of the paired-devices list for the sync dropdown.
    /// Never throws — on any error the list is emptied (the Device dropdown then
    /// reads "no devices", which is the same thing to the user) but the reason is
    /// logged rather than dropped on the floor.
    func loadDevices() async {
        do {
            devices = try await api.listDevices()
        } catch {
            JcLog.dropped(JcLog.coding, "device list", error)
            devices = []
        }
    }

    // MARK: - Select / inspect

    func select(_ id: String) async {
        if selectedId != id {
            // Single-viewer terminals: hand the PTY back before moving on.
            if let previous = selectedId { sessionStores[previous]?.detachTerminal() }
            sync = nil // drop the previous session's status until the poll lands
        }
        selectedId = id
        selected = sessions.first { $0.id == id }
        touchSessionStore(id)
        detailLoading = true
        detailFailures = 0
        error = nil
        await refreshDetail()
        startDetailPolling()
    }

    func deselect() {
        // Leaving the session releases everything it holds: the poll loop, the
        // single-viewer PTY, the transcript and the terminal buffer.
        if let id = selectedId { releaseSessionStore(id) }
        clearSelection()
    }

    /// Not `private`: `delete()` in `CodingStoreActions.swift` calls it.
    func clearSelection() {
        stopDetailPolling()
        selectedId = nil
        selected = nil
        sync = nil
        detailLoading = false
        detailFailures = 0
    }

    /// Consecutive transient detail-poll failures. A blip is a blip; a run of
    /// them is the server being down, and pretending otherwise leaves the user
    /// staring at a session detail that stopped being true minutes ago.
    private var detailFailures = 0

    func refreshDetail() async {
        guard let id = selectedId else { return }
        defer { if selectedId == id { detailLoading = false } }
        do {
            let detail = try await api.get(id)
            // Guard against a late response after the user switched/cleared.
            guard selectedId == id else { return }
            selected = detail.session
            detailFailures = 0
            error = nil
        } catch {
            guard selectedId == id else { return }
            detailFailures += 1
            let message = JcLog.report(JcLog.coding, "session detail", error)
            // This runs on EVERY poll tick, so a single transient blip (a 5xx from
            // the edge when the webui is momentarily busy, or a dropped
            // connection) must NOT flash a scary banner while we already have the
            // session loaded — keep showing the cached detail; the next tick
            // recovers. Only surface an error when there's nothing to show yet,
            // it's real (e.g. a 404 for a deleted session), or the "transient"
            // failure has now repeated `transientFailureLimit` times.
            if selected != nil, Self.isTransient(error),
               detailFailures < Self.transientFailureLimit { return }
            self.error = "Could not load session: \(message)"
        }
    }

    /// Poll the live sync status for the selected session. Best-effort: a missing
    /// endpoint / transient error leaves the last value in place.
    func refreshSyncStatus() async {
        guard let id = selectedId else { return }
        // Endpoint unavailable / transient — keep the last known status.
        let next: CodingSyncStatus
        do {
            next = try await api.syncStatus(id)
        } catch {
            JcLog.dropped(JcLog.coding, "sync status", error)
            return
        }
        guard selectedId == id else { return }
        // Only adopt a MEANINGFUL change: `last_sync_at`/`healed` tick every poll
        // and re-rendering the sync card for them was pure churn (Flutter skipped
        // `notifyListeners` for exactly this reason).
        if Self.syncChanged(sync, next) { sync = next }
    }

    static func syncChanged(_ prev: CodingSyncStatus?, _ next: CodingSyncStatus) -> Bool {
        guard let prev else { return true }
        return prev.enabled != next.enabled
            || prev.deviceOnline != next.deviceOnline
            || prev.status != next.status
            || prev.total != next.total
            || prev.done != next.done
            || prev.device != next.device
            || prev.error != next.error
    }

    /// Kick a fresh sync pass for the selected session, then re-poll the status.
    /// "Sync now" is a button the user pressed: a rejected kick has to say so,
    /// otherwise the card just sits there looking like nothing happened.
    func refreshSync() async {
        guard let id = selectedId else { return }
        do {
            try await api.refreshSync(id)
        } catch {
            self.error = "Sync refresh failed: \(JcLog.report(JcLog.coding, "sync refresh", error))"
        }
        await refreshSyncStatus()
    }

    // MARK: - Polling

    // Every long-lived task lives in a `TaskHandle` (`Copilot/More/MoreSupport.swift`)
    // rather than a `nonisolated(unsafe) var`: the box is `Sendable`, so the
    // nonisolated `deinit` can cancel from anywhere.
    @ObservationIgnored private let detailPollHandle = TaskHandle()
    @ObservationIgnored private let listPollHandle = TaskHandle()
    // Not `private` because `discoverRefresh()` lives in `CodingStoreActions.swift`.
    @ObservationIgnored let rediscoverHandle = TaskHandle()

    /// The live list-poll task, or nil when disarmed. Internal so the tests can
    /// prove the loop is armed exactly once and really cancelled.
    var listPollTask: Task<Void, Never>? { listPollHandle.current }

    private func startDetailPolling() {
        detailPollHandle.replace(Task { [weak self] in
            // Kick the sync poll immediately so the Sync card appears without a
            // 4s wait — inside the tracked task, so `stopDetailPolling` cancels
            // the kick as well as the loop.
            await self?.refreshSyncStatus()
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(nanoseconds: UInt64(self.detailPollEvery * 1_000_000_000))
                // Stop the loop once the store is gone — a `self?` no-op would
                // keep the timer spinning for the life of the process.
                if Task.isCancelled { return }
                await self.detailPollTick()
            }
        })
    }

    private func stopDetailPolling() {
        detailPollHandle.cancel()
    }

    /// One detail-poll tick. Returns false — and does NO network work — while the
    /// tab is hidden or the app is backgrounded. (The Flutter detail poll missed
    /// this gate and kept hitting the network every 4s in the background.)
    @discardableResult
    func detailPollTick() async -> Bool {
        guard isVisible() else { return false }
        await refreshDetail()
        await refreshSyncStatus()
        return true
    }

    /// Start/stop the quiet periodic refresh of the whole sessions list (plus the
    /// approval queue) so the dots stay live while the tab is open.
    func setListPolling(_ on: Bool) {
        guard on else { listPollHandle.cancel(); return }
        // Arm ONCE. The tab's `.onChange(initial:)` fires again on every scene
        // phase flip, and re-creating the task each time both restarts the
        // interval and (with a handle that outlives its task) risks wedging.
        if let running = listPollHandle.current, !running.isCancelled { return }
        listPollHandle.replace(Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(nanoseconds: UInt64(self.listPollEvery * 1_000_000_000))
                if Task.isCancelled { return }
                await self.listPollTick()
            }
        })
    }

    @discardableResult
    func listPollTick() async -> Bool {
        guard isVisible() else { return false }
        await refreshSessionsQuiet()
        await refreshPendingApprovals()
        return true
    }

    // MARK: - Remote permission approvals (PreToolUse relay)

    /// Tool-permission requests awaiting your verdict, polled in the foreground
    /// (the push notification is the fast away-from-app path; this is the in-app
    /// fallback so the card shows even if the push was missed).
    var pendingApprovals: [PendingPermission] = []

    /// Optimistically-answered request ids — filtered out of poll results until
    /// the server stops listing them, so a just-answered card never flickers back
    /// from a poll that was in flight when the verdict was sent.
    private var answeredPermissions: Set<String> = []

    /// Consecutive approval-poll failures. This queue is the in-app fallback for
    /// a missed push, so a poll that has been failing for a while means tool
    /// permissions are silently stuck waiting on the Mac — worth saying.
    private var approvalFailures = 0

    func refreshPendingApprovals() async {
        let raw: [PendingPermission]
        do {
            raw = try await api.pendingPermissions()
            approvalFailures = 0
        } catch {
            // Transient — keep the current set, retry next tick.
            approvalFailures += 1
            let message = JcLog.report(JcLog.coding, "pending approvals", error)
            if approvalFailures >= Self.transientFailureLimit {
                self.error = "Approval requests aren’t reaching this device: \(message)"
            }
            return
        }
        // Drop tombstones the server no longer lists (verdict landed / expired).
        let liveIds = Set(raw.map(\.requestId))
        answeredPermissions.formIntersection(liveIds)
        let pend = raw.filter { !answeredPermissions.contains($0.requestId) }
        let changed = pend.count != pendingApprovals.count
            || !pend.allSatisfy { p in pendingApprovals.contains { $0.requestId == p.requestId } }
        if changed { pendingApprovals = pend }
    }

    /// Answer a permission request (allow/deny, optional steering message on a
    /// deny). Optimistically dismisses the card; if the POST fails the card comes
    /// back so the user knows it didn't go through.
    func respondPermission(_ requestId: String, decision: String, message: String? = nil) async {
        answeredPermissions.insert(requestId)
        let removed = pendingApprovals.first { $0.requestId == requestId }
        pendingApprovals.removeAll { $0.requestId == requestId }
        do {
            try await api.submitPermissionVerdict(requestId, decision: decision, message: message)
        } catch {
            answeredPermissions.remove(requestId)
            if let removed, !pendingApprovals.contains(where: { $0.requestId == requestId }) {
                pendingApprovals.insert(removed, at: 0)
            }
            self.error = "Could not send your decision: \(apiErrorMessage(error))"
        }
    }

    // MARK: -

    /// A transient, self-recovering failure (a 5xx from the edge/upstream while
    /// the webui is briefly busy, or a connection/timeout) vs. a real error worth
    /// surfacing (4xx). Keeps poll-driven refreshes from flashing error banners.
    static func isTransient(_ error: Error) -> Bool {
        if let e = error as? APIError {
            switch e {
            case .http(let status, _): return status >= 500
            case .cancelled: return true
            case .badResponse, .notPaired: return false
            }
        }
        // No response at all — connection dropped or timed out.
        return (error as NSError).domain == NSURLErrorDomain
    }
}

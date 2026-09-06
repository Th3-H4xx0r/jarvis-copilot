import XCTest
@testable import JarvisCopilot

@MainActor
final class CodingStoreTests: XCTestCase {

    private func makeStore(visible: @escaping () -> Bool = { true },
                           listPollEvery: TimeInterval = CodingStore.listPollInterval)
        -> (CodingStore, MockTransport) {
        let (client, transport) = JarvisAPI.mocked()
        return (CodingStore(api: CodingSessionsAPI(api: client), isVisible: visible,
                            listPollEvery: listPollEvery), transport)
    }

    /// Spin until `condition` holds (the poll loops live in their own tasks).
    private func codingStoreWaitUntil(_ what: String, timeout: TimeInterval = 3,
                                      file: StaticString = #filePath, line: UInt = #line,
                                      _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
    }

    /// `{projects, ungrouped}` with two project sessions and one loose one.
    private let expandedTree: [String: Any] = [
        "projects": [[
            "id": "p1", "name": "jarvis-copilot", "repo_path": "/home/p/jc",
            "sessions": [
                ["id": "s1", "status": "running", "activity_state": "working",
                 "last_activity_at": 1781006400] as [String: Any],
                ["id": "s2", "status": "idle", "last_activity_at": 1781000000] as [String: Any],
            ],
        ] as [String: Any]],
        "ungrouped": [
            ["id": "s3", "status": "running", "source": "discovered-tmux",
             "external": 1, "last_activity_at": 1781009999] as [String: Any],
        ],
    ]

    // MARK: - Sessions list

    func testLoadSessionsFlattensTheTreeNewestFirst() async {
        let (store, t) = makeStore()
        t.route("/api/coding/projects", json: expandedTree)
        await store.loadSessions()
        XCTAssertEqual(store.sessions.map(\.id), ["s3", "s1", "s2"])
        XCTAssertEqual(store.projects.map(\.id), ["p1"])
        XCTAssertEqual(store.ungrouped.map(\.id), ["s3"])
        XCTAssertFalse(store.loading)
        XCTAssertNil(store.error)
    }

    func testLoadSessionsFallsBackToTheFlatEndpointOnAnOlderBackend() async {
        let (store, t) = makeStore()
        t.route("/api/coding/projects", json: ["projects": [], "ungrouped": []])
        t.route("/api/coding/sessions", json: ["sessions": [["id": "s1", "status": "running"]]])
        await store.loadSessions()
        XCTAssertEqual(store.sessions.map(\.id), ["s1"])
        XCTAssertEqual(store.ungrouped.map(\.id), ["s1"])
        XCTAssertNil(store.error)
    }

    func testLoadSessionsSurfacesAFailure() async {
        let (store, t) = makeStore()
        t.route("/api/coding/projects", json: ["error": "boom"], status: 500)
        await store.loadSessions()
        XCTAssertTrue(store.error?.hasPrefix("Could not load coding sessions:") == true)
        XCTAssertFalse(store.loading)
    }

    func testQuietRefreshNeverWipesAGoodListWithAnEmptyPayload() async {
        let (store, t) = makeStore()
        // An old backend (or a blip) answers with an empty tree.
        t.route("/api/coding/projects", json: ["projects": [], "ungrouped": []])
        store.sessions = [CodingSession(id: "s1", status: "running")]
        await store.refreshSessionsQuiet()
        XCTAssertEqual(store.sessions.map(\.id), ["s1"])
    }

    func testQuietRefreshClearsAVanishedSelection() async {
        let (store, t) = makeStore()
        t.route("/api/coding/projects", json: expandedTree)
        store.selectedId = "gone"
        store.selected = CodingSession(id: "gone")
        await store.refreshSessionsQuiet()
        XCTAssertNil(store.selectedId)
        XCTAssertNil(store.selected)
    }

    func testCollapseToggle() {
        let (store, _) = makeStore()
        XCTAssertFalse(store.isCollapsed("p1"))
        store.toggleCollapsed("p1")
        XCTAssertTrue(store.isCollapsed("p1"))
        store.toggleCollapsed("p1")
        XCTAssertFalse(store.isCollapsed("p1"))
        store.toggleCollapsed(CodingStore.ungroupedKey)
        XCTAssertTrue(store.collapsed.contains("__ungrouped__"))
    }

    // MARK: - Poll gating (the Flutter `activeTabIndex` + foreground gate)

    func testListPollDoesNoNetworkWorkWhileHidden() async {
        var visible = false
        let (store, t) = makeStore(visible: { visible })
        let ticked = await store.listPollTick()
        XCTAssertFalse(ticked)
        XCTAssertTrue(t.requests.isEmpty, "a hidden tab must not touch the network")

        visible = true
        t.route("/api/coding/projects", json: expandedTree)
        t.route("/api/coding/permission/pending", json: ["pending": []])
        let value1 = await store.listPollTick()
        XCTAssertTrue(value1)
        XCTAssertEqual(t.requests.count, 2, "one tree refresh + one approvals poll")
        XCTAssertEqual(store.sessions.count, 3)
    }

    func testDetailPollDoesNoNetworkWorkWhileHidden() async {
        var visible = false
        let (store, t) = makeStore(visible: { visible })
        store.selectedId = "s1"
        let value2 = await store.detailPollTick()
        XCTAssertFalse(value2)
        XCTAssertTrue(t.requests.isEmpty)

        visible = true
        t.route("/api/coding/session/s1/sync", json: ["enabled": false, "status": "off"])
        t.route("/api/coding/session/s1", json: ["session": ["id": "s1", "status": "running"]])
        let value3 = await store.detailPollTick()
        XCTAssertTrue(value3)
        XCTAssertEqual(store.selected?.status, "running")
    }

    func testListPollingArmsOnceAndCancels() async {
        let (store, t) = makeStore(listPollEvery: 0.02)
        t.route("/api/coding/projects", json: expandedTree)
        t.route("/api/coding/permission/pending", json: ["pending": []])

        store.setListPolling(true)
        let armed = store.listPollTask
        XCTAssertNotNil(armed)
        // The tab's `.onChange(initial:)` re-fires on every scene-phase flip;
        // that must reuse the loop, not restart (or stack) it.
        store.setListPolling(true)
        XCTAssertEqual(armed, store.listPollTask)

        await codingStoreWaitUntil("a couple of poll ticks") { t.requests.count >= 4 }

        store.setListPolling(false)
        XCTAssertNil(store.listPollTask)
        let after = t.requests.count
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(t.requests.count, after, "a cancelled poll touches the network no more")

        // And it can be re-armed afterwards.
        store.setListPolling(true)
        XCTAssertNotNil(store.listPollTask)
        store.setListPolling(false)
    }

    // MARK: - Per-session store cache

    func testDeselectReleasesTheSessionStore() async {
        let (store, t) = makeStore()
        // Routes are matched by substring in insertion order, so the longer
        // paths have to be registered before the bare session detail.
        t.route("/api/coding/session/s1/sync", json: ["enabled": false])
        t.route("/api/coding/session/s1/messages",
                json: ["messages": [], "total": 0, "status": "running"])
        t.route("/api/coding/session/s1/terminal/start", json: ["ok": true])
        t.route("/api/coding/session/s1", json: ["session": ["id": "s1", "status": "running"]])
        t.enqueueSSE("")
        store.sessions = [CodingSession(id: "s1", status: "running")]
        await store.select("s1")

        let first = store.sessionStore("s1")
        first.start()
        await codingStoreWaitUntil("the session's poll to arm") { first.pollTask != nil }

        store.deselect()
        XCTAssertNil(store.sessionStores["s1"], "leaving the session frees its buffers")
        XCTAssertNil(first.pollTask, "and stops its poll loop")
        XCTAssertFalse(store.sessionStore("s1") === first, "a fresh visit builds a fresh store")
    }

    func testTheSessionStoreCacheIsBounded() async {
        let (store, _) = makeStore()
        store.selectedId = "s1"
        let kept = store.sessionStore("s1")
        for id in ["s2", "s3", "s4", "s5"] { _ = store.sessionStore(id) }
        XCTAssertEqual(store.sessionStores.count, CodingStore.maxCachedSessionStores)
        XCTAssertTrue(store.sessionStore("s1") === kept, "the OPEN session is never evicted")
        XCTAssertNil(store.sessionStores["s2"], "the least recently used one went first")
        XCTAssertNotNil(store.sessionStores["s5"])
    }

    // MARK: - Detail refresh

    func testATransientBlipKeepsTheCachedDetailAndShowsNoBanner() async {
        let (store, t) = makeStore()
        store.selectedId = "s1"
        store.selected = CodingSession(id: "s1", status: "running")
        t.enqueue(json: ["error": "bad gateway"], status: 502)
        await store.refreshDetail()
        XCTAssertNil(store.error, "a 5xx on a poll tick must not flash a banner")
        XCTAssertEqual(store.selected?.status, "running")
        XCTAssertFalse(store.detailLoading)

        t.enqueue(error: URLError(.timedOut))
        await store.refreshDetail()
        XCTAssertNil(store.error)
    }

    /// A blip is a blip; a *run* of them is the server being down, and hiding
    /// that leaves the user reading a detail that stopped being true minutes ago.
    func testARunOfTransientFailuresEventuallySurfaces() async {
        let (store, t) = makeStore()
        store.selectedId = "s1"
        store.selected = CodingSession(id: "s1", status: "running")
        for _ in 0..<(CodingStore.transientFailureLimit - 1) {
            t.enqueue(json: ["error": "bad gateway"], status: 502)
            await store.refreshDetail()
            XCTAssertNil(store.error)
        }
        t.enqueue(json: ["error": "bad gateway"], status: 502)
        await store.refreshDetail()
        XCTAssertEqual(store.error, "Could not load session: bad gateway")
        XCTAssertEqual(store.selected?.status, "running", "the cached detail is still shown")

        // One good tick and the counter is forgiven again.
        t.enqueue(json: ["session": ["id": "s1", "status": "idle"]])
        await store.refreshDetail()
        XCTAssertNil(store.error)
        t.enqueue(json: ["error": "bad gateway"], status: 502)
        await store.refreshDetail()
        XCTAssertNil(store.error)
    }

    func testARealFailureIsSurfaced() async {
        let (store, t) = makeStore()
        store.selectedId = "s1"
        store.selected = CodingSession(id: "s1", status: "running")
        t.enqueue(json: ["error": "no such session"], status: 404)
        await store.refreshDetail()
        XCTAssertEqual(store.error, "Could not load session: no such session")
    }

    func testAFailureWithNothingCachedIsAlwaysSurfaced() async {
        let (store, t) = makeStore()
        store.selectedId = "s1"
        t.enqueue(json: ["error": "bad gateway"], status: 502)
        await store.refreshDetail()
        XCTAssertEqual(store.error, "Could not load session: bad gateway")
    }

    func testTransientClassification() {
        XCTAssertTrue(CodingStore.isTransient(APIError.http(status: 502, message: "")))
        XCTAssertTrue(CodingStore.isTransient(APIError.cancelled))
        XCTAssertTrue(CodingStore.isTransient(URLError(.notConnectedToInternet)))
        XCTAssertFalse(CodingStore.isTransient(APIError.http(status: 404, message: "")))
        XCTAssertFalse(CodingStore.isTransient(APIError.badResponse("nope")))
        XCTAssertFalse(CodingStore.isTransient(CodingServerError(message: "x")))
    }

    // MARK: - Sync status

    func testSyncStatusIsOnlyAdoptedOnAMeaningfulChange() async {
        let (store, t) = makeStore()
        store.selectedId = "s1"
        t.enqueue(json: ["enabled": true, "status": "syncing", "total": 4, "done": 1, "last_sync_at": 1])
        await store.refreshSyncStatus()
        XCTAssertEqual(store.sync?.done, 1)

        // Only `last_sync_at` moved — re-rendering the card for that is churn.
        t.enqueue(json: ["enabled": true, "status": "syncing", "total": 4, "done": 1, "last_sync_at": 999])
        await store.refreshSyncStatus()
        XCTAssertEqual(store.sync?.lastSyncAt, 1)

        t.enqueue(json: ["enabled": true, "status": "syncing", "total": 4, "done": 2])
        await store.refreshSyncStatus()
        XCTAssertEqual(store.sync?.done, 2)

        // A dead endpoint keeps the last known status.
        t.enqueue(json: ["error": "nope"], status: 404)
        await store.refreshSyncStatus()
        XCTAssertEqual(store.sync?.done, 2)
    }

    func testSyncChangeDetection() {
        let base = CodingSyncStatus(enabled: true, device: "mac", status: "syncing", total: 4, done: 1)
        XCTAssertTrue(CodingStore.syncChanged(nil, base))
        XCTAssertFalse(CodingStore.syncChanged(base, base))
        var moved = base
        moved.done = 2
        XCTAssertTrue(CodingStore.syncChanged(base, moved))
        var stamped = base
        stamped.lastSyncAt = 1
        stamped.healed = 3
        XCTAssertFalse(CodingStore.syncChanged(base, stamped),
                       "the constantly-ticking fields are deliberately ignored")
    }

    // MARK: - Approvals

    private let twoPending: [String: Any] = ["pending": [
        ["request_id": "rq_1", "tool": "Bash", "summary": "Bash: rm -rf build/", "cwd": "/home/p/jc"],
        ["request_id": "rq_2", "tool": "Edit", "summary": "Edit: main.swift", "cwd": "/home/p/jc"],
    ]]

    func testApprovalsPollAndTheAnsweredTombstone() async {
        let (store, t) = makeStore()
        t.route("/api/coding/permission/pending", json: twoPending)
        t.route("/api/coding/permission/verdict", json: ["ok": true])
        await store.refreshPendingApprovals()
        XCTAssertEqual(store.pendingApprovals.map(\.requestId), ["rq_1", "rq_2"])

        await store.respondPermission("rq_1", decision: "deny", message: "use rm -i")
        XCTAssertEqual(store.pendingApprovals.map(\.requestId), ["rq_2"])
        XCTAssertEqual(t.lastBody()["message"] as? String, "use rm -i")

        // A poll that was in flight when the verdict landed still lists rq_1 —
        // the answered card must NOT flicker back.
        await store.refreshPendingApprovals()
        XCTAssertEqual(store.pendingApprovals.map(\.requestId), ["rq_2"])
        XCTAssertNil(store.error)
    }

    func testAFailedVerdictRestoresTheCard() async {
        let (store, t) = makeStore()
        t.route("/api/coding/permission/pending", json: twoPending)
        t.route("/api/coding/permission/verdict", json: ["error": "relay down"], status: 500)
        await store.refreshPendingApprovals()
        await store.respondPermission("rq_1", decision: "allow")
        XCTAssertEqual(store.pendingApprovals.map(\.requestId), ["rq_1", "rq_2"],
                       "the card comes back at the front")
        XCTAssertEqual(store.error, "Could not send your decision: relay down")

        // And the tombstone was dropped, so the next poll shows it again.
        await store.refreshPendingApprovals()
        XCTAssertEqual(store.pendingApprovals.map(\.requestId), ["rq_1", "rq_2"])
    }

    /// The pending-permission poll is the in-app fallback for a missed push; a
    /// poll that keeps failing means tool permissions are stuck on the Mac with
    /// nobody able to answer them.
    func testAPersistentlyFailingApprovalPollSurfaces() async {
        let (store, t) = makeStore()
        t.route("/api/coding/permission/pending", json: ["error": "relay down"], status: 500)
        for _ in 0..<(CodingStore.transientFailureLimit - 1) {
            await store.refreshPendingApprovals()
            XCTAssertNil(store.error, "one blip stays quiet")
        }
        await store.refreshPendingApprovals()
        XCTAssertEqual(store.error, "Approval requests aren’t reaching this device: relay down")
    }

    func testSyncNowSurfacesAFailedKick() async {
        let (store, t) = makeStore()
        store.selectedId = "s1"
        t.route("/api/coding/session/s1/sync/refresh", json: ["error": "device offline"], status: 502)
        t.route("/api/coding/session/s1/sync", json: ["enabled": true, "status": "syncing"])
        await store.refreshSync()
        XCTAssertEqual(store.error, "Sync refresh failed: device offline")
        // The status poll still ran, so the card shows reality alongside it.
        XCTAssertEqual(store.sync?.status, "syncing")
    }

    // MARK: - Selection / lifecycle

    func testSelectLoadsTheDetailAndKeepsAPerSessionStore() async {
        let (store, t) = makeStore()
        t.route("/api/coding/session/s1/sync", json: ["enabled": false, "status": "off"])
        t.route("/api/coding/session/s1/terminal/start", json: ["ok": true])
        t.route("/api/coding/session/s1", json: ["session": ["id": "s1", "status": "running", "cwd": "/home/p/jc"]])
        store.sessions = [CodingSession(id: "s1", status: "starting")]
        await store.select("s1")
        XCTAssertEqual(store.selectedId, "s1")
        XCTAssertEqual(store.selected?.status, "running")
        XCTAssertFalse(store.detailLoading)

        let a = store.sessionStore("s1")
        XCTAssertTrue(a === store.sessionStore("s1"), "cached so the terminal survives a rebuild")
        XCTAssertFalse(a === store.sessionStore("s2"))
        XCTAssertTrue(a.attachments === store.attachments, "one attachment tray for the whole tab")
        store.deselect()
        XCTAssertNil(store.selectedId)
    }

    func testLaunchRefreshesTheTreeAndOpensTheNewSession() async {
        let (store, t) = makeStore()
        t.route("/api/coding/launch", json: ["session": ["id": "s9", "status": "starting"]])
        t.route("/api/coding/projects", json: [
            "projects": [], "ungrouped": [["id": "s9", "status": "starting"]],
        ])
        t.route("/api/coding/session/s9/sync", json: ["enabled": false, "status": "off"])
        t.route("/api/coding/session/s9", json: ["session": ["id": "s9", "status": "running"]])
        let session = await store.launch(cwd: "/home/p/jc", title: "new")
        XCTAssertEqual(session?.id, "s9")
        XCTAssertEqual(store.selectedId, "s9")
        XCTAssertEqual(store.selected?.status, "running")
        XCTAssertFalse(store.launching)
    }

    func testLaunchInProjectExpandsTheProjectFirst() async {
        let (store, t) = makeStore()
        store.toggleCollapsed("p1")
        t.route("/api/coding/project/p1/session", json: ["session": ["id": "s9"]])
        t.route("/api/coding/projects", json: ["projects": [], "ungrouped": [["id": "s9"]]])
        t.route("/api/coding/session/s9/sync", json: ["enabled": false])
        t.route("/api/coding/session/s9", json: ["session": ["id": "s9"]])
        _ = await store.launchInProject("p1", prompt: "go")
        XCTAssertFalse(store.isCollapsed("p1"), "a new session must be visible")
    }

    func testLaunchFailureSetsAnError() async {
        let (store, t) = makeStore()
        t.route("/api/coding/launch", json: ["error": "no such folder"], status: 400)
        let value4 = await store.launch(cwd: "/nope")
        XCTAssertNil(value4)
        XCTAssertEqual(store.error, "Could not launch session: no such folder")
        XCTAssertFalse(store.launching)
    }

    func testDeleteClearsTheSelection() async {
        let (store, t) = makeStore()
        t.route("/api/coding/session/s1/delete", json: ["ok": true])
        t.route("/api/coding/projects", json: ["projects": [], "ungrouped": []])
        t.route("/api/coding/sessions", json: ["sessions": []])
        store.selectedId = "s1"
        store.selected = CodingSession(id: "s1")
        let value5 = await store.delete()
        XCTAssertTrue(value5)
        XCTAssertNil(store.selectedId)
        XCTAssertFalse(store.busy)
    }

    func testRelaunchOnDeviceNeedsAFolder() async {
        let (store, _) = makeStore()
        store.selectedId = "s1"
        store.selected = CodingSession(id: "s1", status: "stopped", source: "discovered-tmux")
        await store.relaunchOnDevice()
        XCTAssertEqual(store.error,
                       "Can’t relaunch — this session has no folder. Try “Resume on server”.")
    }

    func testResumeReturnsTheIdToOpen() async {
        let (store, t) = makeStore()
        t.route("/api/coding/session/s1/resume", json: ["ok": true, "session": ["id": "s1-live"]])
        t.route("/api/coding/projects", json: ["projects": [], "ungrouped": [["id": "s1-live"]]])
        let value6 = await store.resumeSession("s1")
        XCTAssertEqual(value6, "s1-live")
        XCTAssertFalse(store.busy)
    }

    func testSaveSettingsExplainsAnOldServer() async {
        let (store, t) = makeStore()
        store.selectedId = "s1"
        t.enqueue(json: ["error": "not found"], status: 404)
        let value7 = await store.saveSettings(skipPermissions: true)
        XCTAssertFalse(value7)
        XCTAssertEqual(store.error, "Saving settings isn’t available on this server yet.")

        t.enqueue(json: ["error": "disk full"], status: 500)
        let value8 = await store.saveSettings(cwd: "/x")
        XCTAssertFalse(value8)
        XCTAssertEqual(store.error, "Could not save settings: disk full")
    }

    func testLoadDevicesNeverThrows() async {
        let (store, t) = makeStore()
        t.enqueue(json: ["error": "nope"], status: 500)
        await store.loadDevices()
        XCTAssertTrue(store.devices.isEmpty)

        t.enqueue(json: ["devices": [["id": "desk", "kind": "desktop", "name": "Mac Studio"]]])
        await store.loadDevices()
        XCTAssertEqual(store.devices.map(\.name), ["Mac Studio"])
    }

    func testSendGoesThroughTheMessageEndpoint() async {
        let (store, t) = makeStore()
        t.route("/api/coding/session/s1/message", json: ["ok": true])
        t.route("/api/coding/session/s1", json: ["session": ["id": "s1", "status": "running"]])
        store.selectedId = "s1"
        await store.send("run the tests")
        XCTAssertNil(store.error)
        XCTAssertFalse(store.sending)
    }

    func testSendIgnoresAnEmptyComposer() async {
        let (store, t) = makeStore()
        store.selectedId = "s1"
        await store.send("   ")
        XCTAssertTrue(t.requests.isEmpty)
    }
}

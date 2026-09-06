import XCTest
@testable import JarvisCopilot

/// Fixtures are the shapes the Dart parser was written against: SQLite-ish JSON
/// where booleans are 0/1, numbers can be strings, and absent keys mean
/// "default".
private func obj(_ json: String) -> [String: Any] {
    (try! JSONSerialization.jsonObject(with: Data(json.utf8))) as! [String: Any]
}

final class CodingModelsTests: XCTestCase {

    // MARK: - CodingJSON coercions

    func testStrTreatsEmptyAndNullAsMissing() {
        let j = obj(#"{"a":"x","b":"","c":null,"d":0,"e":false}"#)
        XCTAssertEqual(CodingJSON.str(j["a"]), "x")
        XCTAssertNil(CodingJSON.str(j["b"]))
        XCTAssertNil(CodingJSON.str(j["c"]))
        XCTAssertNil(CodingJSON.str(j["missing"]))
        XCTAssertEqual(CodingJSON.str(j["d"]), "0")
        XCTAssertEqual(CodingJSON.str(j["e"]), "false")
    }

    func testTextFallsBackOnlyForNullAndMissing() {
        let j = obj(#"{"a":"","b":null}"#)
        XCTAssertEqual(CodingJSON.text(j["a"], "def"), "")
        XCTAssertEqual(CodingJSON.text(j["b"], "def"), "def")
        XCTAssertEqual(CodingJSON.text(j["missing"], "def"), "def")
    }

    func testBoolAcceptsSQLiteAndStringShapes() {
        let j = obj(#"{"t":true,"f":false,"one":1,"zero":0,"yes":"yes","str":"TRUE","no":"nope"}"#)
        XCTAssertTrue(CodingJSON.bool(j["t"]))
        XCTAssertFalse(CodingJSON.bool(j["f"]))
        XCTAssertTrue(CodingJSON.bool(j["one"]))
        XCTAssertFalse(CodingJSON.bool(j["zero"]))
        XCTAssertTrue(CodingJSON.bool(j["yes"]))
        XCTAssertTrue(CodingJSON.bool(j["str"]))
        XCTAssertFalse(CodingJSON.bool(j["no"]))
        XCTAssertFalse(CodingJSON.bool(j["missing"]))
        XCTAssertTrue(CodingJSON.bool(j["missing"], or: true))
        XCTAssertFalse(CodingJSON.bool(j["zero"], or: true))
    }

    func testIntTruncatesAndDefaultsToZero() {
        let j = obj(#"{"i":7,"d":3.7,"s":"42","bad":"3.7","b":true}"#)
        XCTAssertEqual(CodingJSON.int(j["i"]), 7)
        XCTAssertEqual(CodingJSON.int(j["d"]), 3)
        XCTAssertEqual(CodingJSON.int(j["s"]), 42)
        XCTAssertEqual(CodingJSON.int(j["bad"]), 0)
        XCTAssertEqual(CodingJSON.int(j["b"]), 0)
        XCTAssertEqual(CodingJSON.int(j["missing"]), 0)
        // The Live Activity variant rounds and takes a sentinel default.
        XCTAssertEqual(CodingJSON.int(j["d"], or: -1), 4)
        XCTAssertEqual(CodingJSON.int(j["missing"], or: -1), -1)
    }

    func testDoubleRejectsBooleansAndParsesStrings() {
        let j = obj(#"{"n":1.5,"s":"2.25","b":true}"#)
        XCTAssertEqual(CodingJSON.double(j["n"]), 1.5)
        XCTAssertEqual(CodingJSON.double(j["s"]), 2.25)
        XCTAssertNil(CodingJSON.double(j["b"]))
        XCTAssertNil(CodingJSON.double(j["missing"]))
    }

    func testMapsAndStringsSkipTheWrongShapes() {
        let j = obj(#"{"tools":[{"name":"Bash"},"junk",7],"diff":["+a","-b",3]}"#)
        XCTAssertEqual(CodingJSON.maps(j["tools"]).count, 1)
        XCTAssertEqual(CodingJSON.strings(j["diff"]), ["+a", "-b", "3"])
        XCTAssertEqual(CodingJSON.strings(j["missing"]), [])
    }

    // MARK: - CodingSession

    private let fullSession = #"""
    {
      "id": "cs_9f2a1b7c4d5e",
      "title": "Port the coding tab",
      "status": "running",
      "host": "server",
      "cwd": "/home/pranav/code/jarvis-copilot",
      "branch": "main",
      "claude_session_id": "b3f1e6d0-1111-4222-8333-abcdef012345",
      "source": "chat",
      "model": "opus",
      "skip_permissions": 1,
      "sync": {"enabled": 1, "device": "mac-studio", "remote_path": "/Users/pranav/code/jc"},
      "created_at": 1781000000.5,
      "project_id": "pj_7",
      "external": 0,
      "device_id": "",
      "tmux_name": "jc-cs_9f2a",
      "last_activity_at": "1781006400",
      "activity_state": "working",
      "attached": 1
    }
    """#

    func testParsesAFullSessionRow() {
        let s = CodingSession(json: obj(fullSession))
        XCTAssertEqual(s.id, "cs_9f2a1b7c4d5e")
        XCTAssertEqual(s.title, "Port the coding tab")
        XCTAssertEqual(s.status, "running")
        XCTAssertEqual(s.host, "server")
        XCTAssertEqual(s.branch, "main")
        XCTAssertEqual(s.model, "opus")
        XCTAssertTrue(s.skipPermissions)          // 1 → true
        XCTAssertEqual(s.sync?.device, "mac-studio")
        XCTAssertTrue(s.sync?.enabled == true)
        XCTAssertEqual(s.createdAt, 1781000000.5)
        XCTAssertEqual(s.projectId, "pj_7")
        XCTAssertFalse(s.external)                // 0 → false
        XCTAssertNil(s.deviceId)                  // "" → nil
        XCTAssertEqual(s.tmuxName, "jc-cs_9f2a")
        XCTAssertTrue(s.attached)
        XCTAssertEqual(s.displayTitle, "Port the coding tab")
        XCTAssertTrue(s.isLive)
        XCTAssertEqual(s.statusClass, "running")
        XCTAssertEqual(s.liveState, "working")
        XCTAssertEqual(s.fleetState, "working")
        XCTAssertFalse(s.isDim)
        XCTAssertFalse(s.isTranscriptIdle)
        XCTAssertFalse(s.isEnded)
        XCTAssertEqual(s.badge, SessionBadge(kind: "server", label: "server"))
        XCTAssertEqual(s.recencyTs, 1781006400)
    }

    func testAnEmptyRowFallsBackToTheDefaults() {
        let s = CodingSession(json: [:])
        XCTAssertEqual(s.id, "")
        XCTAssertEqual(s.status, "starting")
        XCTAssertNil(s.sync)
        XCTAssertTrue(s.attached, "attached defaults to true so we never wrongly dim")
        XCTAssertFalse(s.skipPermissions)
        XCTAssertEqual(s.displayTitle, "Session ")
        XCTAssertTrue(s.isLive)
        XCTAssertEqual(s.statusClass, "idle")
        XCTAssertEqual(s.liveState, "idle")
        XCTAssertEqual(s.recencyTs, 0)
    }

    func testDisplayTitleFallsBackToTheFolderThenTheId() {
        XCTAssertEqual(CodingSession(json: obj(#"{"id":"x","title":"  ","cwd":"/a/b/foo"}"#)).displayTitle, "foo")
        XCTAssertEqual(CodingSession(json: obj(#"{"id":"0123456789abc"}"#)).displayTitle, "Session 01234567")
    }

    func testStatusClassBuckets() {
        func cls(_ status: String) -> String {
            CodingSession(id: "x", status: status).statusClass
        }
        XCTAssertEqual(cls("busy"), "running")
        XCTAssertEqual(cls("Active"), "running")
        XCTAssertEqual(cls("completed"), "done")
        XCTAssertEqual(cls("Failed"), "error")
        XCTAssertEqual(cls("canceled"), "stopped")
        XCTAssertEqual(cls("whatever"), "idle")
    }

    func testLiveStateRefinesEvenAStartingSessionSoWaitingIsNeverMissed() {
        let s = CodingSession(id: "x", status: "starting", activityState: "waiting")
        XCTAssertEqual(s.liveState, "waiting")
        // A running session with no pane reading yet is presumed working…
        XCTAssertEqual(CodingSession(id: "x", status: "running").liveState, "working")
        // …but a starting one stays idle.
        XCTAssertEqual(CodingSession(id: "x", status: "starting").liveState, "idle")
    }

    func testForgottenDetachedTmuxIsDim() {
        let s = CodingSession(json: obj(#"{"id":"x","status":"running","source":"discovered-tmux","activity_state":"idle","attached":0}"#))
        XCTAssertTrue(s.isDim)
        XCTAssertEqual(s.fleetState, "dim")
        // Attached again ⇒ not dim.
        let attached = CodingSession(json: obj(#"{"id":"x","status":"running","source":"discovered-tmux","activity_state":"idle","attached":1}"#))
        XCTAssertFalse(attached.isDim)
        XCTAssertEqual(attached.fleetState, "idle")
    }

    func testTranscriptIdleAndItsBadge() {
        let s = CodingSession(json: obj(#"{"id":"x","status":"stopped","source":"discovered-transcript","external":1}"#))
        XCTAssertTrue(s.isTranscriptIdle)
        XCTAssertEqual(s.liveState, "history")
        XCTAssertEqual(s.badge, SessionBadge(kind: "history", label: "history"))
        XCTAssertFalse(s.isEnded, "a past transcript is resumable, not ended")
    }

    func testDiscoveredBadgeSaysLiveOnlyForARunningTranscript() {
        let live = CodingSession(json: obj(#"{"id":"x","status":"running","source":"discovered-transcript","external":1}"#))
        XCTAssertEqual(live.badge, SessionBadge(kind: "discovered", label: "live"))
        let discovered = CodingSession(json: obj(#"{"id":"x","status":"running","source":"discovered-tmux","external":1}"#))
        XCTAssertEqual(discovered.badge, SessionBadge(kind: "discovered", label: "discovered"))
    }

    func testDesktopBadge() {
        XCTAssertEqual(CodingSession(id: "x", host: "Desktop").badge,
                       SessionBadge(kind: "desktop", label: "desktop"))
    }

    func testIsEnded() {
        // A discovered tmux that got reconciled to stopped.
        XCTAssertTrue(CodingSession(id: "x", status: "stopped", source: "discovered-tmux").isEnded)
        // A server-launched session whose tmux died.
        XCTAssertTrue(CodingSession(id: "x", status: "error", host: "server").isEnded)
        // Host defaults to server when absent.
        XCTAssertTrue(CodingSession(id: "x", status: "stopped").isEnded)
        // A stopped DESKTOP session that wasn't discovered isn't "ended".
        XCTAssertFalse(CodingSession(id: "x", status: "stopped", host: "desktop", source: "manual").isEnded)
        XCTAssertFalse(CodingSession(id: "x", status: "running").isEnded)
    }

    func testRecencyNormalisesMillisecondsAndISOStrings() {
        XCTAssertEqual(CodingSession(json: obj(#"{"id":"x","last_activity_at":1781006400000}"#)).recencyTs,
                       1781006400)
        XCTAssertEqual(CodingSession(json: obj(#"{"id":"x","last_activity_at":"2026-06-09T12:00:00Z"}"#)).recencyTs,
                       1781006400)
        // Falls back to created_at when there's no activity stamp.
        XCTAssertEqual(CodingSession(json: obj(#"{"id":"x","created_at":1781000000}"#)).recencyTs,
                       1781000000)
        XCTAssertEqual(CodingSession(json: obj(#"{"id":"x","last_activity_at":"not a date"}"#)).recencyTs, 0)
    }

    // MARK: - CodingSync

    func testSyncOnlyParsesAnObjectAndSkipsEmptyFieldsWhenEncoding() {
        XCTAssertNil(CodingSync.from(nil))
        XCTAssertNil(CodingSync.from("off"))
        let s = CodingSync.from(obj(#"{"s":{"enabled":true,"device":"mac","remote_path":""}}"#)["s"])
        XCTAssertEqual(s, CodingSync(enabled: true, device: "mac", remotePath: nil))
        let json = s?.json ?? [:]
        XCTAssertEqual(json["enabled"] as? Bool, true)
        XCTAssertEqual(json["device"] as? String, "mac")
        XCTAssertNil(json["remote_path"], "an empty remote path is omitted, not blanked")
        XCTAssertEqual(json.count, 2)
    }

    // MARK: - CodingProject

    func testProjectParsesNestedSessions() {
        let p = CodingProject(json: obj(#"""
        {"id":"pj_7","name":"jarvis-copilot","repo_path":"/home/p/jc","host":"server",
         "device_id":"mac-studio","sync_enabled":1,"sync_desktop_path":"/Users/p/jc",
         "ignore_rules":"node_modules\n.venv","default_branch":"main",
         "sessions":[{"id":"a","status":"running"},"junk",{"id":"b","status":"idle"}]}
        """#))
        XCTAssertEqual(p.id, "pj_7")
        XCTAssertEqual(p.name, "jarvis-copilot")
        XCTAssertTrue(p.syncEnabled)
        XCTAssertEqual(p.defaultBranch, "main")
        XCTAssertEqual(p.sessions.map(\.id), ["a", "b"])
    }

    // MARK: - CodingDevice

    func testDesktopCapableFiltering() {
        func device(_ json: String) -> CodingDevice { CodingDevice(json: obj(json)) }
        // Mobile pairings hold a bridge WS but can never run Mutagen.
        XCTAssertFalse(device(#"{"id":"d1","kind":"mobile-ios","bridge_connected":true}"#).desktopCapable)
        // A desktop jc-client usually registers as 'browser' — the bridge is the tell.
        XCTAssertTrue(device(#"{"id":"d2","kind":"browser","bridge_connected":true}"#).desktopCapable)
        // The server's own flag wins when present.
        XCTAssertFalse(device(#"{"id":"d3","kind":"browser","bridge_connected":true,"sync_capable":false}"#).desktopCapable)
        XCTAssertTrue(device(#"{"id":"d4","kind":"desktop"}"#).desktopCapable)
        XCTAssertFalse(device(#"{"id":"d5","kind":"browser"}"#).desktopCapable)
    }

    func testDeviceIdentityAndOnlineDefault() {
        let d = CodingDevice(json: obj(#"{"device_id":"d4"}"#))
        XCTAssertEqual(d.id, "d4")
        XCTAssertEqual(d.name, "d4", "no name ⇒ show the id")
        XCTAssertTrue(d.online, "online defaults to true when absent")
        XCTAssertNil(d.syncCapable)
        XCTAssertFalse(CodingDevice(json: obj(#"{"id":"x","online":false}"#)).online)
        XCTAssertEqual(CodingDevice(json: obj(#"{"id":"x","device_name":"Mac Studio"}"#)).name, "Mac Studio")
        XCTAssertEqual(CodingDevice(json: obj(#"{"id":"x","kind":"DESKTOP"}"#)).kind, "desktop")
    }

    // MARK: - CodingSyncStatus

    func testSyncStatusProgress() {
        let syncing = CodingSyncStatus(json: obj(#"{"enabled":1,"device":"mac","device_online":1,"status":"syncing","total":8,"done":3,"conflicts":1,"healed":2,"last_sync_at":1781006400}"#))
        XCTAssertTrue(syncing.enabled)
        XCTAssertTrue(syncing.deviceOnline)
        XCTAssertTrue(syncing.isSyncing)
        XCTAssertEqual(syncing.pct, 38)
        XCTAssertEqual(syncing.conflicts, 1)
        XCTAssertEqual(syncing.healed, 2)
        XCTAssertEqual(syncing.lastSyncAt, 1781006400)

        XCTAssertEqual(CodingSyncStatus(json: obj(#"{"status":"synced"}"#)).pct, 100)
        XCTAssertEqual(CodingSyncStatus(json: obj(#"{"status":"error","error":"boom"}"#)).pct, 0)
        XCTAssertTrue(CodingSyncStatus(json: obj(#"{"status":"connecting"}"#)).isSyncing)
        // A syncing status with no file count can't show a bar.
        XCTAssertEqual(CodingSyncStatus(json: obj(#"{"status":"syncing"}"#)).pct, 0)
        XCTAssertEqual(CodingSyncStatus(json: [:]).status, "off")
    }

    // MARK: - CodingSessionDetail / usage

    func testSessionDetailUnwrapsOrAcceptsABareSession() {
        XCTAssertEqual(CodingSessionDetail(json: obj(#"{"session":{"id":"a"},"subagents":[]}"#)).session.id, "a")
        XCTAssertEqual(CodingSessionDetail(json: obj(#"{"id":"b"}"#)).session.id, "b")
    }

    func testUsageParsingUsesMinusOneForUnknown() {
        XCTAssertNil(CodingUsage.from(nil))
        XCTAssertNil(CodingUsage.from("nope"))
        let u = CodingUsage.from(obj(#"{"u":{"five_hour_pct":42,"weekly_resets":"Mon 09:00"}}"#)["u"])
        XCTAssertEqual(u, CodingUsage(fiveHourPct: 42, weeklyPct: -1,
                                      fiveHourResets: "", weeklyResets: "Mon 09:00"))
    }

    // MARK: - PendingPermission

    func testPendingPermissionRequiresARequestId() {
        XCTAssertNil(PendingPermission.from("junk"))
        XCTAssertNil(PendingPermission.from(obj(#"{"tool":"Bash"}"#)))
        let p = PendingPermission.from(obj(#"{"request_id":"rq_1","tool":"Bash","summary":"Bash: rm -rf build/","session_id":"cs_1","cwd":"/home/p/code/jc/"}"#))
        XCTAssertEqual(p?.requestId, "rq_1")
        XCTAssertEqual(p?.id, "rq_1")
        XCTAssertEqual(p?.summary, "Bash: rm -rf build/")
        XCTAssertEqual(p?.projectLabel, "jc", "trailing slashes are stripped")
        XCTAssertEqual(PendingPermission.from(obj(#"{"request_id":"r"}"#))?.tool, "tool")
        XCTAssertEqual(PendingPermission.from(obj(#"{"request_id":"r"}"#))?.projectLabel, "session")
    }

    // MARK: - PendingAttachment

    func testAttachmentImageSniffing() {
        XCTAssertTrue(PendingAttachment.looksImage("Photo.HEIC"))
        XCTAssertTrue(PendingAttachment.looksImage("a.jpeg"))
        XCTAssertFalse(PendingAttachment.looksImage("notes.pdf"))
        let a = PendingAttachment(name: "shot.png", data: Data([1, 2, 3]))
        XCTAssertTrue(a.isImage)
        XCTAssertEqual(a.size, 3)
    }
}

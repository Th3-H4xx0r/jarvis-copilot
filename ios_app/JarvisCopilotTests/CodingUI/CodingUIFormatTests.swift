import XCTest
import SwiftUI
@testable import JarvisCopilot

/// The Coding tab's pure presentation rules (`CodingUI`): fleet colours, sync
/// labels, device options, timestamps, grouping and terminal geometry.
@MainActor
final class CodingUIFormatTests: XCTestCase {

    // MARK: State colours & labels

    func testStateColorsSeparateTheFleetLadder() {
        XCTAssertEqual(CodingUI.stateColor("working"), CodingUI.green)
        XCTAssertEqual(CodingUI.stateColor("waiting"), CodingUI.purple)
        XCTAssertEqual(CodingUI.stateColor("idle"), CodingUI.grey)
        XCTAssertEqual(CodingUI.stateColor("dim"), CodingUI.dimGrey)
        XCTAssertEqual(CodingUI.stateColor("error"), JcTheme.danger)
        XCTAssertEqual(CodingUI.stateColor("running"), JcTheme.success)
        XCTAssertEqual(CodingUI.stateColor("done"), JcTheme.primaryBlue)
        // Anything the server invents later stays muted rather than crashing.
        XCTAssertEqual(CodingUI.stateColor("something-new"), JcTheme.muted)
    }

    func testStateLabelReadsAsEnglish() {
        XCTAssertEqual(CodingUI.stateLabel("waiting"), "needs input")
        XCTAssertEqual(CodingUI.stateLabel("dim"), "detached")
        XCTAssertEqual(CodingUI.stateLabel("working"), "working")
        XCTAssertEqual(CodingUI.stateLabel("stopped"), "stopped")
    }

    func testBadgeAndStatusColors() {
        XCTAssertEqual(CodingUI.badgeColor(kind: "discovered"), JcTheme.cyan)
        XCTAssertEqual(CodingUI.badgeColor(kind: "desktop"), JcTheme.accent)
        XCTAssertEqual(CodingUI.badgeColor(kind: "history"), JcTheme.muted)
        XCTAssertEqual(CodingUI.badgeColor(kind: "server"), JcTheme.primaryBlueHi)

        XCTAssertEqual(CodingUI.statusColor("running"), JcTheme.success)
        XCTAssertEqual(CodingUI.statusColor("starting"), JcTheme.primaryBlue)
        XCTAssertEqual(CodingUI.statusColor("idle"), JcTheme.primaryBlue)
        XCTAssertEqual(CodingUI.statusColor("error"), JcTheme.danger)
        XCTAssertEqual(CodingUI.statusColor("stopped"), JcTheme.muted)
    }

    func testStateChipFallsBackToLiveOrOffline() {
        XCTAssertEqual(CodingUI.stateChip(activityState: "working", live: true).label, "Working")
        XCTAssertTrue(CodingUI.stateChip(activityState: "working", live: true).spinning)
        XCTAssertEqual(CodingUI.stateChip(activityState: "waiting", live: true).label, "Needs input")
        XCTAssertFalse(CodingUI.stateChip(activityState: "waiting", live: true).spinning)
        XCTAssertEqual(CodingUI.stateChip(activityState: nil, live: true).label, "Live")
        XCTAssertEqual(CodingUI.stateChip(activityState: nil, live: false).label, "Offline")
    }

    func testContextGaugeRampsWithOccupancy() {
        XCTAssertEqual(CodingUI.contextColor(pct: 10), JcTheme.primaryBlueHi)
        XCTAssertEqual(CodingUI.contextColor(pct: 80), Color(jcHex: 0xFBBF24))
        XCTAssertEqual(CodingUI.contextColor(pct: 95), Color(jcHex: 0xF87171))
    }

    // MARK: Sync

    func testSyncLabelOfflineOverridesEverythingButDisconnected() {
        let syncing = CodingSyncStatus(enabled: true, deviceOnline: false, status: "syncing")
        XCTAssertEqual(CodingUI.syncLabel(syncing), "Device offline")
        let disconnected = CodingSyncStatus(enabled: true, deviceOnline: false, status: "disconnected")
        XCTAssertEqual(CodingUI.syncLabel(disconnected), "Device offline")
    }

    func testSyncLabelsForEachStatus() {
        func label(_ status: String, conflicts: Int = 0) -> String {
            CodingUI.syncLabel(CodingSyncStatus(enabled: true, deviceOnline: true,
                                                status: status, conflicts: conflicts))
        }
        XCTAssertEqual(label("synced"), "Up to date")
        XCTAssertEqual(label("syncing"), "Syncing…")
        XCTAssertEqual(label("opening"), "Connecting…")
        XCTAssertEqual(label("connecting"), "Connecting…")
        XCTAssertEqual(label("idle"), "Idle")
        XCTAssertEqual(label("error"), "Error")
        XCTAssertEqual(label("conflicts", conflicts: 1), "1 conflict (auto-resolving…)")
        XCTAssertEqual(label("conflicts", conflicts: 3), "3 conflicts (auto-resolving…)")
        XCTAssertEqual(label("brand-new"), "brand-new")
    }

    func testSyncIdleWhileDeviceOfflineWaits() {
        let s = CodingSyncStatus(enabled: true, deviceOnline: false, status: "idle")
        // deviceOnline==false short-circuits to the offline line first.
        XCTAssertEqual(CodingUI.syncLabel(s), "Device offline")
    }

    func testSyncProgressLabel() {
        XCTAssertNil(CodingUI.syncProgressLabel(
            CodingSyncStatus(enabled: true, deviceOnline: true, status: "synced")))
        let unknown = CodingSyncStatus(enabled: true, deviceOnline: true, status: "syncing")
        XCTAssertEqual(CodingUI.syncProgressLabel(unknown), "Syncing…")
        let counted = CodingSyncStatus(enabled: true, deviceOnline: true, status: "syncing",
                                       total: 200, done: 50)
        XCTAssertEqual(CodingUI.syncProgressLabel(counted), "50/200 files · 25%")
    }

    // MARK: Devices

    func testDesktopIndicatorPrefersAnOnlineDevice() {
        XCTAssertNil(CodingUI.desktopIndicator([]))
        let mixed = [CodingDevice(id: "a", name: "Old Mac", online: false),
                     CodingDevice(id: "b", name: "Studio", online: true)]
        let up = CodingUI.desktopIndicator(mixed)
        XCTAssertEqual(up?.label, "Studio")
        XCTAssertEqual(up?.online, true)
        let down = CodingUI.desktopIndicator([CodingDevice(id: "a", name: "Old Mac", online: false)])
        XCTAssertEqual(down?.label, "Old Mac")
        XCTAssertEqual(down?.online, false)
    }

    func testDeviceOptionsLabelOfflineAndKeepAnUnknownSavedValue() {
        let devices = [CodingDevice(id: "mac-1", name: "Studio", online: true),
                       CodingDevice(id: "mac-2", name: "Air", online: false)]
        let options = CodingUI.deviceOptions(devices, selected: "")
        XCTAssertEqual(options.map(\.value), ["", "mac-1", "mac-2"])
        XCTAssertEqual(options[0].label, "— choose a device —")
        XCTAssertEqual(options[1].label, "Studio")
        XCTAssertEqual(options[2].label, "Air (offline)")

        // A saved value the server no longer lists survives as a synthetic row.
        let stale = CodingUI.deviceOptions(devices, selected: "mac-9")
        XCTAssertEqual(stale.last?.value, "mac-9")
        XCTAssertEqual(stale.last?.label, "mac-9 (not connected)")

        // Matching by NAME counts as known (settings may have stored either).
        let byName = CodingUI.deviceOptions(devices, selected: "Studio")
        XCTAssertEqual(byName.count, 3)
    }

    func testProjectOptionsLeadWithNoProject() {
        let projects = [CodingProject(id: "p1", name: "Jarvis", repoPath: "~/code/jarvis"),
                        CodingProject(id: "p2", name: "", repoPath: "~/code/x")]
        let options = CodingUI.projectOptions(projects)
        XCTAssertEqual(options.map(\.value), ["", "p1", "p2"])
        XCTAssertEqual(options[0].label, "No project (ungrouped)")
        XCTAssertEqual(options[1].subtitle, "~/code/jarvis")
        // A nameless project still has to be pickable.
        XCTAssertEqual(options[2].label, "p2")
    }

    // MARK: Approvals

    func testApprovalSummaryFallsBackToTheToolName() {
        let bare = PendingPermission(requestId: "r1", tool: "Bash", summary: "")
        XCTAssertEqual(CodingUI.approvalSummary(bare), "Bash")
        let full = PendingPermission(requestId: "r1", tool: "Bash", summary: "rm -rf build/")
        XCTAssertEqual(CodingUI.approvalSummary(full), "rm -rf build/")
    }

    func testApprovalMetaCountsTheQueue() {
        let p = PendingPermission(requestId: "r1", tool: "Bash", summary: "x",
                                  sessionId: "s1", cwd: "/Users/me/code/jarvis")
        XCTAssertEqual(CodingUI.approvalMeta(p, extra: 0), "jarvis")
        XCTAssertEqual(CodingUI.approvalMeta(p, extra: 2), "jarvis · +2")
    }

    // MARK: Usage

    func testUsageLabelHidesTheUnknownSentinel() {
        XCTAssertNil(CodingUI.usageLabel(pct: -1, resets: "3pm"))
        XCTAssertEqual(CodingUI.usageLabel(pct: 12, resets: ""), "12%")
        XCTAssertEqual(CodingUI.usageLabel(pct: 12, resets: " 3pm "), "12% · resets 3pm")
    }

    func testUsageColorRamps() {
        XCTAssertEqual(CodingUI.usageColor(pct: 10), JcTheme.primaryBlueHi)
        XCTAssertEqual(CodingUI.usageColor(pct: 80), JcTheme.amber)
        XCTAssertEqual(CodingUI.usageColor(pct: 95), JcTheme.danger)
    }

    // MARK: Time

    func testRelativeTime() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func rel(_ ago: TimeInterval) -> String {
            CodingUI.relativeTime(now.timeIntervalSince1970 - ago, now: now)
        }
        XCTAssertEqual(CodingUI.relativeTime(0, now: now), "")
        XCTAssertEqual(rel(5), "now")
        XCTAssertEqual(rel(44), "now")
        XCTAssertEqual(rel(120), "2m")
        XCTAssertEqual(rel(3 * 3600 + 60), "3h")
        XCTAssertEqual(rel(2 * 86_400), "2d")
        // Past a week it becomes a plain "Oct 15"-style date (locale-fixed).
        let old = rel(30 * 86_400)
        XCTAssertNotNil(old.range(of: "^[A-Z][a-z]{2} [0-9]{1,2}$", options: .regularExpression),
                        "unexpected old-session label: \(old)")
    }

    func testRelativeTimeTreatsAServerAheadOfUsAsNow() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(CodingUI.relativeTime(now.timeIntervalSince1970 + 30, now: now), "now")
    }

    func testMessageTimeDropsTheDateOnlyForToday() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 22:13 UTC
        XCTAssertNil(CodingUI.messageTime(nil, now: now, calendar: cal))
        XCTAssertNil(CodingUI.messageTime(0, now: now, calendar: cal))

        let earlierToday = now.timeIntervalSince1970 - 3600
        XCTAssertEqual(CodingUI.messageTime(earlierToday, now: now, calendar: cal), "21:13")

        let yesterday = now.timeIntervalSince1970 - 86_400
        XCTAssertEqual(CodingUI.messageTime(yesterday, now: now, calendar: cal), "11/13 22:13")
    }

    // MARK: Terminal geometry

    func testTerminalViewportFromSizeAndCell() {
        let cell = CGSize(width: 7, height: 14)
        let vp = CodingUI.terminalViewport(size: CGSize(width: 350, height: 280), cell: cell)
        XCTAssertEqual(vp.cols, 50)
        XCTAssertEqual(vp.rows, 20)
    }

    func testTerminalViewportFallsBackAndClamps() {
        let cell = CGSize(width: 7, height: 14)
        // A first-frame zero layout must not resize the tmux to nothing.
        XCTAssertEqual(CodingUI.terminalViewport(size: .zero, cell: cell).cols, 80)
        XCTAssertEqual(CodingUI.terminalViewport(size: .zero, cell: cell).rows, 24)
        XCTAssertEqual(CodingUI.terminalViewport(size: CGSize(width: 400, height: 400),
                                                 cell: .zero).cols, 80)
        // Tiny but non-zero stays at the floor.
        let tiny = CodingUI.terminalViewport(size: CGSize(width: 20, height: 20), cell: cell)
        XCTAssertEqual(tiny.cols, 20)
        XCTAssertEqual(tiny.rows, 4)
        // Absurdly wide is capped.
        let huge = CodingUI.terminalViewport(size: CGSize(width: 99_000, height: 99_000), cell: cell)
        XCTAssertEqual(huge.cols, 400)
        XCTAssertEqual(huge.rows, 200)
    }

    // MARK: Console key bar

    func testKeyBarSendsTheStandardXtermSequences() {
        let row1 = Dictionary(uniqueKeysWithValues: CodingTerminalKeyBar.row1)
        XCTAssertEqual(row1["Esc"], "\u{1b}")
        XCTAssertEqual(row1["\u{2191}"], "\u{1b}[A")   // CSI A — normal cursor-key mode
        XCTAssertEqual(row1["\u{2193}"], "\u{1b}[B")
        XCTAssertEqual(row1["\u{23ce}"], "\r")
        XCTAssertEqual(row1["^C"], "\u{3}")

        let row2 = Dictionary(uniqueKeysWithValues: CodingTerminalKeyBar.row2)
        XCTAssertEqual(row2["1"], "1")
        XCTAssertEqual(row2["6"], "6")
        XCTAssertEqual(row2["\u{21e5}"], "\t")
        XCTAssertEqual(row2["\u{21e7}\u{21e5}"], "\u{1b}[Z") // CSI Z — the permission-mode cycler
    }

    func testTerminalCellIsMeasuredNotGuessed() {
        let cell = CodingTerminalPanel.cell
        XCTAssertGreaterThan(cell.width, 1)
        XCTAssertGreaterThan(cell.height, cell.width)
    }

    // MARK: Grouping

    private func session(_ id: String, activity: Double) -> CodingSession {
        CodingSession(id: id, status: "running", lastActivityAt: "\(activity)")
    }

    func testGroupsSortSessionsNewestFirstWithinEachProject() {
        let p = CodingProject(id: "p1", name: "Jarvis", repoPath: "~/code/jarvis",
                              sessions: [session("old", activity: 100),
                                         session("new", activity: 900)])
        let groups = CodingUI.groups(projects: [p], ungrouped: [], sessions: [])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].key, "p1")
        XCTAssertEqual(groups[0].name, "Jarvis")
        XCTAssertEqual(groups[0].subtitle, "~/code/jarvis")
        XCTAssertEqual(groups[0].sessions.map(\.id), ["new", "old"])
        XCTAssertTrue(groups[0].hasProjectActions)
    }

    func testGroupsAppendUngroupedOnlyWhenItHasSessions() {
        let p = CodingProject(id: "p1", name: "Jarvis", sessions: [session("a", activity: 5)])
        XCTAssertEqual(CodingUI.groups(projects: [p], ungrouped: [], sessions: []).count, 1)
        let withLoose = CodingUI.groups(projects: [p], ungrouped: [session("b", activity: 5)],
                                        sessions: [])
        XCTAssertEqual(withLoose.map(\.key), ["p1", CodingStore.ungroupedKey])
        XCTAssertEqual(withLoose[1].name, "Ungrouped")
        XCTAssertFalse(withLoose[1].hasProjectActions)
    }

    func testGroupsFoldTheFlatListInWhenTheBackendHasNoProjects() {
        // Older backends answer /projects with nothing — the flat list must not
        // silently disappear.
        let flat = [session("a", activity: 1), session("b", activity: 9)]
        let groups = CodingUI.groups(projects: [], ungrouped: [], sessions: flat)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].key, CodingStore.ungroupedKey)
        XCTAssertEqual(groups[0].sessions.map(\.id), ["b", "a"])
    }

    func testGroupNameFallsBackToRepoPathThenId() {
        let noName = CodingProject(id: "p2", name: "", repoPath: "~/code/x")
        XCTAssertEqual(CodingUI.groups(projects: [noName], ungrouped: [], sessions: [])[0].name,
                       "~/code/x")
        let bare = CodingProject(id: "p3", name: "")
        XCTAssertEqual(CodingUI.groups(projects: [bare], ungrouped: [], sessions: [])[0].name,
                       "project p3")
    }

    func testAnEmptyProjectStillGetsItsGroupSoItsPlusIsReachable() {
        let empty = CodingProject(id: "p1", name: "Fresh")
        let groups = CodingUI.groups(projects: [empty], ungrouped: [], sessions: [])
        XCTAssertEqual(groups.count, 1)
        XCTAssertTrue(groups[0].sessions.isEmpty)
    }
}

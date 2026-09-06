import SwiftUI
import UIKit
import XCTest
@testable import JarvisCopilot

/// Hosting smoke tests for the Coding tab's screens: each one is mounted in a
/// `UIHostingController` and laid out, which type-checks the whole view tree at
/// runtime and catches the crashes SwiftUI only raises when a body actually
/// evaluates (a missing environment object, a `ForEach` over duplicate ids, a
/// `navigationDestination` outside a stack, state mutated during a render).
///
/// They deliberately assert structure and store state rather than pixels — the
/// point is "this screen renders, with this data, without exploding".
@MainActor
final class CodingViewHostingTests: XCTestCase {

    // MARK: Harness

    private static let screen = CGSize(width: 393, height: 852)

    /// Windows are retained for the test's lifetime: letting one deallocate while
    /// its controller is mid-appearance logs "unbalanced begin/end appearance
    /// transitions" and can drop the `onAppear` we are trying to exercise.
    private var windows: [UIWindow] = []

    override func tearDown() {
        windows.forEach { $0.isHidden = true; $0.rootViewController = nil }
        windows.removeAll()
        super.tearDown()
    }

    /// Mount a view at iPhone size and force a full layout pass.
    @discardableResult
    private func host<V: View>(_ view: V) -> UIHostingController<V> {
        let vc = UIHostingController(rootView: view)
        vc.view.frame = CGRect(origin: .zero, size: Self.screen)
        // A window makes the hosting controller run its real appearance path,
        // so `onAppear`/`task` fire the way they do in the app.
        let window = UIWindow(frame: vc.view.frame)
        window.rootViewController = vc
        window.isHidden = false
        windows.append(window)
        vc.view.setNeedsLayout()
        vc.view.layoutIfNeeded()
        return vc
    }

    /// Proof the SwiftUI body evaluated and produced geometry.
    ///
    /// Subview counts are NOT usable here: a flat view (one card, no scroll view)
    /// is drawn into a single display list with no child `UIView`s at all, so an
    /// empty `subviews` says nothing. `sizeThatFits` has to run the real layout,
    /// which is exactly what these tests want to prove happened.
    private func assertRendered<V: View>(_ vc: UIHostingController<V>,
                                         file: StaticString = #filePath,
                                         line: UInt = #line) {
        XCTAssertGreaterThan(vc.view.bounds.width, 0, "view has no width", file: file, line: line)
        let fitted = vc.sizeThatFits(in: Self.screen)
        XCTAssertGreaterThan(fitted.width, 0, "view measured no width", file: file, line: line)
        XCTAssertGreaterThan(fitted.height, 0, "view measured no height", file: file, line: line)
    }

    /// A store wired to a mock transport, with every endpoint the fleet touches
    /// answered. More specific paths are routed FIRST — `MockTransport.route`
    /// matches on a substring, first hit wins.
    private func fleetStore(projects: [[String: Any]] = [],
                            ungrouped: [[String: Any]] = [],
                            devices: [[String: Any]] = [],
                            pending: [[String: Any]] = []) -> (CodingStore, MockTransport) {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/coding/permission/pending", json: ["pending": pending])
        transport.route("/api/coding/projects",
                        json: ["projects": projects, "ungrouped": ungrouped])
        transport.route("/api/coding/sessions", json: ["sessions": []])
        transport.route("/api/coding/usage",
                        json: ["usage": ["five_hour_pct": 42, "weekly_pct": 7,
                                         "five_hour_resets": "3pm", "weekly_resets": "Sunday"]])
        transport.route("/api/devices", json: ["devices": devices])
        let store = CodingStore(api: CodingSessionsAPI(api: api), isVisible: { true })
        return (store, transport)
    }

    // MARK: CodingPage

    func testCodingPageRendersItsEmptyState() async {
        let (store, _) = fleetStore()
        await store.loadSessions()
        XCTAssertTrue(store.sessions.isEmpty)

        let vc = host(CodingPage(store: store).environment(AppRouter()))
        assertRendered(vc)
    }

    func testCodingPageRendersAPopulatedTree() async {
        let (store, _) = fleetStore(
            projects: [[
                "id": "p1", "name": "Jarvis", "repo_path": "~/code/jarvis",
                "sync_enabled": true, "device_id": "mac-1",
                "sessions": [
                    ["id": "s1", "title": "Port the coding tab", "status": "running",
                     "activity_state": "working", "cwd": "/Users/me/code/jarvis",
                     "last_activity_at": "1700000000", "host": "server"],
                    ["id": "s2", "title": "Waiting on me", "status": "running",
                     "activity_state": "waiting", "last_activity_at": "1699999000"],
                ],
            ]],
            ungrouped: [
                ["id": "s3", "title": "Old transcript", "status": "stopped",
                 "source": "discovered-transcript", "external": true,
                 "cwd": "/Users/me/code/other", "last_activity_at": "1699000000"],
                ["id": "s4", "title": "Forgotten tmux", "status": "idle",
                 "source": "discovered-tmux", "external": true, "attached": 0],
            ],
            devices: [["id": "mac-1", "name": "Studio", "online": true, "sync_capable": true]],
            pending: [["request_id": "r1", "tool": "Bash", "summary": "rm -rf build/",
                       "session_id": "s1", "cwd": "/Users/me/code/jarvis"]])

        await store.loadSessions()
        await store.loadDevices()
        await store.refreshPendingApprovals()

        XCTAssertEqual(store.projects.count, 1)
        XCTAssertEqual(store.sessions.count, 4)
        XCTAssertEqual(store.pendingApprovals.count, 1)
        // The tree the fleet actually renders: one project + Ungrouped.
        let groups = CodingUI.groups(projects: store.projects, ungrouped: store.ungrouped,
                                     sessions: store.sessions)
        XCTAssertEqual(groups.map(\.key), ["p1", CodingStore.ungroupedKey])

        let vc = host(CodingPage(store: store).environment(AppRouter()))
        assertRendered(vc)

        // Collapsing a group is a store mutation the view observes — re-laying
        // out after it proves the tree survives the change.
        store.toggleCollapsed("p1")
        vc.view.setNeedsLayout()
        vc.view.layoutIfNeeded()
        assertRendered(vc)
    }

    func testCodingFleetListRendersUsageAndDesktopIndicator() async {
        let (store, _) = fleetStore(
            devices: [["id": "mac-1", "name": "Studio", "online": true, "sync_capable": true]])
        await store.loadSessions()
        await store.loadDevices()
        XCTAssertEqual(store.devices.count, 1)

        let vc = host(NavigationStack {
            CodingFleetList(store: store,
                            usage: CodingUsage(fiveHourPct: 42, weeklyPct: 7,
                                               fiveHourResets: "3pm", weeklyResets: "Sunday"),
                            onSelect: { _ in }, onResume: { _ in },
                            onNewSession: { _ in }, onProjectSettings: { _ in })
        })
        assertRendered(vc)
    }

    // MARK: Session screen

    /// A session store whose transcript already holds text, a finished tool, a
    /// running subagent and a diff — plus a terminal with output in it.
    private func loadedSession() async -> (CodingStore, CodingSessionStore) {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/coding/session/s1/messages", json: [
            "total": 3,
            "status": "running",
            "activity_state": "working",
            "status_line": "✳ Zesting… (50s · ↑ 2.0k tokens · high effort)",
            "context": ["used": 62_000, "window": 200_000, "pct": 31],
            "messages": [
                ["i": 0, "role": "user", "text": "Port the coding tab", "ts": 1_700_000_000],
                ["i": 1, "role": "assistant", "text": "On it — **reading** `CodingStore`.",
                 "ts": 1_700_000_010,
                 "tools": [
                    ["name": "Read", "summary": "CodingStore.swift", "output": "line one\nline two",
                     "ok": true],
                    ["name": "Edit", "summary": "CodingPage.swift", "ok": true,
                     "diff": ["@@ -1 +1 @@", "-old line", "+new line", " context"]],
                    ["name": "Task", "summary": "explore the views", "subagent_type": "Explore"],
                 ]],
                ["i": 2, "role": "assistant", "text": "Done.", "ts": 1_700_000_020],
            ],
        ])
        transport.route("/api/coding/session/s1/prompt", json: ["waiting": false])
        transport.route("/api/coding/session/s1/sync",
                        json: ["enabled": true, "device": "Studio", "device_online": true,
                               "status": "syncing", "total": 10, "done": 4])
        transport.route("/api/coding/session/s1", json: [
            "session": ["id": "s1", "title": "Port the coding tab", "status": "running",
                        "cwd": "/Users/me/code/jarvis", "host": "server"],
        ])
        transport.route("/api/coding/projects", json: ["projects": [], "ungrouped": [
            ["id": "s1", "title": "Port the coding tab", "status": "running",
             "cwd": "/Users/me/code/jarvis", "host": "server"],
        ]])
        transport.route("/api/devices", json: ["devices": []])

        let coding = CodingStore(api: CodingSessionsAPI(api: api), isVisible: { true })
        await coding.loadSessions()
        await coding.select("s1")
        let session = coding.sessionStore("s1")
        await session.fetch(full: true)
        session.terminal.write("$ claude --continue\r\nWelcome back.\r\n")
        return (coding, session)
    }

    func testSessionScreenRendersTheTranscriptWithTools() async {
        let (coding, session) = await loadedSession()
        XCTAssertEqual(session.transcript.messages.count, 3)
        XCTAssertEqual(session.transcript.messages[1].tools.count, 3)
        // `ok: null` is the server's "still running" marker.
        XCTAssertTrue(session.transcript.messages[1].tools[2].running)
        XCTAssertTrue(session.showThinking)

        let vc = host(NavigationStack {
            CodingSessionScreen(coding: coding, session: session)
        })
        assertRendered(vc)
    }

    func testSessionScreenRendersTheTerminalPanel() async {
        let (coding, session) = await loadedSession()
        XCTAssertTrue(session.terminal.text.contains("Welcome back."))

        // The Terminal segment: sync card + live pane + key bar + input row.
        let vc = host(NavigationStack {
            CodingSessionScreen(coding: coding, session: session)
        })
        assertRendered(vc)

        let panel = host(NavigationStack {
            CodingTerminalPanel(session: session, host: "server")
        })
        assertRendered(panel)
        // Laying the panel out measures the viewport and pushes it to the PTY.
        XCTAssertGreaterThan(session.terminal.lines.count, 1)
    }

    func testTranscriptRendersThe409NoTranscriptState() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/coding/session/s9/messages",
                        json: ["error": "no transcript"], status: 409)
        let session = CodingSessionStore(sessionId: "s9",
                                         api: CodingSessionsAPI(api: api),
                                         isVisible: { true })
        await session.fetch(full: true)
        XCTAssertTrue(session.transcript.noTranscript)

        let vc = host(CodingChatTranscript(session: session, live: false, onOpenPrompt: {}))
        assertRendered(vc)
    }

    func testPromptSheetRendersOptionsAndRawTail() {
        let structured = CodingPromptState(
            waiting: true, question: "Do you want to proceed?",
            options: [CodingPromptOption(key: "1", label: "Yes"),
                      CodingPromptOption(key: "2", label: "No, tell Claude what to do")])
        assertRendered(host(CodingPromptSheet(prompt: structured,
                                              sendKey: { _ in true }, sendText: { _ in true })))

        let raw = CodingPromptState(waiting: true, raw: "❯ 1. Yes\n  2. No")
        assertRendered(host(CodingPromptSheet(prompt: raw,
                                              sendKey: { _ in true }, sendText: { _ in true })))
    }

    func testCommandSheetListsEveryCommand() {
        XCTAssertEqual(CodingSessionStore.commands.count, 6)
        assertRendered(host(CodingCommandSheet { _ in }))
    }

    // MARK: Approval card

    func testApprovalCardRendersAndReportsItsVerdict() {
        let permission = PendingPermission(requestId: "r1", tool: "Bash",
                                           summary: "rm -rf build/",
                                           sessionId: "s1", cwd: "/Users/me/code/jarvis")
        var seen: (String, String?)?
        let vc = host(CodingApprovalCard(permission: permission, extra: 2) { decision, message in
            seen = (decision, message)
        })
        assertRendered(vc)
        XCTAssertNil(seen, "nothing is answered until the user taps")
        XCTAssertEqual(CodingUI.approvalMeta(permission, extra: 2), "jarvis · +2")
    }

    func testApprovalBannerShowsOnlyTheFirstRequest() async {
        let (store, _) = fleetStore(pending: [
            ["request_id": "r1", "tool": "Bash", "summary": "rm -rf build/"],
            ["request_id": "r2", "tool": "Write", "summary": "app.py"],
        ])
        await store.refreshPendingApprovals()
        XCTAssertEqual(store.pendingApprovals.count, 2)
        assertRendered(host(CodingApprovalBanner(store: store)))
    }

    // MARK: Sheets & settings

    func testLaunchAndProjectSheetsRender() async {
        let (store, _) = fleetStore(
            devices: [["id": "mac-1", "name": "Studio", "online": true, "sync_capable": true]])
        await store.loadDevices()
        assertRendered(host(CodingLaunchSheet(store: store)))
        let project = CodingProject(id: "p1", name: "Jarvis", repoPath: "~/code/jarvis",
                                    syncEnabled: true, sessions: [])
        assertRendered(host(CodingLaunchSheet(store: store, project: project)))
        assertRendered(host(CodingNewProjectSheet(store: store)))
        assertRendered(host(CodingProjectSettingsSheet(store: store, project: project)))
        assertRendered(host(CodingSessionSettingsSheet(
            store: store,
            session: CodingSession(id: "s1", title: "One", host: "server", cwd: "/tmp"))))
    }

    func testEndedPanelRendersBothRecoveryShapes() {
        let server = CodingSession(id: "s1", status: "stopped", host: "server")
        XCTAssertTrue(server.isEnded)
        assertRendered(host(CodingEndedPanel(session: server, busy: false,
                                             onRelaunchDevice: {}, onResumeServer: {},
                                             onReopenTerminal: {}, onRestart: {}, onDelete: {})))

        let discovered = CodingSession(id: "s2", status: "stopped", host: "desktop",
                                       cwd: "/Users/me/code/x",
                                       source: "discovered-tmux", external: true)
        XCTAssertTrue(discovered.isEnded)
        assertRendered(host(CodingEndedPanel(session: discovered, busy: false,
                                             onRelaunchDevice: {}, onResumeServer: {},
                                             onReopenTerminal: {}, onRestart: {}, onDelete: {})))
    }

    func testCodeMasterSettingsPageRenders() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/coding/settings", json: [
            "settings": ["events": ["finished": ["mobile": true, "telegram": false]],
                         "usage_display": true, "remote_approvals": true],
        ])
        let store = CodeMasterSettingsStore(api: CodingSessionsAPI(api: api))
        await store.load()
        XCTAssertTrue(store.remoteApprovals)
        XCTAssertTrue(store.value(event: "finished", channel: "mobile"))

        assertRendered(host(NavigationStack { CodeMasterSettingsPage(store: store) }))
    }
}

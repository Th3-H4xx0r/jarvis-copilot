import Foundation
import SwiftUI
import XCTest
@testable import JarvisCopilot

/// The shared "that refresh failed" banner (silent-failures M3) and the two
/// other affordances that stopped a failure from being invisible.
///
/// Every More page rendered `errorMessage` only when its collection was EMPTY,
/// so a pull-to-refresh that failed with rows on screen changed nothing at all.
/// These assert the store state the pages key off, then host the page in that
/// state so the banner branch is really built.
@MainActor
final class LoadErrorBannerUITests: XCTestCase {

    // MARK: The modifier itself

    func testTheBannerBuildsInEveryCombination() {
        moreUIBHost(Text("rows").loadErrorBanner("Can't reach the server", hasContent: true))
        moreUIBHost(Text("rows").loadErrorBanner("Can't reach the server", hasContent: false))
        moreUIBHost(Text("rows").loadErrorBanner(nil, hasContent: true))
        moreUIBHost(Text("rows").loadErrorBanner("", hasContent: true))
    }

    // MARK: Pages that still have content

    /// The state that used to be silent: a loaded list plus a failed refresh.
    func testTodosKeepsItsRowsAndStillReportsAFailedRefresh() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/sessions", json: ["sessions": [["session_id": "s1",
                                                              "updated_at": 2]]])
        let content = try! JSONSerialization.data(withJSONObject: ["todos": [
            ["id": "1", "content": "ship it", "status": "pending"],
        ]])
        transport.route("/api/session", json: ["session": ["messages": [
            ["role": "tool", "content": String(decoding: content, as: UTF8.self)],
        ]]])
        let store = TodosStore(api: TodosAPI(api: api))
        await store.refresh()
        XCTAssertFalse(store.todos.isEmpty, "the fixture has to load, or this proves nothing")

        moreUIBHost(NavigationStack { TodosPage(store: store) })
        moreUIBHost(NavigationStack { TodosPage(store: store) }
            .loadErrorBanner("Can't reach the server", hasContent: true))
    }

    func testWorkspacesKeepsItsRowsAndStillReportsAFailedRefresh() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/workspaces", json: MoreUIBFixtures.workspaces)
        let store = WorkspacesStore(api: WorkspacesAPI(api: api), sleeper: { _ in })
        await store.refresh()
        XCTAssertFalse(store.workspaces.isEmpty)
        XCTAssertNil(store.errorMessage)

        moreUIBHost(NavigationStack { WorkspacesPage(store: store) }
            .loadErrorBanner("Can't reach the server", hasContent: !store.workspaces.isEmpty))
    }

    // MARK: Insights — an unreachable host says so (M21)

    /// A health fetch that FAILED used to render exactly like a host with no
    /// metrics: the section simply vanished, and the page looked healthy.
    func testInsightsRendersUnavailableWhenTheHealthFetchFailed() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/insights/messages", json: ["messages": []])
        transport.route("/api/insights", json: MoreUIBFixtures.insightsOverview)
        transport.route("/api/system/health", json: ["error": "off"], status: 500)
        transport.route("/api/wiki/status", json: ["available": true, "status": "ok"])
        transport.route("/api/sessions", json: ["sessions": []])

        let store = InsightsStore(api: InsightsAPI(api: api))
        await store.refresh()

        XCTAssertTrue(store.health.failed, "the section renders UNAVAILABLE off this flag")
        XCTAssertFalse(InsightsUI.healthIsAvailable(store.health),
                       "…and it is not renderable as a normal health card")
        XCTAssertFalse(store.overview.isEmpty, "the rest of the page still loaded")
        moreUIBHost(NavigationStack { InsightsPage(store: store) })
    }

    // MARK: Kanban — "updates delayed" (silent-failures L1)

    /// `isPolling` means the live event stream died and the board fell back to a
    /// 30 s poll. Nothing read it before, so "someone else moved this card"
    /// silently took half a minute.
    func testKanbanShowsUpdatesDelayedOncePollingTakesOver() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/kanban/events/stream", json: [:])   // ends immediately
        transport.route("/api/kanban/boards", json: ["boards": []])
        transport.route("/api/kanban/board",
                        json: ["tasks": [["id": "t1", "title": "a", "status": "ready"]]])

        let store = KanbanStore(api: KanbanAPI(api: api), sleeper: { _ in })
        store.onAppear()
        for _ in 0..<40 where !store.isPolling { await Task.yield() }

        XCTAssertTrue(store.isPolling, "the stream ended, so the poll took over")
        moreUIBHost(NavigationStack { KanbanPage(store: store) })
        store.onDisappear()
    }
}

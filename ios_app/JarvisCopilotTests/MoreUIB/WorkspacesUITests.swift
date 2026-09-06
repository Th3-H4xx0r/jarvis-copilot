import SwiftUI
import XCTest
@testable import JarvisCopilot

@MainActor
final class WorkspacesUITests: XCTestCase {

    private func makeStore(_ api: JarvisAPI) -> WorkspacesStore {
        WorkspacesStore(api: WorkspacesAPI(api: api),
                        suggestDebounce: 0, sleeper: instantSleeper)
    }

    private func loadedStore() async -> WorkspacesStore {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/workspaces", json: MoreUIBFixtures.workspaces)
        let store = makeStore(api)
        await store.refresh()
        return store
    }

    func testLastUsedMarksExactlyOneRow() async {
        let store = await loadedStore()
        XCTAssertEqual(store.workspaces.map(\.name), ["Jarvis", "Wearables", "scratch"])
        XCTAssertEqual(store.workspaces.filter(store.isLastUsed).map(\.name), ["Wearables"])
    }

    func testLoadedPageRenders() async {
        let store = await loadedStore()
        XCTAssertNil(store.errorMessage)
        moreUIBHost(NavigationStack { WorkspacesPage(store: store) })
    }

    func testEmptyPageRenders() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/workspaces", json: ["workspaces": [], "last": ""])
        let store = makeStore(api)
        await store.refresh()
        XCTAssertTrue(store.isEmpty)
        moreUIBHost(NavigationStack { WorkspacesPage(store: store) })
    }

    func testErrorPageRenders() async {
        let (api, _) = JarvisAPI.mocked()      // nothing queued → the list fails
        let store = makeStore(api)
        await store.refresh()

        XCTAssertFalse(store.errorMessage?.isEmpty ?? true)
        XCTAssertTrue(store.workspaces.isEmpty)
        XCTAssertFalse(store.isLoading)
        moreUIBHost(NavigationStack { WorkspacesPage(store: store) })
    }

    func testAddSheetRendersWithLiveSuggestions() async {
        let (api, transport) = JarvisAPI.mocked()
        // Substring routing, first match wins: /suggest must precede the prefix
        // that would otherwise swallow it.
        transport.route("/api/workspaces/suggest", json: ["suggestions": ["/a/b", "/a/c"]])
        transport.route("/api/workspaces", json: MoreUIBFixtures.workspaces)
        let store = makeStore(api)
        store.suggest(prefix: "/a")
        await store.waitForSuggestions()
        XCTAssertEqual(store.suggestions, ["/a/b", "/a/c"])
        moreUIBHost(WorkspaceAddSheet(store: store))
    }

    func testRenameSheetRenders() async {
        let store = await loadedStore()
        let workspace = store.workspaces.first ?? Workspace(path: "/p", name: "p")
        moreUIBHost(WorkspaceRenameSheet(store: store, workspace: workspace))
    }
}

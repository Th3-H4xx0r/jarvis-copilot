import SwiftUI
import XCTest
@testable import JarvisCopilot

@MainActor
final class IslandDesignsUITests: XCTestCase {

    private func loadedStore() async -> IslandDesignsStore {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/island/designs", json: MoreUIBFixtures.islandCatalog)
        let store = IslandDesignsStore(api: IslandDesignsAPI(api: api))
        await store.refresh()
        return store
    }

    func testSelectionAndDeletabilityDriveTheRows() async {
        let store = await loadedStore()
        XCTAssertEqual(store.selectedKey, "voice")
        let byID = Dictionary(uniqueKeysWithValues: store.entries.map { ($0.id, $0) })
        let voice = try? XCTUnwrap(byID["voice"])
        XCTAssertEqual(voice?.subtitle, "Built-in · Priority 10")
        XCTAssertEqual(byID["coding"]?.subtitle, "Built-in · Off in Auto · Priority 5")
        // Only custom designs may be deleted.
        XCTAssertFalse(store.canDelete(byID["voice"]!))
        XCTAssertTrue(store.canDelete(byID["meeting"]!))
    }

    func testAutoIsSelectedWhenTheServerSendsNoPin() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/island/designs", json: ["selection": ["mode": "auto"],
                                                      "catalog": [], "designs": []])
        let store = IslandDesignsStore(api: IslandDesignsAPI(api: api))
        await store.refresh()
        XCTAssertEqual(store.selectedKey, IslandDesignsStore.autoKey)
    }

    func testLoadedPageRenders() async {
        let store = await loadedStore()
        XCTAssertNil(store.errorMessage)
        moreUIBHost(NavigationStack { IslandDesignsPage(store: store) })
    }

    func testErrorPageRenders() async {
        let (api, _) = JarvisAPI.mocked()
        let store = IslandDesignsStore(api: IslandDesignsAPI(api: api))
        await store.refresh()

        XCTAssertEqual(store.errorMessage,
                       "Could not load designs. Check the server connection.")
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertFalse(store.isLoading)
        moreUIBHost(NavigationStack { IslandDesignsPage(store: store) })
    }
}

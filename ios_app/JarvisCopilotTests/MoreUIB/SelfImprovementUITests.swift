import SwiftUI
import XCTest
@testable import JarvisCopilot

@MainActor
final class SelfImprovementUITests: XCTestCase {

    private func loadedStore() async -> SelfImprovementStore {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/self-improvement/recent", json: MoreUIBFixtures.selfImprovement)
        let store = SelfImprovementStore(api: SelfImprovementAPI(api: api))
        await store.refresh()
        return store
    }

    func testEventBadgesAndTonesCoverEveryKind() async {
        let store = await loadedStore()
        XCTAssertEqual(store.events.map(\.label), ["LEARNED", "FAILED", "REJECTED"])
        XCTAssertEqual(store.events.map(\.tone), [.success, .danger, .accent])
        // Every event needs a distinct id or the list collapses rows.
        XCTAssertEqual(Set(store.events.map(\.id)).count, store.events.count)
    }

    func testLoadedPageRenders() async {
        let store = await loadedStore()
        XCTAssertNil(store.errorMessage)
        moreUIBHost(NavigationStack { SelfImprovementPage(store: store) })
    }

    func testEmptyPageRenders() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/self-improvement/recent", json: ["entries": []])
        let store = SelfImprovementStore(api: SelfImprovementAPI(api: api))
        await store.refresh()
        XCTAssertTrue(store.isEmpty)
        moreUIBHost(NavigationStack { SelfImprovementPage(store: store) })
    }

    func testErrorPageRenders() async {
        let (api, _) = JarvisAPI.mocked()
        let store = SelfImprovementStore(api: SelfImprovementAPI(api: api))
        await store.refresh()

        XCTAssertFalse(store.errorMessage?.isEmpty ?? true)
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertTrue(store.hasLoaded)
        moreUIBHost(NavigationStack { SelfImprovementPage(store: store) })
    }
}

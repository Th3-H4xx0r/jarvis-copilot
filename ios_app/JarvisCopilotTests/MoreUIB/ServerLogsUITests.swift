import SwiftUI
import XCTest
@testable import JarvisCopilot

@MainActor
final class ServerLogsUITests: XCTestCase {

    private func makeStore(_ api: JarvisAPI) -> ServerLogsStore {
        ServerLogsStore(api: ServerLogsAPI(api: api),
                        refreshInterval: 0.001, sleeper: instantSleeper)
    }

    private func loadedStore() async -> ServerLogsStore {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/logs", json: MoreUIBFixtures.logs)
        let store = makeStore(api)
        await store.refresh()
        return store
    }

    func testLinesRenderNewestFirstAndCarryTheirSeverity() async {
        let store = await loadedStore()
        XCTAssertEqual(store.displayLines.first, "Traceback (most recent call last):")
        XCTAssertEqual(store.severity(of: store.displayLines[0]), .error)
        XCTAssertEqual(store.severity(of: "2026-06-21 09:30:02 WARNING slow reply"), .warn)
        XCTAssertEqual(store.severity(of: "2026-06-21 09:30:00 INFO  started"), .info)
    }

    func testSeverityFilterNarrowsTheListAndTheCopyPayload() async {
        let store = await loadedStore()
        XCTAssertEqual(store.countLabel, "4 of 4 lines")
        store.filter = .errors
        XCTAssertEqual(store.filteredLines.count, 2)
        XCTAssertEqual(store.countLabel, "2 of 4 lines")
        XCTAssertFalse(store.copyText.contains("INFO"))
    }

    func testFooterMetadataIsHumanReadable() async {
        let store = await loadedStore()
        XCTAssertEqual(store.tail.sizeLabel, "2.3 MB")
        XCTAssertTrue(store.tail.truncated)
        XCTAssertFalse(store.tail.mtimeLabel(now: Date(timeIntervalSince1970: 1_781_000_300)).isEmpty)
    }

    func testLoadedPageRenders() async {
        let store = await loadedStore()
        XCTAssertNil(store.errorMessage)
        moreUIBHost(NavigationStack { ServerLogsPage(store: store) })
    }

    func testUnwrappedPageRendersInsideItsHorizontalScroller() async {
        let store = await loadedStore()
        store.wrapLines = false
        moreUIBHost(NavigationStack { ServerLogsPage(store: store) })
    }

    func testEmptyPageRendersTheServerHint() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/logs", json: ["lines": [], "hint": "Nothing logged yet."])
        let store = makeStore(api)
        await store.refresh()
        XCTAssertTrue(store.isEmpty)
        moreUIBHost(NavigationStack { ServerLogsPage(store: store) })
    }

    func testErrorPageRenders() async {
        let (api, _) = JarvisAPI.mocked()
        let store = makeStore(api)
        await store.refresh()

        XCTAssertFalse(store.errorMessage?.isEmpty ?? true)
        XCTAssertTrue(store.tail.lines.isEmpty)
        XCTAssertTrue(store.hasLoaded)
        moreUIBHost(NavigationStack { ServerLogsPage(store: store) })
    }
}

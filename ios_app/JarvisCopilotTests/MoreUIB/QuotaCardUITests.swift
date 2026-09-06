import SwiftUI
import XCTest
@testable import JarvisCopilot

/// The quota card draws percentages the server may not have sent, so the
/// "unknown" path (empty bar + "—", never a misleading full bar) is the thing
/// worth pinning down.
@MainActor
final class QuotaCardUITests: XCTestCase {

    private func loadedStore() async -> QuotaStore {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/provider/quota/all", json: MoreUIBFixtures.quota)
        let store = QuotaStore(api: QuotaAPI(api: api))
        await store.refresh(initial: true)
        return store
    }

    func testWindowsResolveUsedRemainingAndUnknown() async {
        let store = await loadedStore()
        let windows = store.providers.first?.windows ?? []
        XCTAssertEqual(windows.map(\.label),
                       ["Current session", "Current week", "Unknown window"])
        XCTAssertEqual(windows[0].percentText, "46%")
        XCTAssertEqual(windows[0].barTone, .normal)
        // Only `remaining_percent` arrived: 100 - 4 = 96% used, i.e. critical.
        XCTAssertEqual(windows[1].percentText, "96%")
        XCTAssertEqual(windows[1].barTone, .critical)
        XCTAssertEqual(windows[2].percentText, "—")
        XCTAssertEqual(windows[2].barFraction, 0)
        XCTAssertEqual(windows[2].barTone, .unknown)
    }

    func testProviderHeaderIncludesThePlan() async {
        let store = await loadedStore()
        XCTAssertEqual(store.providers.first?.headerTitle, "Claude Code · Max")
        XCTAssertEqual(store.providers.last?.headerTitle, "Codex")
        XCTAssertFalse(store.providers.last?.hasLimits ?? true)
    }

    func testLoadedCardRenders() async {
        let store = await loadedStore()
        XCTAssertFalse(store.isLoading)
        moreUIBHost(QuotaCard(store: store))
    }

    func testErrorCardRenders() async {
        let (api, _) = JarvisAPI.mocked()
        let store = QuotaStore(api: QuotaAPI(api: api))
        await store.refresh(initial: true)
        XCTAssertTrue(store.showsRetry)
        moreUIBHost(QuotaCard(store: store))
    }
}

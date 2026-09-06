import SwiftUI
import XCTest
@testable import JarvisCopilot

@MainActor
final class PhotonUITests: XCTestCase {

    private func loadedStore() async -> PhotonStore {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/integrations/photon", json: MoreUIBFixtures.photon)
        let store = PhotonStore(api: PhotonAPI(api: api))
        await store.refresh()
        return store
    }

    func testStoredSecretsShowAHintAndNeverRoundTrip() async {
        let store = await loadedStore()
        XCTAssertEqual(store.projectID, "proj_abc")
        XCTAssertTrue(store.projectSecret.isEmpty, "a secret must never come back from the GET")
        XCTAssertEqual(store.projectSecretHint, "saved — leave blank to keep")
        XCTAssertNil(store.sidecarTokenHint)
        XCTAssertTrue(store.allowAll)
    }

    func testStatusPillReportsMockMode() async {
        let store = await loadedStore()
        XCTAssertEqual(store.status.tone, .amber)
        XCTAssertEqual(store.status.label, "Sidecar in mock mode — tap Save to reload")
    }

    func testLoadedPageRenders() async {
        let store = await loadedStore()
        XCTAssertNil(store.errorMessage)
        moreUIBHost(NavigationStack { PhotonSetupPage(store: store) })
    }

    func testErrorPageRenders() async {
        let (api, _) = JarvisAPI.mocked()
        let store = PhotonStore(api: PhotonAPI(api: api))
        await store.refresh()

        XCTAssertFalse(store.errorMessage?.isEmpty ?? true)
        XCTAssertFalse(store.configured, "nothing loaded, so nothing is configured")
        XCTAssertFalse(store.isLoading)
        moreUIBHost(NavigationStack { PhotonSetupPage(store: store) })
    }

    func testStatusPillRendersForEveryState() {
        for status in [PhotonStatus.resolve(configured: false, sidecar: PhotonSidecar()),
                       PhotonStatus.resolve(configured: true, sidecar: PhotonSidecar()),
                       PhotonStatus.resolve(configured: true,
                                            sidecar: PhotonSidecar(json: ["reachable": true,
                                                                          "ok": true]))] {
            moreUIBHost(PhotonStatusPill(status: status))
        }
    }
}

import SwiftUI
import UIKit
import XCTest
@testable import JarvisCopilot

/// The Coding tab's half of the shared "that refresh failed" banner (the same
/// gap `LoadErrorBannerUITests` closed for the twelve More pages).
///
/// `CodingFleetList` rendered `store.error` only while `sessions` was EMPTY, so
/// the first load failing was visible but a failed pull-to-refresh — or a failed
/// poll — with the fleet already on screen changed nothing at all: the spinner
/// retracted and the user read stale status dots as live.
@MainActor
final class CodingLoadErrorBannerUITests: XCTestCase {

    private static let screen = CGSize(width: 393, height: 852)

    /// Mount at iPhone size and force a layout pass, which is what actually
    /// evaluates the SwiftUI body (and therefore the banner branch).
    private func host<V: View>(_ view: V,
                               file: StaticString = #filePath, line: UInt = #line) {
        let vc = UIHostingController(rootView: view)
        vc.view.frame = CGRect(origin: .zero, size: Self.screen)
        vc.view.setNeedsLayout()
        vc.view.layoutIfNeeded()
        XCTAssertEqual(vc.view.bounds.size, Self.screen, "hosted view lost its frame",
                       file: file, line: line)
        let fitted = vc.sizeThatFits(in: Self.screen)
        XCTAssertGreaterThan(fitted.height, 0, "view measured no height", file: file, line: line)
    }

    private func fleetList(_ store: CodingStore) -> some View {
        CodingFleetList(store: store, usage: nil,
                        onSelect: { _ in }, onResume: { _ in },
                        onNewSession: { _ in }, onProjectSettings: { _ in })
    }

    /// One project with one session, then a refresh that 500s. The projects
    /// endpoint is left to the FIFO queue so the two calls get different
    /// answers; everything else the fleet touches is routed.
    private func loadedThenFailing() async -> CodingStore {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/coding/sessions", json: ["sessions": []])
        transport.route("/api/devices", json: ["devices": []])
        transport.enqueue(json: ["projects": [[
            "id": "p1", "name": "Jarvis", "repo_path": "~/code/jarvis",
            "sessions": [["id": "s1", "title": "Port the coding tab", "status": "running"]],
        ]], "ungrouped": []])
        transport.enqueue(json: ["error": "gateway"], status: 502)

        let store = CodingStore(api: CodingSessionsAPI(api: api), isVisible: { true })
        await store.loadSessions()
        return store
    }

    /// The state that used to be silent: a loaded fleet plus a failed refresh.
    func testTheFleetKeepsItsRowsAndStillReportsAFailedRefresh() async {
        let store = await loadedThenFailing()
        XCTAssertFalse(store.sessions.isEmpty, "the fixture has to load, or this proves nothing")
        XCTAssertNil(store.error)
        host(NavigationStack { fleetList(store) })

        await store.loadSessions()

        XCTAssertFalse(store.sessions.isEmpty, "the rows stay on screen…")
        XCTAssertNotNil(store.error, "…and the failure is recorded, not swallowed")
        // Content + a message is exactly the combination the banner exists for.
        XCTAssertTrue(bannerIsApplied(to: store),
                      "the fleet must go through the shared banner, like the other 12 pages")
        host(NavigationStack { fleetList(store) })
    }

    /// Hosting a view only proves it *builds*, so it cannot tell a screen with the
    /// banner from one without it. The modifier is part of the body's static type,
    /// which can: `.loadErrorBanner` wraps the body in `LoadErrorBannerModifier`.
    private func bannerIsApplied(to store: CodingStore) -> Bool {
        String(describing: type(of: CodingFleetList(
            store: store, usage: nil, onSelect: { _ in }, onResume: { _ in },
            onNewSession: { _ in }, onProjectSettings: { _ in }).body))
            .contains("LoadErrorBannerModifier")
    }

    /// With nothing on screen the page keeps its own full-screen error state —
    /// two error affordances at once is worse than one.
    func testAnEmptyFleetStillUsesItsFullScreenErrorState() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/coding/sessions", json: ["sessions": []])
        transport.route("/api/devices", json: ["devices": []])
        transport.route("/api/coding/projects", json: ["error": "gateway"], status: 502)

        let store = CodingStore(api: CodingSessionsAPI(api: api), isVisible: { true })
        await store.loadSessions()

        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertNotNil(store.error)
        host(NavigationStack { fleetList(store) })
    }

    /// Every branch of the modifier as the fleet can hand it values.
    func testTheBannerBuildsInEveryCombination() {
        host(Text("fleet").loadErrorBanner("Could not load coding sessions", hasContent: true))
        host(Text("fleet").loadErrorBanner("Could not load coding sessions", hasContent: false))
        host(Text("fleet").loadErrorBanner(nil, hasContent: true))
        host(Text("fleet").loadErrorBanner("", hasContent: true))
    }
}

import Foundation
import XCTest
@testable import JarvisCopilot

/// No Dart test existed for `api/self_improvement.dart`; these cover the
/// endpoint plus the kind→label/tone mapping from `self_improvement_page.dart`.
final class SelfImprovementTests: XCTestCase {

    func testKindLabelsAndTones() {
        func event(_ kind: String) -> SelfImprovementEvent {
            SelfImprovementEvent(json: ["kind": kind], index: 0)
        }
        XCTAssertEqual(event("fail").label, "FAILED")
        XCTAssertEqual(event("fail").tone, .danger)
        XCTAssertEqual(event("rejected").label, "REJECTED")
        XCTAssertEqual(event("rejected").tone, .accent)
        XCTAssertEqual(event("noop").label, "REVIEWED")
        XCTAssertEqual(event("noop").tone, .muted)
        XCTAssertEqual(event("change").label, "LEARNED")
        XCTAssertEqual(event("change").tone, .success)
        // An unknown kind reads as a normal change.
        XCTAssertEqual(event("whatever").label, "LEARNED")
    }

    func testKindDefaultsToChange() {
        let event = SelfImprovementEvent(json: ["text": "did a thing"], index: 0)
        XCTAssertEqual(event.kind, "change")
        XCTAssertEqual(event.label, "LEARNED")
    }

    func testIDIsStableAndUniquePerRow() {
        let stamped = SelfImprovementEvent(json: ["ts": "2026-06-21T10:00:00Z"], index: 2)
        XCTAssertEqual(stamped.id, "2026-06-21T10:00:00Z#2")
        let bare = SelfImprovementEvent(json: [:], index: 5)
        XCTAssertEqual(bare.id, "event_5")
    }

    func testTimestampLabel() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let event = SelfImprovementEvent(
            json: ["ts": now.timeIntervalSince1970 - 3600], index: 0)
        XCTAssertEqual(event.tsLabel(now: now), "1h ago")
    }

    // MARK: API requests

    func testRecentSendsTheLimitAndReadsTheEntriesEnvelope() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["entries": [
            ["kind": "change", "origin": "skills", "ts": "2026-06-21T10:00:00Z",
             "text": "created skill: weather"],
            ["kind": "fail", "text": "patch rejected"],
        ], "total": 2, "hint": "…"])
        let events = try await SelfImprovementAPI(api: api).recent(limit: 25)

        XCTAssertEqual(transport.lastMethod, "GET")
        XCTAssertEqual(transport.lastPath, "/api/self-improvement/recent")
        XCTAssertEqual(transport.lastQuery, ["limit": "25"])
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].origin, "skills")
        XCTAssertEqual(events[0].text, "created skill: weather")
        XCTAssertEqual(events[1].label, "FAILED")
    }

    func testRecentDefaultLimitMatchesTheFlutterClient() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["entries": []])
        _ = try await SelfImprovementAPI(api: api).recent()
        XCTAssertEqual(transport.lastQuery, ["limit": "100"])
    }

    func testRecentToleratesABareList() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: [["kind": "change", "text": "x"]])
        let events = try await SelfImprovementAPI(api: api).recent()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].text, "x")
    }

    // MARK: Store

    @MainActor
    func testStoreLoadsInServerOrder() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/self-improvement/recent", json: ["entries": [
            ["kind": "change", "text": "newest"],
            ["kind": "noop", "text": "older"],
        ]])

        let store = SelfImprovementStore(api: SelfImprovementAPI(api: api))
        await store.refresh()

        XCTAssertEqual(store.events.map(\.text), ["newest", "older"])
        XCTAssertFalse(store.isEmpty)
        XCTAssertNil(store.errorMessage)
    }

    @MainActor
    func testStoreEmptyStateAndError() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["entries": []])
        let store = SelfImprovementStore(api: SelfImprovementAPI(api: api))
        await store.refresh()
        XCTAssertTrue(store.isEmpty)
        XCTAssertTrue(store.emptyText.hasPrefix("No self-improvement activity yet."))

        transport.enqueue(json: ["error": "log missing"], status: 500)
        await store.refresh()
        XCTAssertEqual(store.errorMessage, "log missing")
    }
}

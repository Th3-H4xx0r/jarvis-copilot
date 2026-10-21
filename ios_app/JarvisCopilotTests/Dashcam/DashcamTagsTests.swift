import XCTest
@testable import JarvisCopilot

/// Tags he puts on clips by hand: what the server sends, toggling one, tagging several clips at once.
final class DashcamTagsTests: XCTestCase {
    private func clip(_ id: String, tags: [String] = []) -> DashcamServerClip {
        DashcamServerClip(json: ["id": id, "path": "/sd/\(id).ts", "start": "2026-10-21T21:17:37Z", "tags": tags])!
    }

    func testClipsCarryTheirTags() throws {
        XCTAssertEqual(clip("a", tags: ["accident", "scenic"]).tags, ["accident", "scenic"])
        XCTAssertEqual(try XCTUnwrap(DashcamServerClip(json: ["id": "b", "path": "/sd/b.ts"])).tags, [], "none → empty")
        let tag = try XCTUnwrap(DashcamTag(json: ["id": "pothole", "name": "Pothole", "preset": false]))
        XCTAssertEqual(tag, DashcamTag(id: "pothole", name: "Pothole", preset: false))
        XCTAssertNil(DashcamTag(json: ["name": "No id"]))
    }

    func testTogglingATag() {
        XCTAssertEqual(DashcamTagging.toggled(["accident"], "scenic"), ["accident", "scenic"])
        XCTAssertEqual(DashcamTagging.toggled(["accident", "scenic"], "accident"), ["scenic"])
    }

    /// Several clips selected: the tag goes on all of them, unless every one already has it — then it comes off.
    func testBulkAddsUnlessEveryClipHasIt() {
        let mixed = DashcamTagging.bulk("accident", on: [clip("a", tags: ["accident"]), clip("b"), clip("c", tags: ["scenic"])])
        XCTAssertTrue(mixed.add)
        XCTAssertEqual(mixed.changes.map(\.clipID), ["b", "c"], "a already has it")
        XCTAssertEqual(mixed.changes.map(\.tags), [["accident"], ["scenic", "accident"]])
        let all = DashcamTagging.bulk("accident", on: [clip("a", tags: ["accident"]), clip("b", tags: ["accident", "scenic"])])
        XCTAssertFalse(all.add)
        XCTAssertEqual(all.changes.map(\.tags), [[], ["scenic"]])
    }

    func testTheFilterAsksForTheTag() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["clips": [["id": "a", "path": "/sd/a.ts", "tags": ["near_miss"]]], "next": NSNull()])
        let page = try await DashcamAPI(api: api).clips(DashcamAPI.ClipFilter(tag: "near_miss"))
        XCTAssertEqual(page.clips.first?.tags, ["near_miss"])
        XCTAssertTrue(transport.requests.last?.url?.query?.contains("tag=near_miss") == true)
    }

    func testSettingTagsPostsThemAndReadsBothClips() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["ok": true, "clips": [["id": "f", "path": "/sd/f.ts", "tags": ["accident"]],
                                                       ["id": "r", "path": "/sd/r.ts", "tags": ["accident"]]]])
        let clips = try await DashcamAPI(api: api).setTags(clipID: "f", ["accident"])
        XCTAssertEqual(clips.map(\.id), ["f", "r"])
        let request = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(request.url?.path, "/api/dashcam/clips/f/tags")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        XCTAssertEqual(body["tags"] as? [String], ["accident"])
    }

    func testTheTagCatalogAndNewTags() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["tags": [["id": "accident", "name": "Accident", "preset": true]]])
        transport.enqueue(json: ["ok": true, "tag": ["id": "pothole", "name": "Pothole", "preset": false]])
        let dashcam = DashcamAPI(api: api)
        let tags = try await dashcam.tags()
        let made = try await dashcam.addTag("Pothole")
        XCTAssertEqual(tags.map(\.name), ["Accident"])
        XCTAssertEqual(made.id, "pothole")
    }

    /// Clips he tagged stay on the phone after their upload: the phone remembers which clips carry tags.
    func testTheTaggedListFollowsWhatTheServerSays() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DashcamTagsTests-\(UUID().uuidString)"))
        DashcamTagged.update([clip("a", tags: ["accident"]), clip("b")], defaults: defaults)
        XCTAssertTrue(DashcamTagged.contains("a", defaults: defaults))
        XCTAssertFalse(DashcamTagged.contains("b", defaults: defaults))
        DashcamTagged.update([clip("a")], defaults: defaults)
        XCTAssertFalse(DashcamTagged.contains("a", defaults: defaults), "untagged again")
    }
}

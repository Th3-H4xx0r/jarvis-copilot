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

    /// A tap sends the change, not the whole list: two quick taps can't undo each other.
    func testAChangePostsWhatToAddAndRemoveAndReadsBothClips() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["ok": true, "clips": [["id": "f", "path": "/sd/f.ts", "tags": ["accident"]],
                                                       ["id": "r", "path": "/sd/r.ts", "tags": ["accident"]]]])
        let clips = try await DashcamAPI(api: api).changeTags(clipID: "f", add: ["accident"], remove: ["scenic"])
        XCTAssertEqual(clips.map(\.id), ["f", "r"])
        let request = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(request.url?.path, "/api/dashcam/clips/f/tags")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        XCTAssertEqual(body["add"] as? [String], ["accident"])
        XCTAssertEqual(body["remove"] as? [String], ["scenic"])
        XCTAssertNil(body["tags"])
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
    /// A tag change is the truth for its clips; a listing only ever adds (it may be older than a tap).
    func testTheTaggedListFollowsChangesAndListingsOnlyAdd() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DashcamTagsTests-\(UUID().uuidString)"))
        DashcamTagged.update([clip("a", tags: ["accident"]), clip("b")], defaults: defaults)
        XCTAssertTrue(DashcamTagged.contains("a", defaults: defaults))
        XCTAssertFalse(DashcamTagged.contains("b", defaults: defaults))
        DashcamTagged.mark("b", defaults: defaults)                 // tapped: kept even before the server answers
        DashcamTagged.learn([clip("b"), clip("c", tags: ["scenic"])], defaults: defaults)
        XCTAssertTrue(DashcamTagged.contains("b", defaults: defaults), "an older listing doesn't untag it")
        XCTAssertTrue(DashcamTagged.contains("c", defaults: defaults))
        DashcamTagged.update([clip("a")], defaults: defaults)
        XCTAssertFalse(DashcamTagged.contains("a", defaults: defaults), "untagged again")
    }

    /// Tag on several selected clips with the server down: it stops at the first failure, not one
    /// timeout per clip.
    @MainActor
    func testBulkTaggingStopsAtTheFirstFailure() async {
        let (api, transport) = JarvisAPI.mocked()
        let store = DashcamTagStore.shared
        let saved = store.api
        defer { store.api = saved }
        store.api = DashcamAPI(api: api)
        let model = DashcamLibraryModel()
        model.api = DashcamAPI(api: api)
        transport.enqueue(json: ["clips": (0..<5).map { ["id": "c\($0)", "path": "/sd/c\($0).ts", "start": "2026-10-21T21:1\($0):00Z"] },
                                 "next": NSNull()])
        await model.reload()
        model.selected = Set(model.clips.map(\.id))
        transport.enqueue(MockTransport.Reply(status: 502, body: Data("down".utf8)))
        let note = await model.tagSelected("accident")
        XCTAssertEqual(transport.requests.count, 2, "the page, then one try")
        XCTAssertEqual(note, "5 clips couldn't be tagged. Try again.")
    }
}

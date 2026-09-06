import Foundation
import XCTest
@testable import JarvisCopilot

/// Ported from `mobile_client/test/workspaces_test.dart`, case for case, plus
/// the endpoint and store behaviour from `workspaces_page.dart`.
final class WorkspacesTests: XCTestCase {

    // MARK: parseWorkspaceList

    func testObjectEntriesKeepPathAndNameAndCarryLastThrough() {
        let out = parseWorkspaceList([
            "workspaces": [
                ["path": "/Users/me/code/alpha", "name": "Alpha"],
                ["path": "/Users/me/code/beta", "name": "Beta"],
            ],
            "last": "/Users/me/code/beta",
        ] as JSONObject)
        XCTAssertEqual(out.workspaces.count, 2)
        XCTAssertEqual(out.workspaces[0].path, "/Users/me/code/alpha")
        XCTAssertEqual(out.workspaces[0].name, "Alpha")
        XCTAssertEqual(out.workspaces[1].name, "Beta")
        XCTAssertEqual(out.last, "/Users/me/code/beta")
    }

    func testOrderIsPreserved() {
        let out = parseWorkspaceList([
            "workspaces": [
                ["path": "/a", "name": "A"],
                ["path": "/b", "name": "B"],
                ["path": "/c", "name": "C"],
            ],
            "last": "",
        ] as JSONObject)
        XCTAssertEqual(out.workspaces.map(\.path), ["/a", "/b", "/c"])
    }

    func testBareStringEntriesDeriveANameFromTheLastPathSegment() {
        let out = parseWorkspaceList([
            "workspaces": ["/Users/me/code/gamma", "/srv/"],
            "last": "/Users/me/code/gamma",
        ] as JSONObject)
        XCTAssertEqual(out.workspaces.count, 2)
        XCTAssertEqual(out.workspaces[0].path, "/Users/me/code/gamma")
        XCTAssertEqual(out.workspaces[0].name, "gamma")
        // A trailing slash is trimmed before taking the basename.
        XCTAssertEqual(out.workspaces[1].name, "srv")
    }

    func testEntryMissingANameFallsBackToTheBasename() {
        let out = parseWorkspaceList([
            "workspaces": [["path": "/Users/me/code/delta"]],
            "last": "",
        ] as JSONObject)
        XCTAssertEqual(out.workspaces.count, 1)
        XCTAssertEqual(out.workspaces[0].name, "delta")
    }

    func testEntriesWithEmptyPathsAreDropped() {
        let out = parseWorkspaceList([
            "workspaces": [
                ["path": "", "name": "Ghost"],
                ["path": "/real", "name": "Real"],
            ],
            "last": "",
        ] as JSONObject)
        XCTAssertEqual(out.workspaces.count, 1)
        XCTAssertEqual(out.workspaces[0].path, "/real")
    }

    func testEmptyMapGivesEmptyListAndEmptyLast() {
        let out = parseWorkspaceList(JSONObject())
        XCTAssertTrue(out.workspaces.isEmpty)
        XCTAssertEqual(out.last, "")
    }

    func testMissingWorkspacesKeyGivesEmptyList() {
        let out = parseWorkspaceList(["last": "/somewhere"] as JSONObject)
        XCTAssertTrue(out.workspaces.isEmpty)
        XCTAssertEqual(out.last, "/somewhere")
    }

    func testNilInputGivesEmptyListAndEmptyLast() {
        let out = parseWorkspaceList(nil)
        XCTAssertTrue(out.workspaces.isEmpty)
        XCTAssertEqual(out.last, "")
    }

    func testNonMapInputGivesEmptyListAndEmptyLast() {
        let out = parseWorkspaceList([1, 2, 3])
        XCTAssertTrue(out.workspaces.isEmpty)
        XCTAssertEqual(out.last, "")
    }

    func testNonListWorkspacesValueGivesEmptyList() {
        let out = parseWorkspaceList(["workspaces": "oops", "last": ""] as JSONObject)
        XCTAssertTrue(out.workspaces.isEmpty)
    }

    func testMissingLastGivesEmptyStringNotNil() {
        let out = parseWorkspaceList(["workspaces": [["path": "/x", "name": "X"]]] as JSONObject)
        XCTAssertEqual(out.last, "")
    }

    // MARK: basename

    func testBasenameEdgeCases() {
        XCTAssertEqual(Workspace.basename("/a/b/c"), "c")
        XCTAssertEqual(Workspace.basename("/a/b/c///"), "c")
        XCTAssertEqual(Workspace.basename("noslash"), "noslash")
        XCTAssertEqual(Workspace.basename("/"), "/")
    }

    // MARK: API requests

    func testListHitsApiWorkspaces() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["workspaces": [["path": "/a", "name": "A"]], "last": "/a"])
        let list = try await WorkspacesAPI(api: api).list()

        XCTAssertEqual(transport.lastMethod, "GET")
        XCTAssertEqual(transport.lastPath, "/api/workspaces")
        XCTAssertEqual(transport.lastQuery, [:])
        XCTAssertEqual(list.workspaces.map(\.name), ["A"])
        XCTAssertEqual(list.last, "/a")
    }

    func testSuggestSendsThePrefix() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["suggestions": ["/Users/me/code", "/Users/me/docs"]])
        let hits = try await WorkspacesAPI(api: api).suggest("/Users/me/")

        XCTAssertEqual(transport.lastMethod, "GET")
        XCTAssertEqual(transport.lastPath, "/api/workspaces/suggest")
        XCTAssertEqual(transport.lastQuery, ["prefix": "/Users/me/"])
        XCTAssertEqual(hits, ["/Users/me/code", "/Users/me/docs"])
    }

    func testSuggestToleratesAMissingSuggestionsKey() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["other": 1])
        let hits = try await WorkspacesAPI(api: api).suggest("/x")
        XCTAssertTrue(hits.isEmpty)
    }

    func testAddRemoveRenameAndReorderBodies() async throws {
        let (api, transport) = JarvisAPI.mocked()

        transport.enqueue(json: ["ok": true])
        try await WorkspacesAPI(api: api).add("/new")
        XCTAssertEqual(transport.lastMethod, "POST")
        XCTAssertEqual(transport.lastPath, "/api/workspaces/add")
        assertJSONEqual(transport.lastBody(), ["path": "/new"])

        transport.enqueue(json: ["ok": true])
        try await WorkspacesAPI(api: api).remove("/old")
        XCTAssertEqual(transport.lastPath, "/api/workspaces/remove")
        assertJSONEqual(transport.lastBody(), ["path": "/old"])

        transport.enqueue(json: ["ok": true])
        try await WorkspacesAPI(api: api).rename("/a", name: "Alpha")
        XCTAssertEqual(transport.lastPath, "/api/workspaces/rename")
        assertJSONEqual(transport.lastBody(), ["path": "/a", "name": "Alpha"])

        transport.enqueue(json: ["ok": true])
        try await WorkspacesAPI(api: api).reorder(["/b", "/a"])
        XCTAssertEqual(transport.lastPath, "/api/workspaces/reorder")
        assertJSONEqual(transport.lastBody(), ["paths": ["/b", "/a"]])
    }

    // MARK: Store

    @MainActor
    private func loadedStore(_ api: JarvisAPI, _ transport: MockTransport) async -> WorkspacesStore {
        let store = WorkspacesStore(api: WorkspacesAPI(api: api), sleeper: instantSleeper)
        await store.refresh()
        return store
    }

    @MainActor
    func testStoreExposesLastUsed() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/workspaces", json: [
            "workspaces": [["path": "/a", "name": "A"], ["path": "/b", "name": "B"]],
            "last": "/b",
        ])
        let store = await loadedStore(api, transport)

        XCTAssertEqual(store.workspaces.count, 2)
        XCTAssertFalse(store.isLastUsed(store.workspaces[0]))
        XCTAssertTrue(store.isLastUsed(store.workspaces[1]))
        XCTAssertFalse(store.isEmpty)
    }

    @MainActor
    func testStoreAddRejectsABlankPathWithoutARequest() async {
        let (api, transport) = JarvisAPI.mocked()
        let store = WorkspacesStore(api: WorkspacesAPI(api: api), sleeper: instantSleeper)
        let ok = await store.add(path: "   ")
        XCTAssertFalse(ok)
        XCTAssertEqual(store.toast, "Enter a folder path")
        XCTAssertTrue(transport.requests.isEmpty)
    }

    @MainActor
    func testStoreRenameRejectsABlankName() async {
        let (api, transport) = JarvisAPI.mocked()
        let store = WorkspacesStore(api: WorkspacesAPI(api: api), sleeper: instantSleeper)
        let ok = await store.rename(Workspace(path: "/a", name: "A"), to: " ")
        XCTAssertFalse(ok)
        XCTAssertEqual(store.toast, "Enter a name")
        XCTAssertTrue(transport.requests.isEmpty)
    }

    @MainActor
    func testStoreAddTrimsThenReloads() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/workspaces/add", json: ["ok": true])
        transport.route("/api/workspaces", json: ["workspaces": [["path": "/new"]], "last": ""])

        let store = WorkspacesStore(api: WorkspacesAPI(api: api), sleeper: instantSleeper)
        let ok = await store.add(path: "  /new  ")

        XCTAssertTrue(ok)
        assertJSONEqual(transport.body(0), ["path": "/new"])
        XCTAssertEqual(transport.path(1), "/api/workspaces")
        XCTAssertEqual(store.workspaces.map(\.path), ["/new"])
    }

    @MainActor
    func testStoreMoveAppliesOptimisticallyThenPersistsAndReconciles() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/workspaces/reorder", json: ["ok": true])
        transport.route("/api/workspaces", json: [
            "workspaces": [["path": "/b", "name": "B"], ["path": "/a", "name": "A"]],
            "last": "/a",
        ])

        let store = WorkspacesStore(api: WorkspacesAPI(api: api), sleeper: instantSleeper)
        await store.refresh()
        // The server currently answers B,A — pretend the user dragged A up.
        await store.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)

        let reorder = transport.requests.first { $0.url?.path == "/api/workspaces/reorder" }
        XCTAssertNotNil(reorder)
        let body = (try? JSONSerialization.jsonObject(with: reorder!.httpBody ?? Data()))
            as? JSONObject ?? [:]
        XCTAssertEqual(body["paths"] as? [String], ["/a", "/b"])
        // Reconciled back to the server's authoritative order.
        XCTAssertEqual(store.workspaces.map(\.path), ["/b", "/a"])
    }

    @MainActor
    func testStoreMoveSurfacesAFailureButStillReconciles() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/workspaces/reorder", json: ["error": "locked"], status: 500)
        transport.route("/api/workspaces", json: [
            "workspaces": [["path": "/a"], ["path": "/b"]], "last": "",
        ])

        let store = WorkspacesStore(api: WorkspacesAPI(api: api), sleeper: instantSleeper)
        await store.refresh()
        await store.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)

        XCTAssertEqual(store.toast, "locked")
        XCTAssertEqual(store.workspaces.map(\.path), ["/a", "/b"])
    }

    @MainActor
    func testStoreSuggestIsDebouncedAndABlankPrefixSkipsTheRequest() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/workspaces/suggest", json: ["suggestions": ["/Users/me/code"]])

        let store = WorkspacesStore(api: WorkspacesAPI(api: api), sleeper: instantSleeper)
        store.suggest(prefix: "  ")
        await store.waitForSuggestions()
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertTrue(store.suggestions.isEmpty)

        store.suggest(prefix: "/U")
        store.suggest(prefix: "/Us")
        store.suggest(prefix: "/Users")
        await store.waitForSuggestions()

        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.lastQuery, ["prefix": "/Users"])
        XCTAssertEqual(store.suggestions, ["/Users/me/code"])

        store.clearSuggestions()
        XCTAssertTrue(store.suggestions.isEmpty)
    }
}

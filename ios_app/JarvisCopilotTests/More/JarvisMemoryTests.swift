import Foundation
import XCTest
@testable import JarvisCopilot

/// Ported from `mobile_client/test/jarvis_memory_test.dart`, case for case.
final class JarvisMemoryTests: XCTestCase {

    // MARK: parseNamespaces

    func testRealStatsShape() {
        let out = JarvisMemoryParse.namespaces([
            "available": true,
            "count": 7,
            "namespaces": [
                ["namespace": "global", "count": 5],
                ["namespace": "work", "count": 2],
            ],
        ] as JSONObject)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].namespace, "global")
        XCTAssertEqual(out[0].count, 5)
        XCTAssertEqual(out[1].namespace, "work")
        XCTAssertEqual(out[1].count, 2)
    }

    func testBareListOfNamespaceMapsIsAccepted() {
        let out = JarvisMemoryParse.namespaces([
            ["namespace": "a", "count": 1],
            ["namespace": "b", "count": 3],
        ])
        XCTAssertEqual(out.map(\.namespace), ["a", "b"])
        XCTAssertEqual(out.map(\.count), [1, 3])
    }

    func testCountCoercesNumericStringsAndDefaultsMissingToZero() {
        let out = JarvisMemoryParse.namespaces([
            "namespaces": [
                ["namespace": "x", "count": "9"],
                ["namespace": "y"],       // no count
            ],
        ] as JSONObject)
        XCTAssertEqual(out[0].count, 9)
        XCTAssertEqual(out[1].count, 0)
    }

    func testToleratesNameAsAnAliasForNamespace() {
        let out = JarvisMemoryParse.namespaces([
            "namespaces": [["name": "aliased", "count": 4]],
        ] as JSONObject)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].namespace, "aliased")
        XCTAssertEqual(out[0].count, 4)
    }

    func testNamespacesEmptyMissingNilOrWrongTypeGivesEmpty() {
        XCTAssertTrue(JarvisMemoryParse.namespaces(["namespaces": []] as JSONObject).isEmpty)
        XCTAssertTrue(JarvisMemoryParse.namespaces(JSONObject()).isEmpty)
        XCTAssertTrue(JarvisMemoryParse.namespaces(nil).isEmpty)
        XCTAssertTrue(JarvisMemoryParse.namespaces("nope").isEmpty)
        XCTAssertTrue(JarvisMemoryParse.namespaces(["namespaces": 42] as JSONObject).isEmpty)
    }

    func testNamespacesSkipsEntriesWithNoUsableNameAndNonMapItems() {
        let out = JarvisMemoryParse.namespaces([
            "namespaces": [
                ["namespace": "", "count": 1],   // empty name → skip
                "garbage",                        // non-object → skip
                ["count": 2],                     // no name key → skip
                ["namespace": "keep", "count": 8],
            ],
        ] as JSONObject)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].namespace, "keep")
    }

    // MARK: parseEntries

    func testRealSearchShapeUsesEntriesNotResults() {
        let out = JarvisMemoryParse.entries([
            "available": true,
            "namespace": "global",
            "entries": [
                ["id": "c1", "body": "hello", "score": 0.9],
                ["id": "c2", "body": "world", "score": 0.4],
            ],
        ] as JSONObject)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].id, "c1")
        XCTAssertEqual(out[0].body, "hello")
        XCTAssertEqual(out[0].score, 0.9)
    }

    func testToleratesResultsAndABareList() {
        let fromResults = JarvisMemoryParse.entries([
            "results": [["id": "r1", "body": "x"]],
        ] as JSONObject)
        XCTAssertEqual(fromResults.count, 1)
        XCTAssertEqual(fromResults[0].id, "r1")

        let bare = JarvisMemoryParse.entries([["id": "b1", "body": "y"]])
        XCTAssertEqual(bare.count, 1)
        XCTAssertEqual(bare[0].id, "b1")
    }

    func testEntriesUnavailableEmptyOrWrongTypeGivesEmpty() {
        XCTAssertTrue(JarvisMemoryParse.entries([
            "available": false, "error": "no store", "entries": [],
        ] as JSONObject).isEmpty)
        XCTAssertTrue(JarvisMemoryParse.entries(nil).isEmpty)
        XCTAssertTrue(JarvisMemoryParse.entries("nope").isEmpty)
    }

    // MARK: asInt

    func testAsIntHandlesIntNumNumericStringNilAndJunk() {
        XCTAssertEqual(JarvisMemoryParse.asInt(3), 3)
        XCTAssertEqual(JarvisMemoryParse.asInt(3.9), 3)
        XCTAssertEqual(JarvisMemoryParse.asInt(" 42 "), 42)
        XCTAssertEqual(JarvisMemoryParse.asInt(nil), 0)
        XCTAssertEqual(JarvisMemoryParse.asInt("abc"), 0)
        XCTAssertEqual(JarvisMemoryParse.asInt([Int]()), 0)
    }

    // MARK: Availability (long_term_memory_page's _MemoryData)

    func testAvailableOnlyWhenNeitherStatsNorStatusReportedFailure() {
        let ok = JarvisMemoryData(stats: ["available": true], status: ["available": true], reflections: [])
        XCTAssertTrue(ok.available)
        XCTAssertNil(ok.unavailableMessage)

        // A MISSING `available` must not read as unavailable.
        let partial = JarvisMemoryData(stats: ["count": 3], status: JSONObject(), reflections: [])
        XCTAssertTrue(partial.available)

        let statsDown = JarvisMemoryData(stats: ["available": false, "error": "no store"],
                                         status: ["available": true], reflections: [])
        XCTAssertFalse(statsDown.available)
        XCTAssertEqual(statsDown.unavailableMessage, "no store")

        let statusDown = JarvisMemoryData(stats: ["available": true],
                                          status: ["available": false], reflections: [])
        XCTAssertFalse(statusDown.available)
        XCTAssertNil(statusDown.unavailableMessage)   // no error text given
    }

    func testDataExposesCountAndNamespaces() {
        let data = JarvisMemoryData(
            stats: ["count": "12", "namespaces": [["namespace": "global", "count": 12]]],
            status: ["embed_model": "nomic", "ollama_running": true],
            reflections: [MemoryReflection(id: "1", title: "hi")])
        XCTAssertEqual(data.count, 12)
        XCTAssertEqual(data.namespaces.map(\.namespace), ["global"])
        XCTAssertEqual(data.status.embedModel, "nomic")
        XCTAssertTrue(data.status.ollamaRunning)
        XCTAssertEqual(data.reflections.count, 1)
    }

    // MARK: API requests

    func testStatsAndStatusPaths() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["available": true, "count": 2])
        _ = try await JarvisMemoryAPI(api: api).stats()
        XCTAssertEqual(transport.lastMethod, "GET")
        XCTAssertEqual(transport.lastPath, "/api/jarvis-memory/stats")

        transport.enqueue(json: ["available": true])
        _ = try await JarvisMemoryAPI(api: api).status()
        XCTAssertEqual(transport.lastPath, "/api/jarvis-memory/status")
        XCTAssertEqual(transport.lastQuery, [:])
    }

    func testSearchSendsTheQueryAsQ() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["entries": [["id": "1", "body": "hit"]]])
        let out = try await JarvisMemoryAPI(api: api).search("bikes")

        XCTAssertEqual(transport.lastMethod, "GET")
        XCTAssertEqual(transport.lastPath, "/api/jarvis-memory/search")
        XCTAssertEqual(transport.lastQuery, ["q": "bikes"])
        XCTAssertEqual(out.map(\.body), ["hit"])
    }

    func testReflectionsParsesTheSqliteRows() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["reflections": [
            ["id": 7, "ts": "2026-06-21T10:00:00Z", "kind": "pattern",
             "title": "You commit at night", "body": "…", "status": "new",
             "dedup_key": "k"],
        ]])
        let out = try await JarvisMemoryAPI(api: api).reflections()

        XCTAssertEqual(transport.lastPath, "/api/jarvis-memory/reflections")
        XCTAssertEqual(out.count, 1)
        // The row's id is an INTEGER server-side; stringified here.
        XCTAssertEqual(out[0].id, "7")
        XCTAssertEqual(out[0].title, "You commit at night")
        XCTAssertEqual(out[0].dedupKey, "k")
    }

    func testDeleteEntryPostsAStringID() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["ok": true])
        try await JarvisMemoryAPI(api: api).deleteEntry("c1")

        XCTAssertEqual(transport.lastMethod, "POST")
        XCTAssertEqual(transport.lastPath, "/api/jarvis-memory/delete")
        assertJSONEqual(transport.lastBody(), ["id": "c1"])
    }

    func testDismissReflectionCoercesANumericIDToAnInteger() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["ok": true])
        try await JarvisMemoryAPI(api: api).dismissReflection("7")

        XCTAssertEqual(transport.lastMethod, "POST")
        XCTAssertEqual(transport.lastPath, "/api/jarvis-memory/reflections/dismiss")
        let body = transport.lastBody()
        XCTAssertEqual(body["id"] as? Int, 7)
        XCTAssertEqual(body["reflection_id"] as? Int, 7)
    }

    func testDismissReflectionKeepsANonNumericIDAsAString() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["ok": true])
        try await JarvisMemoryAPI(api: api).dismissReflection("abc")
        XCTAssertEqual(transport.lastBody()["id"] as? String, "abc")
    }

    func testRunReflectionsPostsAnEmptyBody() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["ok": true, "new": 2])
        try await JarvisMemoryAPI(api: api).runReflections()

        XCTAssertEqual(transport.lastMethod, "POST")
        XCTAssertEqual(transport.lastPath, "/api/jarvis-memory/reflections/run")
        XCTAssertTrue(transport.lastBody().isEmpty)
    }

    // MARK: Store

    @MainActor
    func testStoreLoadsHeaderAndSearchesOnAppear() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/jarvis-memory/stats",
                        json: ["available": true, "count": 3,
                               "namespaces": [["namespace": "global", "count": 3]]])
        transport.route("/api/jarvis-memory/status", json: ["available": true])
        transport.route("/api/jarvis-memory/reflections", json: ["reflections": []])
        transport.route("/api/jarvis-memory/search",
                        json: ["entries": [["id": "e1", "body": "recent"]]])

        let store = JarvisMemoryStore(api: JarvisMemoryAPI(api: api), sleeper: instantSleeper)
        await store.refresh()

        XCTAssertTrue(store.available)
        XCTAssertEqual(store.data.count, 3)
        XCTAssertEqual(store.namespaces.map(\.namespace), ["global"])
        XCTAssertEqual(store.results.map(\.id), ["e1"])
        XCTAssertEqual(store.lastQuery, "")
    }

    @MainActor
    func testStoreDeleteEntryDropsItOptimisticallyThenReloadsStats() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/jarvis-memory/stats", json: ["available": true, "count": 1])
        transport.route("/api/jarvis-memory/status", json: ["available": true])
        transport.route("/api/jarvis-memory/reflections", json: ["reflections": []])
        transport.route("/api/jarvis-memory/search",
                        json: ["entries": [["id": "e1", "body": "x"], ["id": "e2", "body": "y"]]])
        transport.route("/api/jarvis-memory/delete", json: ["ok": true])

        let store = JarvisMemoryStore(api: JarvisMemoryAPI(api: api), sleeper: instantSleeper)
        await store.refresh()
        XCTAssertEqual(store.results.count, 2)

        await store.deleteEntry("e1")
        XCTAssertEqual(store.results.map(\.id), ["e2"])
        XCTAssertTrue(transport.paths.contains("/api/jarvis-memory/delete"))
    }

    @MainActor
    func testStoreRunReflectionsToasts() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/jarvis-memory/stats", json: ["available": true])
        transport.route("/api/jarvis-memory/status", json: ["available": true])
        transport.route("/api/jarvis-memory/reflections/run", json: ["ok": true, "new": 1])
        transport.route("/api/jarvis-memory/reflections", json: ["reflections": []])

        let store = JarvisMemoryStore(api: JarvisMemoryAPI(api: api), sleeper: instantSleeper)
        await store.runReflections()
        XCTAssertEqual(store.toast, "Reflection started")
    }

    @MainActor
    func testStoreDebouncedQueryOnlyIssuesTheLastSearch() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/jarvis-memory/search", json: ["entries": []])

        let store = JarvisMemoryStore(api: JarvisMemoryAPI(api: api), sleeper: instantSleeper)
        store.queryChanged("b")
        store.queryChanged("bi")
        store.queryChanged("bike")
        await store.waitForSearch()

        // The earlier two tasks were cancelled before their request went out.
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.lastQuery, ["q": "bike"])
        XCTAssertEqual(store.lastQuery, "bike")
    }
}

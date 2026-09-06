import Foundation
import XCTest
@testable import JarvisCopilot

/// Ported from `mobile_client/test/island_demo_test.dart`, case for case, plus
/// the `/api/island/*` endpoint and store behaviour from `island_designs_page.dart`.
final class IslandDemoTests: XCTestCase {

    // MARK: The bundled demo

    func testBundledDemoIsARegionsDesignThatParses() {
        XCTAssertEqual(MoreJSON.text(IslandDemo.design["id"]), "demo")
        let presentations = MoreJSON.map(IslandDemo.design["presentations"])
        XCTAssertEqual(MoreJSON.text(MoreJSON.map(presentations["expanded"])["type"]), "regions")

        let design = IslandDesign(json: IslandDemo.design)
        XCTAssertEqual(design.name, "UI Example (max size)")
        XCTAssertEqual(design.version, 6)
    }

    func testBundledDemoProgressBarCarriesATipIndicator() {
        let expanded = MoreJSON.map(MoreJSON.map(IslandDemo.design["presentations"])["expanded"])
        let bottom = MoreJSON.mapList(MoreJSON.map(expanded["bottom"])["children"])
        let progress = bottom.first { MoreJSON.text($0["type"]) == "progress" }
        XCTAssertNotNil(progress)
        let tip = progress?["tip"] as? JSONObject
        XCTAssertNotNil(tip)
        XCTAssertEqual(MoreJSON.text(tip?["symbol"]), "airplane")
    }

    func testBundledDemoRegionsAreAllLabelled() {
        let expanded = MoreJSON.map(MoreJSON.map(IslandDemo.design["presentations"])["expanded"])
        for region in ["leading", "center", "trailing", "bottom"] {
            XCTAssertNotNil(expanded[region], region)
        }
    }

    func testInjectBundledDemoReplacesTheServerDemoAndPreservesUserOverrides() {
        var raw: JSONObject = [
            "designs": [
                ["id": "demo", "version": 1, "presentations": [:]],
                ["id": "deploy", "version": 1],
            ],
            "catalog": [
                ["id": "demo", "builtin": true, "enabled": true, "priority": 9],
                ["id": "deploy"],
            ],
            "selection": ["mode": "auto"],
        ]
        IslandDemo.injectBundledDemo(&raw)

        let demos = MoreJSON.mapList(raw["designs"]).filter { MoreJSON.text($0["id"]) == "demo" }
        XCTAssertEqual(demos.count, 1, "the server copy is replaced, not duplicated")
        XCTAssertEqual(MoreJSON.int(demos[0]["version"]), 6, "the bundled version wins")
        let expanded = MoreJSON.map(MoreJSON.map(demos[0]["presentations"])["expanded"])
        XCTAssertEqual(MoreJSON.text(expanded["type"]), "regions")
        // deploy is untouched.
        XCTAssertTrue(MoreJSON.mapList(raw["designs"])
            .contains { MoreJSON.text($0["id"]) == "deploy" })

        let catalog = MoreJSON.mapList(raw["catalog"]).filter { MoreJSON.text($0["id"]) == "demo" }
        XCTAssertEqual(catalog.count, 1)
        XCTAssertEqual(catalog[0]["enabled"] as? Bool, true, "user override preserved")
        XCTAssertEqual(MoreJSON.int(catalog[0]["priority"]), 9)
    }

    func testInjectBundledDemoHandlesAMissingOrEmptyPayload() {
        var raw = JSONObject()
        IslandDemo.injectBundledDemo(&raw)
        XCTAssertTrue(MoreJSON.mapList(raw["designs"]).contains { MoreJSON.text($0["id"]) == "demo" })
        XCTAssertTrue(MoreJSON.mapList(raw["catalog"]).contains { MoreJSON.text($0["id"]) == "demo" })
    }

    func testInjectBundledDemoKeepsTheBundledDefaultsWhenTheServerHasNoOverride() {
        var raw: JSONObject = ["catalog": [["id": "deploy"]]]
        IslandDemo.injectBundledDemo(&raw)
        let demo = MoreJSON.mapList(raw["catalog"]).first { MoreJSON.text($0["id"]) == "demo" }
        // The bundled entry ships disabled with priority 1.
        XCTAssertEqual(demo?["enabled"] as? Bool, false)
        XCTAssertEqual(MoreJSON.int(demo?["priority"]), 1)
    }

    func testInjectBundledDemoPreservesConditionsAndSchedule() {
        var raw: JSONObject = ["catalog": [[
            "id": "demo",
            "conditions": ["op": "exists", "a": ["src": "x"]],
            "schedule": ["from": "09:00", "to": "17:00"],
        ]]]
        IslandDemo.injectBundledDemo(&raw)
        let demo = MoreJSON.mapList(raw["catalog"]).first { MoreJSON.text($0["id"]) == "demo" }
        XCTAssertNotNil(demo?["conditions"])
        XCTAssertEqual(MoreJSON.text(MoreJSON.map(demo?["schedule"])["from"]), "09:00")
    }

    // MARK: API requests

    func testCatalogMergesTheBundledDemo() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: [
            "designs": [["id": "deploy", "version": 2]],
            "catalog": [["id": "deploy", "priority": 10]],
            "selection": ["mode": "auto"],
            "data": ["deploy": ["pct": 62]],
        ])
        let catalog = try await IslandDesignsAPI(api: api).catalog()

        XCTAssertEqual(transport.lastMethod, "GET")
        XCTAssertEqual(transport.lastPath, "/api/island/designs")
        XCTAssertEqual(transport.lastQuery, [:])
        XCTAssertNotNil(catalog.design(id: "demo"), "the bundled demo is merged in")
        XCTAssertNotNil(catalog.design(id: "deploy"))
        XCTAssertEqual(catalog.design(id: "demo")?.version, 6)
        XCTAssertEqual(MoreJSON.int(catalog.data(for: "deploy")["pct"]), 62)
    }

    func testUpsertPostsTheWholeDesign() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["ok": true])
        try await IslandDesignsAPI(api: api).upsert(["id": "d", "version": 3])

        XCTAssertEqual(transport.lastMethod, "POST")
        XCTAssertEqual(transport.lastPath, "/api/island/designs")
        assertJSONEqual(transport.lastBody(), ["id": "d", "version": 3])
    }

    func testDeleteDesignUsesDELETE() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["ok": true])
        try await IslandDesignsAPI(api: api).deleteDesign("d")

        XCTAssertEqual(transport.lastMethod, "DELETE")
        XCTAssertEqual(transport.lastPath, "/api/island/designs/d")
    }

    func testSetSelectionOmitsPinnedIDForAuto() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["ok": true])
        try await IslandDesignsAPI(api: api).setSelection("auto")
        XCTAssertEqual(transport.lastMethod, "POST")
        XCTAssertEqual(transport.lastPath, "/api/island/selection")
        assertJSONEqual(transport.lastBody(), ["mode": "auto"])

        transport.enqueue(json: ["ok": true])
        try await IslandDesignsAPI(api: api).setSelection("pinned", pinnedID: "deploy")
        assertJSONEqual(transport.lastBody(), ["mode": "pinned", "pinnedId": "deploy"])
    }

    func testSetRulesOnlySendsTheKeysGiven() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["ok": true])
        try await IslandDesignsAPI(api: api).setRules("d", enabled: false)
        XCTAssertEqual(transport.lastMethod, "POST")
        XCTAssertEqual(transport.lastPath, "/api/island/designs/d/rules")
        assertJSONEqual(transport.lastBody(), ["enabled": false])

        transport.enqueue(json: ["ok": true])
        try await IslandDesignsAPI(api: api).setRules(
            "d", priority: 42,
            conditions: ["op": "exists", "a": ["src": "x"]],
            schedule: ["from": "09:00", "to": "17:00"])
        assertJSONEqual(transport.lastBody(), [
            "priority": 42,
            "conditions": ["op": "exists", "a": ["src": "x"]],
            "schedule": ["from": "09:00", "to": "17:00"],
        ])
    }

    func testSetDataPostsTheValues() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["ok": true])
        try await IslandDesignsAPI(api: api).setData("d", data: ["pct": 62])
        XCTAssertEqual(transport.lastPath, "/api/island/designs/d/data")
        assertJSONEqual(transport.lastBody(), ["pct": 62])
    }

    // MARK: Store

    @MainActor
    func testStoreSelectedKeyIsAutoOrThePinnedID() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/island/designs", json: [
            "designs": [["id": "deploy", "version": 1]],
            "catalog": [["id": "voice", "builtin": true], ["id": "deploy"]],
            "selection": ["mode": "pinned", "pinnedId": "deploy"],
        ])

        let store = IslandDesignsStore(api: IslandDesignsAPI(api: api))
        await store.refresh()

        XCTAssertEqual(store.selectedKey, "deploy")
        XCTAssertEqual(store.entries.map(\.id), ["voice", "deploy", "demo"])
        // The bundled demo ships `builtin: true`, so only `deploy` is deletable.
        XCTAssertEqual(store.customEntries.map(\.id), ["deploy"])
        XCTAssertTrue(store.canDelete(store.customEntries[0]))
        XCTAssertFalse(store.isLoading)
        XCTAssertNil(store.errorMessage)
    }

    @MainActor
    func testStoreSelectPostsAutoOrPinnedThenReloadsAndPokesTheCoordinator() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/island/selection", json: ["ok": true])
        transport.route("/api/island/designs", json: ["designs": [], "catalog": [],
                                                      "selection": ["mode": "auto"]])

        let poked = LockedFlag()
        let store = IslandDesignsStore(api: IslandDesignsAPI(api: api),
                                       onChanged: { poked.set() })

        await store.select(IslandDesignsStore.autoKey)
        assertJSONEqual(transport.body(0), ["mode": "auto"])
        XCTAssertTrue(poked.value)
        XCTAssertEqual(transport.path(1), "/api/island/designs", "the catalog reloads")

        await store.select("deploy")
        assertJSONEqual(transport.body(2), ["mode": "pinned", "pinnedId": "deploy"])
    }

    @MainActor
    func testStoreSetEnabledAndDelete() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/island/designs/d/rules", json: ["ok": true])
        transport.route("/api/island/designs/d", json: ["ok": true])
        transport.route("/api/island/designs", json: ["designs": [], "catalog": [],
                                                      "selection": ["mode": "auto"]])

        let store = IslandDesignsStore(api: IslandDesignsAPI(api: api))
        await store.setEnabled("d", false)
        XCTAssertEqual(transport.path(0), "/api/island/designs/d/rules")
        assertJSONEqual(transport.body(0), ["enabled": false])

        let before = transport.requests.count
        await store.delete(IslandCatalogEntry(id: "d", name: "D", icon: "", version: 1,
                                              builtin: false, enabled: true, priority: 0))
        XCTAssertEqual(transport.method(before), "DELETE")
        XCTAssertEqual(transport.path(before), "/api/island/designs/d")
    }

    @MainActor
    func testStoreSurfacesALoadFailureWithTheFlutterWording() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/island/designs", json: ["error": "off"], status: 500)

        let store = IslandDesignsStore(api: IslandDesignsAPI(api: api))
        await store.refresh()
        XCTAssertEqual(store.errorMessage,
                       "Could not load designs. Check the server connection.")
    }

    @MainActor
    func testStoreMutationFailureToasts() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/island/selection", json: ["error": "no"], status: 500)
        transport.route("/api/island/designs", json: ["designs": [], "catalog": [],
                                                      "selection": ["mode": "auto"]])

        let store = IslandDesignsStore(api: IslandDesignsAPI(api: api))
        await store.select("deploy")
        XCTAssertEqual(store.toast, "That didn’t go through. Try again.")
    }

    @MainActor
    func testStoreSyncsTheWidgetCacheAfterLoading() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/island/designs", json: [
            "designs": [["id": "deploy", "version": 1]],
            "catalog": [], "selection": ["mode": "auto"],
        ])

        let cache = SpyIslandCache()
        let store = IslandDesignsStore(api: IslandDesignsAPI(api: api),
                                       sync: IslandSync(cache: cache))
        await store.refresh()

        let pushed = await cache.pushedIDs
        XCTAssertEqual(pushed.count, 1)
        XCTAssertEqual(pushed[0].sorted(), ["demo", "deploy"])
    }
}

/// A tiny thread-safe flag for asserting an escaping `@Sendable` callback ran.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

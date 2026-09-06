import Foundation
import XCTest
@testable import JarvisCopilot

/// The More-area behaviours the wave-4 coverage review found untested, plus the
/// silent-failure fixes that gave a few of them an observable result.
@MainActor
final class MoreGapTests: XCTestCase {

    // MARK: - KanbanStore.runDispatcher

    /// The board-level "run the dispatcher" bolt: it reports what the server did
    /// AND re-reads the board, because the tasks it claimed have changed column.
    func testRunDispatcherReportsTheResultAndReloadsTheBoard() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/kanban/dispatch", json: ["spawned": 2])
        transport.route("/api/kanban/boards", json: ["boards": []])
        transport.route("/api/kanban/board",
                        json: ["tasks": [["id": "t1", "title": "a", "status": "ready"]]])

        let store = KanbanStore(api: KanbanAPI(api: api), sleeper: { _ in })
        await store.runDispatcher()

        XCTAssertEqual(store.toast, "Dispatcher ran — 2 workers started")
        XCTAssertTrue(transport.paths.contains("/api/kanban/board"),
                      "the claimed tasks moved column — the board has to be re-read")
        XCTAssertEqual(store.allTasks.count, 1)
    }

    func testRunDispatcherPassesTheDryRunAndMaxThrough() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/kanban/dispatch", json: ["spawned": 0])
        transport.route("/api/kanban/boards", json: ["boards": []])
        transport.route("/api/kanban/board", json: ["tasks": []])

        let store = KanbanStore(api: KanbanAPI(api: api), sleeper: { _ in })
        await store.runDispatcher(dryRun: true, max: 3)

        // The dispatcher takes its flags as QUERY, not body — the POST body is
        // empty, which is what the bridge expects.
        XCTAssertEqual(transport.query(0)["dry_run"], "true")
        XCTAssertEqual(transport.query(0)["max"], "3")
    }

    /// A dispatcher failure is a toast, not a wiped board — the tasks on screen
    /// are still real.
    func testRunDispatcherSurfacesAFailureWithoutClearingTheBoard() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/kanban/dispatch", json: ["error": "busy"], status: 500)
        transport.route("/api/kanban/boards", json: ["boards": []])
        transport.route("/api/kanban/board",
                        json: ["tasks": [["id": "t1", "title": "a", "status": "ready"]]])
        let store = KanbanStore(api: KanbanAPI(api: api), sleeper: { _ in })
        await store.refresh()
        XCTAssertEqual(store.allTasks.count, 1)

        await store.runDispatcher()

        XCTAssertNotNil(store.toast)
        XCTAssertEqual(store.allTasks.count, 1, "a failed dispatch must not blank the board")
    }

    // MARK: - IslandDesignsStore.setPriority / guarded

    func testSetPriorityPostsTheRuleAndReloadsTheCatalog() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/island/designs/flight/rules", json: ["ok": true])
        transport.route("/api/island/designs", json: ["designs": [], "catalog": []])

        var pokes = 0
        let store = IslandDesignsStore(api: IslandDesignsAPI(api: api),
                                       onChanged: { pokes += 1 })
        await store.setPriority("flight", 7)

        XCTAssertEqual(transport.path(0), "/api/island/designs/flight/rules")
        XCTAssertEqual(transport.body(0)["priority"] as? Int, 7)
        XCTAssertNil(transport.body(0)["enabled"], "only the field being changed is sent")
        XCTAssertTrue(transport.paths.contains("/api/island/designs"),
                      "the catalog is re-read so the list shows the new order")
        XCTAssertEqual(pokes, 1, "the island switches now, not on the next throttled poll")
        XCTAssertFalse(store.isBusy)
    }

    /// `guarded` is the mutation lock: every control disables while one is in
    /// flight, and a failure becomes a toast rather than a half-applied list.
    func testAFailedMutationToastsAndLeavesTheCatalogAlone() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/island/designs/flight/rules",
                        json: ["error": "nope"], status: 500)

        var pokes = 0
        let store = IslandDesignsStore(api: IslandDesignsAPI(api: api),
                                       onChanged: { pokes += 1 })
        await store.setEnabled("flight", false)

        XCTAssertEqual(store.toast, "That didn’t go through. Try again.")
        XCTAssertEqual(pokes, 0, "nothing changed, so nothing to poke")
        XCTAssertFalse(store.isBusy, "the lock must be released on the failure path too")
        XCTAssertFalse(transport.paths.contains("/api/island/designs"))
    }

    func testGuardedDropsASecondMutationWhileOneIsInFlight() async {
        let (api, transport) = JarvisAPI.mocked()
        // Routes are first-match-wins on a path SUBSTRING, so the specific
        // endpoints have to be registered before the catalog's prefix.
        transport.route("/api/island/designs/a/rules", json: ["ok": true])
        transport.route("/api/island/designs/b/rules", json: ["ok": true])
        transport.route("/api/island/designs", json: ["designs": [], "catalog": []])

        let store = IslandDesignsStore(api: IslandDesignsAPI(api: api))
        async let first: Void = store.setEnabled("a", true)
        async let second: Void = store.setEnabled("b", true)
        await first
        await second

        let ruleHits = transport.paths.filter { $0.hasSuffix("/rules") }
        XCTAssertEqual(ruleHits.count, 1,
                       "the second tap lands while isBusy and is dropped, not queued")
    }

    // MARK: - WorkspacesStore stale-suggest race

    /// `suggestRequestID` is what makes a superseded lookup lose even when its
    /// answer arrives last: only the newest prefix's hits are ever shown, and
    /// the request that was replaced never reaches the list.
    func testOnlyTheNewestSuggestionLookupOwnsTheList() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["suggestions": ["/Users/me/code"]])
        let store = WorkspacesStore(api: WorkspacesAPI(api: api), sleeper: { _ in })

        store.suggest(prefix: "/U")
        store.suggest(prefix: "/Users")
        await store.waitForSuggestions()

        XCTAssertEqual(transport.requests.count, 1, "the replaced lookup never went out")
        XCTAssertEqual(transport.lastQuery["prefix"], "/Users")
        XCTAssertEqual(store.suggestions, ["/Users/me/code"])
    }

    /// A failed lookup degrades to "no suggestions" — the user can still type the
    /// whole path — but it must not leave the PREVIOUS prefix's hits on screen.
    func testAFailedSuggestionLookupClearsRatherThanKeepsStaleHits() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["suggestions": ["/a"]])
        transport.enqueue(json: ["error": "nope"], status: 500)
        let store = WorkspacesStore(api: WorkspacesAPI(api: api), sleeper: { _ in })

        store.suggest(prefix: "/a")
        await store.waitForSuggestions()
        XCTAssertEqual(store.suggestions, ["/a"])

        store.suggest(prefix: "/ab")
        await store.waitForSuggestions()

        XCTAssertTrue(store.suggestions.isEmpty)
        XCTAssertEqual(transport.requests.count, 2)
    }

    // MARK: - TodosAPI.sessionMessages

    /// `{session: {messages: []}}` is the documented shape; a bare `messages`
    /// key is what older servers answer with, and both have to work.
    func testSessionMessagesAcceptsTheBareMessagesShape() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["messages": [["role": "assistant", "content": "hi"]]])

        let messages = try await TodosAPI(api: api).sessionMessages("s1")

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(transport.lastPath, "/api/session")
        XCTAssertEqual(transport.lastQuery,
                       ["session_id": "s1", "messages": "1", "resolve_model": "0"])
    }

    func testSessionMessagesPrefersTheNestedSessionEnvelope() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["session": ["messages": [["role": "user", "content": "a"],
                                                          ["role": "user", "content": "b"]]],
                                 "messages": []])
        let messages = try await TodosAPI(api: api).sessionMessages("s1")
        XCTAssertEqual(messages.count, 2, "the envelope wins over the bare key")
    }

    func testSessionMessagesIsEmptyWhenNeitherKeyIsThere() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["session": ["id": "s1"]])
        let messages = try await TodosAPI(api: api).sessionMessages("s1")
        XCTAssertTrue(messages.isEmpty)
    }

    // MARK: - JarvisMemoryStore.loadHeader partial failure

    /// Stats and status are required; reflections are not. A reflections outage
    /// must not turn the whole page into an error.
    func testTheHeaderSurvivesAReflectionsOutage() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/jarvis-memory/stats", json: ["available": true, "count": 12])
        transport.route("/api/jarvis-memory/status", json: ["available": true])
        transport.route("/api/jarvis-memory/reflections", json: ["error": "off"], status: 500)

        let store = JarvisMemoryStore(api: JarvisMemoryAPI(api: api), sleeper: { _ in })
        await store.refresh()

        XCTAssertNil(store.errorMessage, "reflections fail soft on their own")
        XCTAssertTrue(store.data.reflections.isEmpty)
        XCTAssertTrue(store.hasLoaded)
    }

    /// …but a stats failure IS the page failing.
    func testAStatsFailureIsReportedAsAPageError() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/jarvis-memory/stats", json: ["error": "off"], status: 500)
        transport.route("/api/jarvis-memory/status", json: ["available": true])
        transport.route("/api/jarvis-memory/reflections", json: ["reflections": []])

        let store = JarvisMemoryStore(api: JarvisMemoryAPI(api: api), sleeper: { _ in })
        await store.refresh()

        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(store.hasLoaded)
    }

    // MARK: - Insights: an unreachable host is not a healthy one (M21)

    func testAFailedHealthFetchIsFlaggedRatherThanHidden() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/system/health", json: ["error": "off"], status: 500)

        let health = await InsightsAPI(api: api).systemHealth()

        XCTAssertTrue(health.failed,
                      "an unreachable host must not render the same as one with no metrics")
        XCTAssertTrue(health.isEmpty)
    }

    func testAHealthyResponseIsNotFlagged() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/system/health", json: ["available": true, "cpu": ["percent": 10]])
        let health = await InsightsAPI(api: api).systemHealth()
        XCTAssertFalse(health.failed)
    }

    /// An EMPTY body is the server saying "no metrics", which is not a failure.
    func testAnEmptyHealthBodyIsNotAFailure() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/system/health", json: JSONObject())
        let health = await InsightsAPI(api: api).systemHealth()
        XCTAssertFalse(health.failed)
        XCTAssertTrue(health.isEmpty)
    }

    // MARK: - Partial loads keep the required data (silent-failures M13)

    /// The device list is the only required fetch; the skill catalogue only
    /// labels the per-device chips.
    func testASkillCatalogueOutageDoesNotSinkTheDeviceList() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/devices/skills", json: ["error": "off"], status: 500)
        transport.route("/api/devices", json: ["devices": [["id": "d1", "name": "Mac"]]])
        transport.route("/api/system/health", json: JSONObject())
        transport.route("/api/wiki/status", json: JSONObject())

        let store = DevicesStore(api: DevicesAPI(api: api), insights: InsightsAPI(api: api))
        await store.refresh()

        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.devices.count, 1)
        XCTAssertTrue(store.catalogue.isEmpty)
    }

    /// Code-memory totals fall back to summing the projects when stats is down.
    func testACodeMemoryStatsOutageStillShowsTheProjects() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/code-memory/stats", json: ["error": "off"], status: 500)
        transport.route("/api/code-memory/projects",
                        json: ["projects": [["project": "hermes", "entries": 4]]])

        let store = CodeMemoryStore(api: CodeMemoryAPI(api: api))
        await store.refresh()

        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.overview.projects.count, 1)
    }
}

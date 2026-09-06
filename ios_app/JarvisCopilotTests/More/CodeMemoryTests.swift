import Foundation
import XCTest
@testable import JarvisCopilot

/// Ported from `mobile_client/test/code_memory_test.dart`, case for case.
/// `relativeTime` takes an injected `now` here instead of reading the wall clock,
/// so the cases are deterministic rather than "close to now".
final class CodeMemoryTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_780_000_000)  // fixed "now"

    private func relative(secondsAgo: Int) -> String {
        RelativeTime.format(now.timeIntervalSince1970 - Double(secondsAgo), now: now)
    }

    // MARK: parseProjects

    func testMapKeyedBySlugBecomesAListCarryingEachSlug() {
        let raw: JSONObject = [
            "jarvis-copilot": [
                "name": "JarvisCopilot",
                "knowledge_count": 12,
                "sessions_count": 3,
                "last_seen": "2026-06-21T10:00:00Z",
            ],
            "other-repo": [
                "name": "Other",
                "knowledge_count": 0,
                "sessions_count": 1,
            ],
        ]
        let out = CodeMemoryParse.projects(raw)
        XCTAssertEqual(out.count, 2)

        let jc = out.first { $0.slug == "jarvis-copilot" }
        XCTAssertEqual(jc?.name, "JarvisCopilot")
        XCTAssertEqual(jc?.knowledgeCount, 12)
        XCTAssertEqual(jc?.sessionsCount, 3)

        let other = out.first { $0.slug == "other-repo" }
        XCTAssertEqual(other?.name, "Other")
        XCTAssertEqual(other?.slug, "other-repo")
    }

    func testTheMapKeyWinsAsSlugEvenIfAnInnerSlugFieldDiffers() {
        let out = CodeMemoryParse.projects(["real-slug": ["name": "X", "slug": "stale"]] as JSONObject)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].slug, "real-slug")
    }

    func testBareListPassesThrough() {
        let out = CodeMemoryParse.projects([
            ["slug": "a", "name": "A"],
            ["slug": "b", "name": "B"],
        ])
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].slug, "a")
        XCTAssertEqual(out[1].name, "B")
    }

    func testListDropsNonMapItems() {
        let out = CodeMemoryParse.projects([["slug": "a"], "garbage", 42])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].slug, "a")
    }

    func testEmptyMapGivesEmptyList() {
        XCTAssertTrue(CodeMemoryParse.projects(JSONObject()).isEmpty)
    }

    func testNilOrNonCollectionGivesEmptyList() {
        XCTAssertTrue(CodeMemoryParse.projects(nil).isEmpty)
        XCTAssertTrue(CodeMemoryParse.projects("nope").isEmpty)
        XCTAssertTrue(CodeMemoryParse.projects(7).isEmpty)
    }

    func testProjectCountsToleratePlainKnowledgeAndSessionsKeys() {
        let out = CodeMemoryParse.projects(["s": ["knowledge": 4, "sessions": 2]] as JSONObject)
        XCTAssertEqual(out[0].knowledgeCount, 4)
        XCTAssertEqual(out[0].sessionsCount, 2)
    }

    // MARK: relativeTime

    func testRelativeTimeNilEmptyOrUnparseableGivesEmptyString() {
        XCTAssertEqual(RelativeTime.format(nil, now: now), "")
        XCTAssertEqual(RelativeTime.format("", now: now), "")
        XCTAssertEqual(RelativeTime.format("   ", now: now), "")
        XCTAssertEqual(RelativeTime.format("not-a-date", now: now), "")
    }

    func testRelativeTimeUnderAMinuteIsJustNow() {
        XCTAssertEqual(relative(secondsAgo: 5), "just now")
        XCTAssertEqual(relative(secondsAgo: 59), "just now")
    }

    func testRelativeTimeMinutesHoursDaysAgo() {
        XCTAssertEqual(relative(secondsAgo: 60 * 5), "5m ago")
        XCTAssertEqual(relative(secondsAgo: 3600 * 2), "2h ago")
        XCTAssertEqual(relative(secondsAgo: 86400 * 3), "3d ago")
    }

    func testRelativeTimeOlderThanAWeekIsAnAbsoluteDate() {
        let out = RelativeTime.format("2020-01-15T08:30:00Z", now: now)
        XCTAssertNotNil(out.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression), out)
        XCTAssertTrue(out.hasPrefix("2020-01-1"), out)
    }

    func testRelativeTimeAcceptsEpochSecondsAndMilliseconds() {
        let seconds = now.timeIntervalSince1970
        XCTAssertEqual(RelativeTime.format(seconds - 120, now: now), "2m ago")
        XCTAssertEqual(RelativeTime.format((seconds - 120) * 1000, now: now), "2m ago")
    }

    func testRelativeTimeNumericStringIsTreatedAsEpoch() {
        let seconds = Int(now.timeIntervalSince1970)
        XCTAssertEqual(RelativeTime.format("\(seconds - 7200)", now: now), "2h ago")
    }

    func testRelativeTimeFutureTimestampReadsAsJustNow() {
        let future = now.addingTimeInterval(5 * 60)
        XCTAssertEqual(RelativeTime.format(future.timeIntervalSince1970, now: now), "just now")
    }

    // MARK: Overview totals (code_memory_page's stats header)

    func testOverviewPrefersServerStatsAndFallsBackToSummingProjects() {
        let projects = CodeMemoryParse.projects([
            "a": ["knowledge_count": 2, "sessions_count": 1],
            "b": ["knowledge_count": 3, "sessions_count": 4],
        ] as JSONObject)

        let derived = CodeMemoryOverview(stats: CodeMemoryStats(), projects: projects)
        XCTAssertEqual(derived.totalProjects, 2)
        XCTAssertEqual(derived.totalKnowledge, 5)
        XCTAssertEqual(derived.totalHandoffs, 5)
        XCTAssertEqual(derived.lastActivityLabel(now: now), "")

        let served = CodeMemoryOverview(
            stats: CodeMemoryStats(json: ["projects": 9, "knowledge": 99, "sessions": 7,
                                          "last_activity": now.timeIntervalSince1970 - 300]),
            projects: projects)
        XCTAssertEqual(served.totalProjects, 9)
        XCTAssertEqual(served.totalKnowledge, 99)
        XCTAssertEqual(served.totalHandoffs, 7)
        XCTAssertEqual(served.lastActivityLabel(now: now), "5m ago")
    }

    // MARK: Entry titles + filtering

    func testEntryTitleUsesTheFirstLineThenFirstLineFieldThenType() {
        let full = CodeMemoryEntry(json: ["id": "1", "content": "Header line\nbody text"])
        XCTAssertEqual(full.title(kind: .knowledge), "Header line")

        let compact = CodeMemoryEntry(json: ["id": "2", "first_line": "Compact row"])
        XCTAssertEqual(compact.title(kind: .knowledge), "Compact row")

        let typed = CodeMemoryEntry(json: ["id": "3", "entry_type": "decision"])
        XCTAssertEqual(typed.title(kind: .knowledge), "decision")

        let bare = CodeMemoryEntry(json: ["id": "4"])
        XCTAssertEqual(bare.title(kind: .knowledge), "note")
        XCTAssertEqual(bare.title(kind: .sessions), "handoff")
    }

    func testProjectFilterMatchesNameOrSlugCaseInsensitively() {
        let project = CodeMemoryProject(slug: "jarvis-copilot", name: "JarvisCopilot")
        XCTAssertTrue(project.matches(""))
        XCTAssertTrue(project.matches("  "))
        XCTAssertTrue(project.matches("jarvis"))
        XCTAssertTrue(project.matches("COPILOT"))
        XCTAssertTrue(project.matches("-copilot"))
        XCTAssertFalse(project.matches("zzz"))
    }

    func testKindLabels() {
        XCTAssertEqual(CodeMemoryKind.knowledge.label, "Knowledge")
        XCTAssertEqual(CodeMemoryKind.sessions.label, "Handoffs")
    }

    // MARK: API requests

    func testStatsAndProjectsPaths() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["projects": 2, "knowledge": 5, "sessions": 3,
                                 "last_activity": "2026-06-21T10:00:00Z"])
        let stats = try await CodeMemoryAPI(api: api).stats()
        XCTAssertEqual(transport.lastMethod, "GET")
        XCTAssertEqual(transport.lastPath, "/api/code-memory/stats")
        XCTAssertEqual(stats.projects, 2)

        transport.enqueue(json: ["projects": ["a": ["name": "A"]]])
        let projects = try await CodeMemoryAPI(api: api).projects()
        XCTAssertEqual(transport.lastPath, "/api/code-memory/projects")
        XCTAssertEqual(projects.map(\.slug), ["a"])
    }

    func testEntriesSendsProjectKindAndLimit() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["slug": "a", "kind": "sessions",
                                 "entries": [["id": "a::sessions::1::0", "content": "x"]]])
        let out = try await CodeMemoryAPI(api: api).entries("a", kind: .sessions, limit: 20)

        XCTAssertEqual(transport.lastMethod, "GET")
        XCTAssertEqual(transport.lastPath, "/api/code-memory")
        XCTAssertEqual(transport.lastQuery, ["project": "a", "kind": "sessions", "limit": "20"])
        XCTAssertEqual(out.count, 1)
    }

    func testSearchSendsQAndLimit() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["entries": [["id": "1", "first_line": "hit"]]])
        _ = try await CodeMemoryAPI(api: api).search("a", query: "cache", kind: .knowledge, limit: 5)

        XCTAssertEqual(transport.lastPath, "/api/code-memory/search")
        XCTAssertEqual(transport.lastQuery,
                       ["project": "a", "kind": "knowledge", "q": "cache", "limit": "5"])
    }

    func testByIDsJoinsIDsWithCommasAndSkipsTheCallWhenEmpty() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["entries": []])
        let none = try await CodeMemoryAPI(api: api).byIDs([])
        XCTAssertTrue(none.isEmpty)
        XCTAssertTrue(transport.requests.isEmpty)

        _ = try await CodeMemoryAPI(api: api).byIDs(["x", "y"])
        XCTAssertEqual(transport.lastPath, "/api/code-memory/entries")
        XCTAssertEqual(transport.lastQuery, ["ids": "x,y"])
    }

    func testUpdatePostsIDContentAndOptionalEntryType() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["ok": true])
        try await CodeMemoryAPI(api: api).update(id: "e1", content: "new body")
        XCTAssertEqual(transport.lastMethod, "POST")
        XCTAssertEqual(transport.lastPath, "/api/code-memory/update")
        assertJSONEqual(transport.lastBody(), ["id": "e1", "content": "new body"])

        transport.enqueue(json: ["ok": true])
        try await CodeMemoryAPI(api: api).update(id: "e1", content: "b", entryType: "decision")
        assertJSONEqual(transport.lastBody(),
                        ["id": "e1", "content": "b", "entry_type": "decision"])
    }

    func testDeleteEntryPrefersTheIDFormAndFallsBackToSlugKindTS() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["ok": true])
        try await CodeMemoryAPI(api: api).deleteEntry(id: "e1")
        XCTAssertEqual(transport.lastMethod, "POST")
        XCTAssertEqual(transport.lastPath, "/api/code-memory/delete-entry")
        assertJSONEqual(transport.lastBody(), ["id": "e1"])

        transport.enqueue(json: ["ok": true])
        try await CodeMemoryAPI(api: api).deleteEntry(slug: "a", kind: "knowledge", ts: "12")
        assertJSONEqual(transport.lastBody(), ["slug": "a", "kind": "knowledge", "ts": "12"])
    }

    // MARK: Stores

    @MainActor
    func testOverviewStoreKeepsProjectsWhenStatsFails() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/code-memory/stats", json: ["error": "off"], status: 500)
        transport.route("/api/code-memory/projects",
                        json: ["projects": ["a": ["name": "A", "knowledge_count": 2],
                                            "b": ["name": "B", "knowledge_count": 1]]])

        let store = CodeMemoryStore(api: CodeMemoryAPI(api: api))
        await store.refresh()

        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.overview.projects.count, 2)
        XCTAssertEqual(store.overview.totalProjects, 2)
        XCTAssertEqual(store.overview.totalKnowledge, 3)
    }

    @MainActor
    func testOverviewStoreFilterIsClientSide() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/code-memory/stats", json: JSONObject())
        transport.route("/api/code-memory/projects",
                        json: ["projects": ["alpha": ["name": "Alpha"], "beta": ["name": "Beta"]]])

        let store = CodeMemoryStore(api: CodeMemoryAPI(api: api))
        await store.refresh()
        let before = transport.requests.count

        store.filter = "alph"
        XCTAssertEqual(store.visibleProjects.map(\.slug), ["alpha"])
        XCTAssertEqual(transport.requests.count, before, "filtering must not refetch")

        store.filter = "zzz"
        XCTAssertTrue(store.filterMatchedNothing)
        store.clearFilter()
        XCTAssertEqual(store.visibleProjects.count, 2)
    }

    @MainActor
    func testEntriesStoreSearchHydratesBodiesByID() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/code-memory/search",
                        json: ["entries": [["id": "e1", "first_line": "compact"]]])
        transport.route("/api/code-memory/entries",
                        json: ["entries": [["id": "e1", "content": "full body"]]])

        let store = CodeMemoryEntriesStore(api: CodeMemoryAPI(api: api), slug: "a", kind: .knowledge)
        store.query = "cache"
        await store.refresh()

        XCTAssertEqual(store.entries.map(\.content), ["full body"])
        XCTAssertTrue(transport.paths.contains("/api/code-memory/search"))
        XCTAssertTrue(transport.paths.contains("/api/code-memory/entries"))
    }

    @MainActor
    func testEntriesStoreFallsBackToCompactRowsWhenHydrationFails() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/code-memory/search",
                        json: ["entries": [["id": "e1", "first_line": "compact"]]])
        transport.route("/api/code-memory/entries", json: ["error": "boom"], status: 500)

        let store = CodeMemoryEntriesStore(api: CodeMemoryAPI(api: api), slug: "a", kind: .knowledge)
        store.query = "cache"
        await store.refresh()

        XCTAssertEqual(store.entries.map(\.firstLine), ["compact"])
        XCTAssertNil(store.errorMessage)
    }

    @MainActor
    func testEntriesStoreRefusesAnEmptyEditAndAnIDLessEntry() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/code-memory", json: ["entries": []])

        let store = CodeMemoryEntriesStore(api: CodeMemoryAPI(api: api), slug: "a", kind: .knowledge)
        let idLess = await store.update(CodeMemoryEntry(id: ""), content: "x")
        XCTAssertFalse(idLess)
        XCTAssertEqual(store.toast, "This entry has no id; cannot edit.")

        let blank = await store.update(CodeMemoryEntry(id: "e1"), content: "   ")
        XCTAssertFalse(blank)
        XCTAssertEqual(store.toast, "Content cannot be empty.")
        XCTAssertTrue(transport.requests.isEmpty)
    }

    @MainActor
    func testEntriesStoreDeleteFallsBackToSlugKindTSWithoutAnID() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/code-memory/delete-entry", json: ["ok": true])
        transport.route("/api/code-memory", json: ["entries": []])

        let store = CodeMemoryEntriesStore(api: CodeMemoryAPI(api: api), slug: "a", kind: .sessions)
        let entry = CodeMemoryEntry(json: ["ts": "99"])
        let ok = await store.delete(entry)

        XCTAssertTrue(ok)
        assertJSONEqual(transport.body(0), ["slug": "a", "kind": "sessions", "ts": "99"])
        XCTAssertEqual(store.toast, "Entry deleted.")
        XCTAssertEqual(store.mutationCount, 1)
    }
}

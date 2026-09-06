import Foundation
import XCTest
@testable import JarvisCopilot

/// Ported from `mobile_client/test/insights_test.dart`, case for case, plus the
/// health/wiki/message parsing and the fan-out load from `insights_page.dart`.
final class InsightsTests: XCTestCase {

    // MARK: formatTokenCount

    func testInsertsThousandsSeparators() {
        XCTAssertEqual(Insights.formatTokenCount(1234), "1,234")
        XCTAssertEqual(Insights.formatTokenCount(1_234_567), "1,234,567")
    }

    func testLeavesSmallNumbersUnchanged() {
        XCTAssertEqual(Insights.formatTokenCount(0), "0")
        XCTAssertEqual(Insights.formatTokenCount(42), "42")
        XCTAssertEqual(Insights.formatTokenCount(999), "999")
    }

    func testHandlesNegatives() {
        XCTAssertEqual(Insights.formatTokenCount(-1234), "-1,234")
    }

    func testCoercesNumericStringsAndNil() {
        XCTAssertEqual(Insights.formatTokenCount("1234"), "1,234")
        XCTAssertEqual(Insights.formatTokenCount("1,234"), "1,234")
        XCTAssertEqual(Insights.formatTokenCount("$2,500"), "2,500")
        XCTAssertEqual(Insights.formatTokenCount(nil), "0")
        XCTAssertEqual(Insights.formatTokenCount("nope"), "0")
    }

    func testRoundsNonIntegers() {
        XCTAssertEqual(Insights.formatTokenCount(1234.7), "1,235")
    }

    // MARK: formatTokensCompact

    func testCompactsThousandsAndMillions() {
        XCTAssertEqual(Insights.formatTokensCompact(0), "0")
        XCTAssertEqual(Insights.formatTokensCompact(999), "999")
        XCTAssertEqual(Insights.formatTokensCompact(1500), "1.5K")
        XCTAssertEqual(Insights.formatTokensCompact(2_500_000), "2.5M")
    }

    // MARK: formatCost

    func testShowsEmDashAtOrBelowZero() {
        XCTAssertEqual(Insights.formatCost(0), "—")
        XCTAssertEqual(Insights.formatCost(nil), "—")
        XCTAssertEqual(Insights.formatCost(-1), "—")
    }

    func testFourDecimalsUnderADollarTwoOver() {
        XCTAssertEqual(Insights.formatCost(0.1234), "$0.1234")
        XCTAssertEqual(Insights.formatCost(12.5), "$12.50")
    }

    func testParsesStringCosts() {
        XCTAssertEqual(Insights.formatCost("$3.50"), "$3.50")
    }

    // MARK: parseModelStats

    func testParsesTheRealListOfObjectsShape() {
        let rows = Insights.parseModelStats([
            ["model": "claude-code", "sessions": 5, "input_tokens": 100,
             "output_tokens": 50, "total_tokens": 150, "cost": 0.42],
            ["model": "sonnet", "sessions": 2, "total_tokens": 30, "cost": 0.0],
        ])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first?.model, "claude-code")
        XCTAssertEqual(rows.first?.totalTokens, 150)
        XCTAssertEqual(rows.first?.cost, 0.42)
    }

    func testToleratesALegacyMapKeyedByModelShape() {
        let rows = Insights.parseModelStats([
            "claude-code": ["sessions": 3, "total_tokens": 99],
            "unknown": ["sessions": 1, "total_tokens": 1],
        ] as JSONObject)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.model)), ["claude-code", "unknown"])
    }

    func testDefaultsAMissingModelNameToUnknown() {
        let rows = Insights.parseModelStats([["sessions": 1, "total_tokens": 5]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].model, "unknown")
    }

    func testReturnsEmptyForNilOrNonCollectionInput() {
        XCTAssertTrue(Insights.parseModelStats(nil).isEmpty)
        XCTAssertTrue(Insights.parseModelStats(42).isEmpty)
        XCTAssertTrue(Insights.parseModelStats("x").isEmpty)
    }

    // MARK: parseRows

    func testNormalisesAListOfMaps() {
        let rows = Insights.parseRows([
            ["date": "2026-06-01", "input_tokens": 10],
            ["date": "2026-06-02", "input_tokens": 20],
        ])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(MoreJSON.int(rows[1]["input_tokens"]), 20)
    }

    func testReturnsEmptyForNonListInput() {
        XCTAssertTrue(Insights.parseRows(nil).isEmpty)
        XCTAssertTrue(Insights.parseRows(["messages": []] as JSONObject).isEmpty)
    }

    // MARK: insightsNum

    func testCoercesIntsDoublesStringsAndNil() {
        XCTAssertEqual(Insights.number(5), 5)
        XCTAssertEqual(Insights.number(2.5), 2.5)
        XCTAssertEqual(Insights.number("7"), 7)
        XCTAssertEqual(Insights.number("$1,000"), 1000)
        XCTAssertEqual(Insights.number(nil), 0)
    }

    // MARK: formatBytes + system health

    func testFormatBytesRounding() {
        XCTAssertEqual(Insights.formatBytes(512), "512 B")
        XCTAssertEqual(Insights.formatBytes(1536), "1.5 KB")
        XCTAssertEqual(Insights.formatBytes(1024 * 1024 * 12), "12 MB")
        XCTAssertEqual(Insights.formatBytes(0), "0 B")
    }

    func testSystemHealthPercentClampsAndTolerates() {
        XCTAssertEqual(Insights.systemHealthPercent(["percent": 42] as JSONObject), 42)
        XCTAssertEqual(Insights.systemHealthPercent(["percent": 150] as JSONObject), 100)
        XCTAssertEqual(Insights.systemHealthPercent(["percent": -3] as JSONObject), 0)
        XCTAssertNil(Insights.systemHealthPercent(JSONObject()))
        XCTAssertNil(Insights.systemHealthPercent(nil))
        XCTAssertNil(Insights.systemHealthPercent("nope"))
    }

    func testSystemHealthBytesLabel() {
        XCTAssertEqual(Insights.systemHealthBytesLabel(
            ["used_bytes": 1024 * 1024 * 512, "total_bytes": 1024 * 1024 * 1024 * 8] as JSONObject),
                       "512 MB / 8.0 GB")
        // CPU has no byte counts.
        XCTAssertEqual(Insights.systemHealthBytesLabel(["percent": 10] as JSONObject), "")
        XCTAssertEqual(Insights.systemHealthBytesLabel(
            ["used_bytes": 1, "total_bytes": 0] as JSONObject), "")
        XCTAssertEqual(Insights.systemHealthBytesLabel(nil), "")
    }

    // MARK: messageComposition

    func testMessageCompositionDropsNonPositiveEntries() {
        let out = Insights.messageComposition([
            "composition": ["sections": ["system": 120, "tools": 0, "history": "45", "junk": -1]],
        ])
        XCTAssertEqual(out["system"], 120)
        XCTAssertEqual(out["history"], 45)
        XCTAssertNil(out["tools"])
        XCTAssertNil(out["junk"])
    }

    func testMessageCompositionEmptyWhenAbsent() {
        XCTAssertTrue(Insights.messageComposition([:]).isEmpty)
        XCTAssertTrue(Insights.messageComposition(["composition": "nope"]).isEmpty)
    }

    // MARK: Timestamps + period options

    func testFormatTimestamp() {
        XCTAssertEqual(Insights.formatTimestamp(nil), "Never")
        XCTAssertEqual(Insights.formatTimestamp("not a date"), "not a date")
        let out = Insights.formatTimestamp("2026-06-21T10:00:00Z")
        XCTAssertNotNil(out.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$"#,
                                  options: .regularExpression), out)
    }

    func testPeriodOptions() {
        XCTAssertEqual(Insights.periodOptions.map(\.days), [7, 30, 90, 365])
        XCTAssertEqual(Insights.periodOptions.map(\.label), ["7d", "30d", "90d", "1y"])
    }

    // MARK: API requests

    func testOverviewSendsDays() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: [
            "period_days": 7, "total_sessions": 4, "total_messages": 20,
            "total_tokens": 900, "total_cost": 1.5,
            "models": [["model": "claude-code", "cost": 1.5]],
            "daily_tokens": [["date": "2026-06-01"]],
            "activity_by_day": [["day": "Mon", "sessions": 2]],
            "activity_by_hour": [["hour": 9, "sessions": 1]],
        ])
        let overview = try await InsightsAPI(api: api).overview(days: 7)

        XCTAssertEqual(transport.lastMethod, "GET")
        XCTAssertEqual(transport.lastPath, "/api/insights")
        XCTAssertEqual(transport.lastQuery, ["days": "7"])
        XCTAssertEqual(overview.periodDays, 7)
        XCTAssertEqual(overview.totalSessions, 4)
        XCTAssertEqual(overview.models.map(\.model), ["claude-code"])
        XCTAssertEqual(overview.dailyTokens.count, 1)
        XCTAssertEqual(overview.activityByDay.count, 1)
        XCTAssertEqual(overview.activityByHour.count, 1)
        XCTAssertFalse(overview.isEmpty)
    }

    func testSystemHealthParsesAndNeverThrows() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: [
            "status": "ok", "available": true, "checked_at": "2026-06-21T10:00:00Z",
            "cpu": ["percent": 23],
            "memory": ["used_bytes": 1024, "total_bytes": 4096, "percent": 25],
            "disk": ["used_bytes": 2048, "total_bytes": 8192, "percent": 25],
            "errors": [],
        ])
        var health = await InsightsAPI(api: api).systemHealth()
        XCTAssertEqual(transport.lastPath, "/api/system/health")
        XCTAssertEqual(health.cpuPercent, 23)
        XCTAssertEqual(health.memoryLabel, "1.0 KB / 4.0 KB")
        XCTAssertFalse(health.isEmpty)

        transport.enqueue(json: ["error": "boom"], status: 500)
        health = await InsightsAPI(api: api).systemHealth()
        XCTAssertTrue(health.isEmpty)
        XCTAssertNil(health.cpuPercent)
    }

    func testWikiStatusParsesAndDegradesToAnErrorShape() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: [
            "available": true, "enabled": true, "status": "ready",
            "entry_count": 12, "page_count": 3, "raw_source_count": 40,
            "last_updated": "2026-06-21T10:00:00Z", "last_writer": "jarvis",
            "path_configured": true, "docs_url": "https://x",
        ])
        var wiki = await InsightsAPI(api: api).wikiStatus()
        XCTAssertEqual(transport.lastPath, "/api/wiki/status")
        XCTAssertEqual(wiki.entryCount, 12)
        XCTAssertTrue(wiki.enabled)
        XCTAssertFalse(wiki.lastUpdatedLabel.isEmpty)

        transport.enqueue(error: URLError(.notConnectedToInternet))
        wiki = await InsightsAPI(api: api).wikiStatus()
        XCTAssertEqual(wiki.status, "error")
    }

    func testMessagesNeedsASessionIDAndParsesComposition() async {
        let (api, transport) = JarvisAPI.mocked()
        let none = await InsightsAPI(api: api).messages(sessionID: nil)
        XCTAssertTrue(none.isEmpty)
        XCTAssertTrue(transport.requests.isEmpty)

        transport.enqueue(json: ["messages": [[
            "turn": 3, "timestamp": "2026-06-21T10:00:00Z", "model": "claude-code",
            "provider": "anthropic", "input_tokens": 100, "output_tokens": 40,
            "cache_read_tokens": 10, "cache_write_tokens": 5, "reasoning_tokens": 2,
            "latency_s": 1.25,
            "composition": ["sections": ["system": 50, "history": 50]],
        ]]])
        let messages = await InsightsAPI(api: api).messages(sessionID: "s1")

        XCTAssertEqual(transport.lastMethod, "GET")
        XCTAssertEqual(transport.lastPath, "/api/insights/messages")
        XCTAssertEqual(transport.lastQuery, ["session_id": "s1"])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].turn, 3)
        XCTAssertEqual(messages[0].latencySeconds, 1.25)
        XCTAssertEqual(messages[0].composition["system"], 50)
    }

    // MARK: Store

    @MainActor
    func testStoreFansOutAndDegradesSections() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/insights/messages", json: ["messages": [["turn": 1]]])
        transport.route("/api/insights", json: ["total_sessions": 3])
        transport.route("/api/system/health", json: ["error": "off"], status: 500)
        transport.route("/api/wiki/status", json: ["error": "off"], status: 500)
        transport.route("/api/sessions", json: ["sessions": [["session_id": "s1",
                                                              "updated_at": 5]]])

        let store = InsightsStore(api: InsightsAPI(api: api))
        await store.refresh()

        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.overview.totalSessions, 3)
        XCTAssertTrue(store.health.isEmpty)
        XCTAssertEqual(store.wiki.status, "error")
        XCTAssertTrue(store.showsMessages)
        XCTAssertEqual(store.messages.count, 1)
    }

    @MainActor
    func testStoreHidesMessagesWithNoOpenSession() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/insights", json: ["total_sessions": 0])
        transport.route("/api/system/health", json: JSONObject())
        transport.route("/api/wiki/status", json: JSONObject())
        transport.route("/api/sessions", json: ["sessions": []])

        let store = InsightsStore(api: InsightsAPI(api: api))
        await store.refresh()

        XCTAssertFalse(store.showsMessages)
        XCTAssertTrue(store.messages.isEmpty)
    }

    @MainActor
    func testStoreSetDaysReloadsWithTheNewWindow() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/insights/messages", json: ["messages": []])
        transport.route("/api/insights", json: ["total_sessions": 1])
        transport.route("/api/system/health", json: JSONObject())
        transport.route("/api/wiki/status", json: JSONObject())
        transport.route("/api/sessions", json: ["sessions": []])

        let store = InsightsStore(api: InsightsAPI(api: api))
        XCTAssertEqual(store.days, 30)
        store.setDays(90)
        XCTAssertEqual(store.days, 90)
        await store.refresh()

        let insightsQueries = transport.requests
            .filter { $0.url?.path == "/api/insights" }
            .compactMap { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.query }
        XCTAssertTrue(insightsQueries.contains("days=90"), "\(insightsQueries)")
    }

    @MainActor
    func testStoreSurfacesAnOverviewFailureButKeepsSideSections() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/insights/messages", json: ["messages": []])
        transport.route("/api/insights", json: ["error": "analytics off"], status: 503)
        transport.route("/api/system/health", json: ["available": true, "cpu": ["percent": 10]])
        transport.route("/api/wiki/status", json: ["available": true, "entry_count": 4])
        transport.route("/api/sessions", json: ["sessions": []])

        let store = InsightsStore(api: InsightsAPI(api: api))
        await store.refresh()

        XCTAssertEqual(store.errorMessage, "analytics off")
        XCTAssertEqual(store.health.cpuPercent, 10)
        XCTAssertEqual(store.wiki.entryCount, 4)
        XCTAssertTrue(store.isEmpty)
    }
}

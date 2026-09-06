import SwiftUI
import XCTest
@testable import JarvisCopilot

/// `InsightsUI` shapes every number the Insights screen draws, so it carries the
/// bugs a chart would otherwise hide (empty windows, zero totals, unknown
/// section keys). The hosting tests then prove the body builds for a loaded and
/// a failed load.
@MainActor
final class InsightsUITests: XCTestCase {

    // MARK: Daily bars

    func testDailyBarsDropLeadingEmptyDaysAndKeepTheLastThirty() {
        var rows: [JSONObject] = (0..<10).map { ["date": "2026-05-0\($0 % 10)"] }
        rows += (0..<40).map { ["date": "2026-06-\($0)", "input_tokens": 100, "output_tokens": 50] }
        let bars = InsightsUI.dailyBars(rows)
        XCTAssertEqual(bars.count, 30)
        XCTAssertEqual(bars.first?.total, 150)
    }

    func testDailyBarsKeepAllZeroWindowAsASingleBar() {
        // Every day empty: the trim must stop at the last element, not run off.
        let bars = InsightsUI.dailyBars([["date": "2026-06-19"], ["date": "2026-06-20"]])
        XCTAssertEqual(bars.count, 1)
        XCTAssertFalse(InsightsUI.hasUsage(bars))
    }

    func testDailyBarsOnEmptyInput() {
        XCTAssertTrue(InsightsUI.dailyBars([]).isEmpty)
        XCTAssertFalse(InsightsUI.hasUsage([]))
    }

    func testDayLabelDropsTheYear() {
        XCTAssertEqual(InsightsUI.dayLabel("2026-06-21"), "06-21")
        XCTAssertEqual(InsightsUI.dayLabel("6-21"), "6-21")
        XCTAssertEqual(InsightsUI.dayLabel(nil), "")
    }

    func testThinnedLabelsKeepAboutSixTicks() {
        let labels = (0..<30).map { "d\($0)" }
        let shown = InsightsChartStyle.thinnedLabels(labels)
        XCTAssertEqual(shown.count, 6)
        XCTAssertEqual(shown.first, "d0")
        // A short axis is never thinned.
        XCTAssertEqual(InsightsChartStyle.thinnedLabels(["a", "b", "c"]).count, 3)
    }

    // MARK: Activity

    func testHourBarsClampToTheDayAndSumDuplicates() {
        let bars = InsightsUI.hourBars([["hour": 9, "sessions": 2],
                                        ["hour": 9, "sessions": 3],
                                        ["hour": 24, "sessions": 99],
                                        ["hour": -1, "sessions": 99],
                                        ["hour": 0, "sessions": 1]])
        XCTAssertEqual(bars.map(\.hour), [0, 9])
        XCTAssertEqual(bars.last?.sessions, 5)
        XCTAssertEqual(bars.first?.label, "00")
    }

    func testDayBarsDropUnlabelledRows() {
        let bars = InsightsUI.dayBars([["day": "Mon", "sessions": 3], ["sessions": 9]])
        XCTAssertEqual(bars.map(\.day), ["Mon"])
    }

    // MARK: Composition

    func testCompositionSlicesSortBySizeAndSumToOneHundred() {
        let slices = InsightsUI.compositionSlices(["identity": 100, "memory": 300])
        XCTAssertEqual(slices.map(\.key), ["memory", "identity"])
        XCTAssertEqual(slices[0].percent, 75, accuracy: 0.001)
        XCTAssertEqual(slices.map(\.percent).reduce(0, +), 100, accuracy: 0.001)
    }

    func testCompositionSlicesDropNonPositiveAndEmptyTotals() {
        XCTAssertTrue(InsightsUI.compositionSlices([:]).isEmpty)
        XCTAssertTrue(InsightsUI.compositionSlices(["a": 0, "b": -5]).isEmpty)
    }

    func testCompositionTiesAreOrderedStablyByKey() {
        let slices = InsightsUI.compositionSlices(["b": 10, "a": 10])
        XCTAssertEqual(slices.map(\.key), ["a", "b"])
    }

    func testSectionLabelAndColourFallBackForUnknownKeys() {
        XCTAssertEqual(InsightsUI.sectionLabel("identity"), "Identity / SOUL.md")
        XCTAssertEqual(InsightsUI.sectionLabel("system_message"), "system_message")
        XCTAssertEqual(InsightsUI.sectionColorHex("identity"), 0x7C5CFF)
        XCTAssertEqual(InsightsUI.sectionColorHex("system_message"), 0x6B7280)
    }

    // MARK: Health + wiki

    func testHealthIsAvailableOnlyWithAMetric() {
        XCTAssertFalse(InsightsUI.healthIsAvailable(SystemHealth()))
        XCTAssertFalse(InsightsUI.healthIsAvailable(SystemHealth(json: ["status": "ok"])))
        XCTAssertTrue(InsightsUI.healthIsAvailable(
            SystemHealth(json: MoreUIBFixtures.systemHealth)))
    }

    func testMetricPercentTextAndTone() {
        XCTAssertEqual(InsightsUI.metricPercentText(41), "41%")
        XCTAssertEqual(InsightsUI.metricPercentText(41.5), "41.5%")
        XCTAssertEqual(InsightsUI.metricTone(10), .cyan)
        XCTAssertEqual(InsightsUI.metricTone(70), .accentAlt)
        XCTAssertEqual(InsightsUI.metricTone(93.2), .danger)
    }

    func testHealthBadgeMarksPartialHosts() {
        XCTAssertEqual(InsightsUI.healthBadge(SystemHealth(json: ["status": "ok"])).label, "LIVE")
        let partial = InsightsUI.healthBadge(SystemHealth(json: ["status": "partial"]))
        XCTAssertEqual(partial.label, "PARTIAL")
        XCTAssertEqual(partial.tone, .blue)
    }

    func testWikiBadgeCoversEveryState() {
        func badge(_ json: JSONObject) -> String { InsightsUI.wikiBadge(WikiStatus(json: json)).label }
        XCTAssertEqual(badge(["available": true, "status": "ready"]), "Available")
        XCTAssertEqual(badge(["available": true, "status": "empty"]), "Empty")
        XCTAssertEqual(badge(["status": "error"]), "Error")
        XCTAssertEqual(badge([:]), "Unavailable")
    }

    func testWikiNoteQuotesTheServerError() {
        let note = InsightsUI.wikiNote(WikiStatus(json: ["status": "error", "error": "no path"]))
        XCTAssertTrue(note.contains("no path"), note)
    }

    func testWikiTilesAreTheSixFlutterRows() {
        let tiles = InsightsUI.wikiTiles(WikiStatus(json: MoreUIBFixtures.wikiStatus))
        XCTAssertEqual(tiles.map(\.label),
                       ["Enabled", "Entries", "Pages", "Raw files", "Last updated", "Last writer"])
        XCTAssertEqual(tiles[1].value, "1,234")
        XCTAssertEqual(tiles[5].value, "jarvis")
    }

    func testWikiLastWriterFallsBackWhenAbsent() {
        XCTAssertEqual(InsightsUI.wikiTiles(WikiStatus(json: [:]))[5].value, "Not available")
    }

    // MARK: Models

    func testModelShareFallsBackFromCostToTokensToSessions() {
        var stat = ModelStat(json: ["model": "m", "cost_share": 40.6])
        XCTAssertEqual(InsightsUI.modelShare(stat), 41)
        stat = ModelStat(json: ["model": "m", "token_share": 12])
        XCTAssertEqual(InsightsUI.modelShare(stat), 12)
        stat = ModelStat(json: ["model": "m", "session_share": 7])
        XCTAssertEqual(InsightsUI.modelShare(stat), 7)
    }

    func testModelSubtitleReadsAsTheFlutterRow() {
        let stat = ModelStat(json: ["model": "m", "sessions": 1234,
                                    "total_tokens": 1_500_000, "cost_share": 85.2])
        XCTAssertEqual(InsightsUI.modelSubtitle(stat), "1,234 sessions · 1.5M tokens · 85% share")
    }

    // MARK: Hosting

    private func loadedStore() async -> InsightsStore {
        let (api, transport) = JarvisAPI.mocked()
        // Routed by substring, first match wins — the messages route has to be
        // registered before the bare /api/insights prefix that also matches it.
        transport.route("/api/insights/messages", json: MoreUIBFixtures.insightsMessages)
        transport.route("/api/insights", json: MoreUIBFixtures.insightsOverview)
        transport.route("/api/system/health", json: MoreUIBFixtures.systemHealth)
        transport.route("/api/wiki/status", json: MoreUIBFixtures.wikiStatus)
        transport.route("/api/sessions", json: MoreUIBFixtures.sessions)
        let store = InsightsStore(api: InsightsAPI(api: api))
        await store.refresh()
        return store
    }

    func testLoadedPageRenders() async {
        let store = await loadedStore()
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.overview.totalSessions, 42)
        XCTAssertTrue(store.showsMessages)
        moreUIBHost(NavigationStack { InsightsPage(store: store) })
    }

    func testErrorPageRenders() async {
        let (api, _) = JarvisAPI.mocked()      // nothing queued → every call fails
        let store = InsightsStore(api: InsightsAPI(api: api))
        await store.refresh()

        XCTAssertFalse(store.errorMessage?.isEmpty ?? true)
        XCTAssertTrue(store.overview.isEmpty)
        XCTAssertTrue(store.hasLoaded)
        // The host's health fetch failed too — that renders "Unavailable"
        // rather than hiding the section (silent-failures M21).
        XCTAssertTrue(store.health.failed)
        moreUIBHost(NavigationStack { InsightsPage(store: store) })
    }
}

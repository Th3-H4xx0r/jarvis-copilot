import Foundation
import XCTest
@testable import JarvisCopilot

/// Ported from `mobile_client/test/quota_test.dart`. The parsing group is a
/// case-for-case port; the four `QuotaUsageCard` **widget** cases are not
/// portable here (this wave has no views), so their *logic* is asserted against
/// `QuotaWindow`/`QuotaStore` instead — see the "card logic" section.
final class QuotaTests: XCTestCase {

    // MARK: QuotaProvider/QuotaWindow parsing

    func testParsesProvidersAndWindows() {
        let raw: JSONObject = [
            "provider": "claude-code",
            "display_name": "Claude Code",
            "plan": "Max",
            "windows": [
                ["label": "Current session", "used_percent": 45.0,
                 "remaining_percent": 55.0, "reset_at": "2030-03-17T17:30:00Z",
                 "detail": NSNull()],
                ["label": "Current week", "used_percent": 18,
                 "remaining_percent": 82, "reset_at": NSNull(),
                 "detail": "Opus + Sonnet"],
            ],
            "details": ["Extra usage: 1.20 / 50.00 USD", ""],
            "fetched_at": "2030-03-17T12:30:00Z",
        ]
        let p = QuotaProvider(json: raw)

        XCTAssertEqual(p.provider, "claude-code")
        XCTAssertEqual(p.displayName, "Claude Code")
        XCTAssertEqual(p.plan, "Max")
        XCTAssertEqual(p.windows.count, 2)
        XCTAssertEqual(p.windows[0].label, "Current session")
        XCTAssertEqual(p.windows[0].usedPercent, 45.0)
        XCTAssertEqual(p.windows[0].remainingPercent, 55.0)
        XCTAssertNotNil(p.windows[0].resetAt)
        XCTAssertNil(p.windows[0].detail)
        XCTAssertEqual(p.windows[1].usedPercent, 18.0)
        XCTAssertEqual(p.windows[1].detail, "Opus + Sonnet")
        XCTAssertNil(p.windows[1].resetAt)
        // The empty detail string is dropped.
        XCTAssertEqual(p.details, ["Extra usage: 1.20 / 50.00 USD"])
        XCTAssertNotNil(p.fetchedAt)
    }

    func testToleratesMissingFieldsAndANullUsedPercent() {
        let p = QuotaProvider(json: [
            "provider": "openai-codex",
            "windows": [
                ["label": "Session", "used_percent": NSNull()],
                ["label": ""],   // dropped — no label
            ],
        ])
        XCTAssertEqual(p.displayName, "openai-codex")
        XCTAssertEqual(p.windows.count, 1)
        XCTAssertNil(p.windows[0].usedPercent)
        XCTAssertNil(p.plan)
        XCTAssertTrue(p.details.isEmpty)
        XCTAssertNil(p.fetchedAt)
    }

    // MARK: Card logic (from widgets/quota_card.dart)

    func testPercentTextRendersTheUsedValueOrAnEmDash() {
        XCTAssertEqual(QuotaWindow(label: "S", usedPercent: 45).percentText, "45%")
        XCTAssertEqual(QuotaWindow(label: "S", usedPercent: 45.6).percentText, "46%")
        XCTAssertEqual(QuotaWindow(label: "S", usedPercent: 140).percentText, "100%")
        // Only a remainder reported → used is derived.
        XCTAssertEqual(QuotaWindow(label: "S", remainingPercent: 39).percentText, "61%")
        // Nothing reported → "—" with an empty bar, never a fake value.
        XCTAssertEqual(QuotaWindow(label: "S").percentText, "—")
        XCTAssertEqual(QuotaWindow(label: "S").barFraction, 0)
    }

    func testBarFractionAndTone() {
        XCTAssertEqual(QuotaWindow(label: "S", usedPercent: 45).barFraction, 0.45, accuracy: 0.0001)
        XCTAssertEqual(QuotaWindow(label: "S", usedPercent: 45).barTone, .normal)
        XCTAssertEqual(QuotaWindow(label: "S", usedPercent: 75).barTone, .warning)
        XCTAssertEqual(QuotaWindow(label: "S", usedPercent: 90).barTone, .critical)
        XCTAssertEqual(QuotaWindow(label: "S").barTone, .unknown)
    }

    func testResetTextCountsDown() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        func window(_ offset: TimeInterval) -> QuotaWindow {
            QuotaWindow(label: "S", usedPercent: 10, resetAt: now.addingTimeInterval(offset))
        }
        XCTAssertEqual(window(-1).resetText(now: now), "resets now")
        XCTAssertEqual(window(30).resetText(now: now), "resets in <1m")
        XCTAssertEqual(window(15 * 60).resetText(now: now), "resets in 15m")
        XCTAssertEqual(window(2 * 3600 + 15 * 60).resetText(now: now), "resets in 2h 15m")
        XCTAssertEqual(window(3 * 86400 + 4 * 3600).resetText(now: now), "resets in 3d 4h")
        XCTAssertNil(QuotaWindow(label: "S").resetText(now: now))
    }

    func testSubtitleJoinsResetAndDetail() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let both = QuotaWindow(label: "S", usedPercent: 1,
                               resetAt: now.addingTimeInterval(600), detail: "Opus + Sonnet")
        XCTAssertEqual(both.subtitle(now: now), "resets in 10m · Opus + Sonnet")
        XCTAssertEqual(QuotaWindow(label: "S", detail: "Opus").subtitle(now: now), "Opus")
        XCTAssertEqual(QuotaWindow(label: "S").subtitle(now: now), "")
    }

    func testHeaderTitleAppendsThePlanAndIconsPerProvider() {
        XCTAssertEqual(QuotaProvider(json: ["provider": "claude-code",
                                            "display_name": "Claude Code",
                                            "plan": "Max"]).headerTitle,
                       "Claude Code · Max")
        XCTAssertEqual(QuotaProvider(json: ["provider": "claude-code",
                                            "display_name": "Claude Code"]).headerTitle,
                       "Claude Code")
        XCTAssertEqual(QuotaProvider(json: ["provider": "claude-code"]).iconName, "bolt.fill")
        XCTAssertEqual(QuotaProvider(json: ["provider": "anthropic"]).iconName, "bolt.fill")
        XCTAssertEqual(QuotaProvider(json: ["provider": "openai-codex"]).iconName, "cpu")
        XCTAssertEqual(QuotaProvider(json: ["provider": "openrouter"]).iconName,
                       "arrow.triangle.branch")
        XCTAssertEqual(QuotaProvider(json: ["provider": "other"]).iconName, "speedometer")
    }

    func testHasLimitsIsFalseWithNoWindows() {
        XCTAssertFalse(QuotaProvider(json: ["provider": "x"]).hasLimits)
    }

    // MARK: API requests

    func testGetAllHitsTheProviderQuotaEndpoint() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["providers": [
            ["provider": "claude-code", "windows": [["label": "Session", "used_percent": 45]]],
        ]])
        let providers = try await QuotaAPI(api: api).all()

        XCTAssertEqual(transport.lastMethod, "GET")
        XCTAssertEqual(transport.lastPath, "/api/provider/quota/all")
        XCTAssertEqual(transport.lastQuery, [:], "no refresh ⇒ no query")
        XCTAssertEqual(providers.map(\.provider), ["claude-code"])
    }

    func testGetAllWithRefreshSendsRefreshOne() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["providers": []])
        _ = try await QuotaAPI(api: api).all(refresh: true)
        XCTAssertEqual(transport.lastQuery, ["refresh": "1"])
    }

    // MARK: Store (the card's states)

    @MainActor
    func testStoreRendersEveryWindow() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/provider/quota/all", json: ["providers": [
            ["provider": "claude-code", "display_name": "Claude Code", "windows": [
                ["label": "Current session", "used_percent": 45, "remaining_percent": 55],
                ["label": "Current week", "used_percent": 18, "remaining_percent": 82],
            ]],
            ["provider": "openai-codex", "display_name": "OpenAI Codex", "windows": [
                ["label": "Session", "used_percent": 61, "remaining_percent": 39],
            ]],
        ]])

        let store = QuotaStore(api: QuotaAPI(api: api))
        await store.refresh(initial: true)

        XCTAssertEqual(store.providers.map(\.displayName), ["Claude Code", "OpenAI Codex"])
        let percentages = store.providers.flatMap { $0.windows.map(\.percentText) }
        XCTAssertEqual(percentages, ["45%", "18%", "61%"])
        XCTAssertFalse(store.isEmpty)
        XCTAssertFalse(store.showsRetry)
        XCTAssertFalse(store.isLoading)
    }

    @MainActor
    func testStoreNullUsedPercentShowsAnEmDashAndAnEmptyBar() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/provider/quota/all", json: ["providers": [
            ["provider": "openai-codex", "display_name": "OpenAI Codex",
             "windows": [["label": "Session"]]],
        ]])

        let store = QuotaStore(api: QuotaAPI(api: api))
        await store.refresh(initial: true)

        let window = store.providers[0].windows[0]
        XCTAssertEqual(window.percentText, "—")
        XCTAssertEqual(window.barFraction, 0)
    }

    @MainActor
    func testStoreEmptyProviderListShowsTheEmptyState() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/provider/quota/all", json: ["providers": []])

        let store = QuotaStore(api: QuotaAPI(api: api))
        await store.refresh(initial: true)

        XCTAssertTrue(store.isEmpty)
        XCTAssertEqual(store.emptyText, "No quota-capable providers configured.")
    }

    @MainActor
    func testStoreLoaderErrorShowsTheRetryNote() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/provider/quota/all", json: ["error": "boom"], status: 500)

        let store = QuotaStore(api: QuotaAPI(api: api))
        await store.refresh(initial: true)

        XCTAssertTrue(store.showsRetry)
        XCTAssertEqual(store.errorMessage, "Couldn’t load usage")
    }

    @MainActor
    func testStoreKeepsStaleDataWhenARefreshFails() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["providers": [
            ["provider": "claude-code", "windows": [["label": "S", "used_percent": 10]]],
        ]])
        let store = QuotaStore(api: QuotaAPI(api: api))
        await store.refresh(initial: true)
        XCTAssertEqual(store.providers.count, 1)

        transport.enqueue(json: ["error": "boom"], status: 500)
        await store.refresh(force: true)

        XCTAssertEqual(store.providers.count, 1, "a stale bar beats a blank card")
        XCTAssertFalse(store.showsRetry)
        XCTAssertFalse(store.isRefreshing)
    }
}

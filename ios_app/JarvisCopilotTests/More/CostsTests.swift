import Foundation
import XCTest
@testable import JarvisCopilot

/// Insights → Costs: decoding against trimmed copies of real `/api/costs`
/// payloads, the chart grouping, the headline maths and the API requests.
final class CostsTests: XCTestCase {

    // MARK: Fixtures (trimmed from real GET /api/costs?days=30 and /api/costs/service)

    private static let overviewJSON = #"""
    {
     "currency": "USD", "days": 7, "start": "2026-10-26", "end": "2026-11-01",
     "generated_at": 1793509904.45, "last_run": 1793509904.45,
     "totals": {"period": 70.0, "previous_period": 56.0, "month_to_date": 7.8107,
                "projected_month": 281.1833,
                "by_source": {"subscription": 52.5, "estimate": 17.5}},
     "budget": {"monthly_usd": 150.0, "used_pct": 5.2},
     "daily": [
      {"day": "2026-10-26", "total": 10.0, "by_service": {"claude-code": 6.0, "anthropic": 2.0, "ollama-cloud": 1.0, "custom-hetzner-vps": 0.5, "parallel": 0.3, "celeris": 0.2}},
      {"day": "2026-10-27", "total": 10.0, "by_service": {"claude-code": 6.0, "anthropic": 2.0, "ollama-cloud": 1.0, "custom-hetzner-vps": 0.5, "parallel": 0.3, "soniox": 0.2}},
      {"day": "2026-10-28", "total": 10.0, "by_service": {"claude-code": 6.0, "anthropic": 2.5, "ollama-cloud": 1.0, "custom-hetzner-vps": 0.5}},
      {"day": "2026-10-29", "total": 10.0, "by_service": {"claude-code": 6.0, "anthropic": 2.5, "ollama-cloud": 1.0, "custom-hetzner-vps": 0.5}},
      {"day": "2026-10-30", "total": 10.0, "by_service": {"claude-code": 6.0, "anthropic": 2.5, "ollama-cloud": 1.0, "custom-hetzner-vps": 0.5}},
      {"day": "2026-10-31", "total": 10.0, "by_service": {"claude-code": 6.0, "anthropic": 3.0, "ollama-cloud": 0.5, "custom-hetzner-vps": 0.5}},
      {"day": "2026-11-01", "total": 10.0, "by_service": {"claude-code": 6.0, "anthropic": 3.0, "ollama-cloud": 0.5, "custom-hetzner-vps": 0.5}}
     ],
     "services": [
      {"id": "claude-code", "name": "Claude subscription", "category": "AI models", "kind": "subscription",
       "custom": false, "status": "subscription", "detected": true, "billing_connected": false,
       "period_total": 42.0, "month_to_date": 6.6667, "sources": ["subscription"],
       "estimate_total": null, "billing_total": null, "plan_usage_usd": null,
       "units": {"calls": 206, "input_tokens": 44, "output_tokens": 62861, "cache_read_tokens": 32361311,
                 "cache_write_tokens": 0, "api_equiv_usd": 7.1017, "unpriced_calls": 1},
       "spark": [6.0, 6.0, 6.0, 6.0, 6.0, 6.0, 6.0],
       "balance_usd": null, "limit_usd": null, "balance_at": null, "last_synced": null, "error": null,
       "subscription": {"amount_usd": 200.0, "interval": "month", "plan": "Max 20×", "since": null},
       "suggested_plans": [{"label": "Pro", "amount_usd": 20, "interval": "month"},
                           {"label": "Max 20×", "amount_usd": 200, "interval": "month"}],
       "fields": [], "url": "https://claude.ai/settings/billing",
       "help": "Claude Code calls are covered by your Claude plan."},
      {"id": "anthropic", "name": "Anthropic API", "category": "AI models", "kind": "usage",
       "custom": false, "status": "estimated", "detected": true, "billing_connected": false,
       "period_total": 17.5, "month_to_date": 3.0, "sources": ["estimate"],
       "estimate_total": 17.5, "billing_total": null, "plan_usage_usd": null,
       "units": {"calls": 7649, "input_tokens": 25903, "output_tokens": 1924690,
                 "cache_read_tokens": 197726090, "cache_write_tokens": 40731018, "unpriced_calls": 0},
       "spark": [2.0, 2.0, 2.5, 2.5, 2.5, 3.0, 3.0],
       "balance_usd": 12.5, "limit_usd": 50.0, "balance_at": 1793509000, "last_synced": null, "error": null,
       "subscription": null, "suggested_plans": [],
       "fields": [{"key": "admin_key", "label": "Admin API key", "kind": "secret",
                   "placeholder": "sk-ant-admin01-…", "is_set": false}],
       "url": "https://platform.claude.com/settings/billing", "help": "Jarvis prices every Claude call."},
      {"id": "openai-codex", "name": "ChatGPT / Codex", "category": "AI models", "kind": "subscription",
       "custom": false, "status": "needs_price", "detected": true, "billing_connected": false,
       "period_total": 0.0, "month_to_date": 0.0, "sources": [], "estimate_total": null,
       "billing_total": null, "plan_usage_usd": null,
       "units": {"calls": 329, "api_equiv_usd": 0.0}, "spark": [0, 0, 0, 0, 0, 0, 0],
       "balance_usd": null, "limit_usd": null, "balance_at": null, "last_synced": null, "error": null,
       "subscription": null, "suggested_plans": [{"label": "Plus", "amount_usd": 20, "interval": "month"}],
       "fields": [], "url": "https://chatgpt.com/#settings/Subscription", "help": "Covered by the plan."},
      {"id": "parallel", "name": "Parallel", "category": "Web search", "kind": "usage", "status": "estimated",
       "period_total": 0.6, "sources": ["estimate"], "units": {"searches": 229, "from_history": true},
       "spark": [0.3, 0.3, 0, 0, 0, 0, 0], "subscription": null, "fields": []}
     ],
     "available": [
      {"id": "browserbase", "name": "Browserbase", "category": "Browser", "kind": "subscription",
       "custom": false, "status": "needs_price", "detected": false, "period_total": 0.0,
       "sources": [], "units": {}, "spark": [0, 0, 0, 0, 0, 0, 0], "subscription": null,
       "suggested_plans": [{"label": "Developer", "amount_usd": 20, "interval": "month"}],
       "fields": [{"key": "api_key", "label": "API key", "kind": "secret", "placeholder": "bb_live_…", "is_set": true},
                  {"key": "project_id", "label": "Project ID", "kind": "text", "placeholder": "Project ID", "is_set": true, "billing_only": true}],
       "url": null, "help": "Reads browser minutes and proxy data used."}
     ]
    }
    """#

    private static let detailJSON = #"""
    {
     "service": {"id": "anthropic", "name": "Anthropic API", "category": "AI models", "kind": "usage",
                 "status": "billing", "detected": true, "billing_connected": true,
                 "period_total": 13.0, "month_to_date": 0.0007, "sources": ["billing", "estimate"],
                 "estimate_total": 14.0, "billing_total": 10.0, "units": {"calls": 532},
                 "spark": [0.0, 3.0, 10.0], "subscription": null, "fields": [], "url": null, "help": ""},
     "days": 3,
     "daily": [
      {"day": "2026-10-30", "effective": 0.0, "billing": null, "estimate": null, "subscription": null,
       "source": null, "units": {}},
      {"day": "2026-10-31", "effective": 3.0, "billing": null, "estimate": 3.0, "subscription": null,
       "source": "estimate", "units": {"calls": 94}},
      {"day": "2026-11-01", "effective": 10.0, "billing": 10.0, "estimate": 11.0, "subscription": null,
       "source": "billing", "units": {"calls": 438}}
     ],
     "models": [
      {"model": "claude-sonnet-5-5", "calls": 1196, "tokens": 70013498, "cost_usd": 76.7939},
      {"model": "claude-opus-4-5-20251101", "calls": 1, "tokens": 0, "cost_usd": 0.0, "unpriced": true}
     ],
     "billing_items": [{"item": "Claude Sonnet", "cost_usd": 9.5}],
     "snapshots": [{"ts": 1793509000, "balance_usd": 12.5, "used_usd": null, "limit_usd": 50}]
    }
    """#

    private static func object(_ text: String) -> JSONObject {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? JSONObject ?? [:]
    }

    private var overview: CostsOverview { CostsOverview(json: Self.object(Self.overviewJSON)) }
    private var detail: CostServiceDetail { CostServiceDetail(json: Self.object(Self.detailJSON)) }

    // MARK: Decoding

    func testOverviewDecodesTotalsBudgetAndLists() {
        let o = overview
        XCTAssertFalse(o.isEmpty)
        XCTAssertEqual(o.days, 7)
        XCTAssertEqual(o.start, "2026-10-26")
        XCTAssertEqual(o.totals.period, 70)
        XCTAssertEqual(o.totals.previousPeriod, 56)
        XCTAssertEqual(o.totals.projectedMonth, 281.1833, accuracy: 0.0001)
        XCTAssertEqual(o.totals.bySource["estimate"], 17.5)
        XCTAssertEqual(o.budget.monthlyUSD, 150)
        XCTAssertEqual(o.budget.usedPercent, 5.2)
        XCTAssertNotNil(o.lastRun)
        XCTAssertEqual(o.daily.count, 7)
        XCTAssertEqual(o.daily[0].byService["claude-code"], 6)
        XCTAssertEqual(o.services.map(\.id), ["claude-code", "anthropic", "openai-codex", "parallel"])
        XCTAssertEqual(o.available.map(\.id), ["browserbase"])
    }

    func testSubscriptionCardDecodesPlanAndCoveredUsage() throws {
        let claude = try XCTUnwrap(overview.service("claude-code"))
        XCTAssertEqual(claude.kind, .subscription)
        XCTAssertEqual(claude.status, .subscription)
        XCTAssertEqual(claude.subscription?.amountUSD, 200)
        XCTAssertEqual(claude.subscription?.plan, "Max 20×")
        XCTAssertEqual(claude.suggestedPlans.map(\.label), ["Pro", "Max 20×"])
        XCTAssertEqual(claude.units.calls, 206)
        XCTAssertEqual(claude.units.apiEquivUSD, 7.1017)
        XCTAssertFalse(claude.isEstimate)
        XCTAssertEqual(claude.url?.host(), "claude.ai")
        XCTAssertNotNil(CostsUI.apiEquivalentLine(claude))
    }

    func testUsageCardDecodesFieldsBalanceAndEstimate() throws {
        let api = try XCTUnwrap(overview.service("anthropic"))
        XCTAssertEqual(api.status, .estimated)
        XCTAssertTrue(api.isEstimate)
        XCTAssertEqual(api.spark.count, 7)
        XCTAssertEqual(api.balanceUSD, 12.5)
        XCTAssertNotNil(api.balanceAt)
        XCTAssertEqual(api.fields.map(\.key), ["admin_key"])
        XCTAssertTrue(api.fields[0].isSecret)
        XCTAssertFalse(api.fields[0].isSet)
        XCTAssertNil(api.subscription)
        XCTAssertEqual(CostsUI.balanceText(api), "Balance $12.50 of $50.00")
    }

    func testNeedsPriceAndAvailableCards() throws {
        let codex = try XCTUnwrap(overview.service("openai-codex"))
        XCTAssertEqual(codex.status, .needsPrice)
        XCTAssertNil(CostsUI.apiEquivalentLine(codex), "a zero API equivalent says nothing")
        XCTAssertTrue(CostsUI.serviceSubtitle(codex).hasPrefix("No price set"))

        let bb = try XCTUnwrap(overview.available.first)
        XCTAssertNil(bb.url)
        XCTAssertEqual(bb.fields.map(\.isSecret), [true, false])
        XCTAssertEqual(bb.fields.map(\.isSet), [true, true])
        XCTAssertEqual(bb.fields.map(\.billingOnly), [false, true])
        XCTAssertTrue(bb.hasBillingKey, "a saved billing-only key can be disconnected")
        var mainKeyOnly = bb
        mainKeyOnly.fields[1].isSet = false
        XCTAssertFalse(mainKeyOnly.hasBillingKey, "the service's own key is managed in Settings")
        XCTAssertTrue(bb.units.isEmpty)
    }

    func testMissingFieldsDegradeInsteadOfThrowing() {
        let sparse = CostService(json: ["id": "x", "spark": [1, "2", NSNull()], "subscription": ["plan": "Pro"]])
        XCTAssertEqual(sparse.name, "x")
        XCTAssertEqual(sparse.category, "Other")
        XCTAssertEqual(sparse.kind, .usage)
        XCTAssertEqual(sparse.status, .unknown)
        XCTAssertEqual(sparse.spark, [1, 2, 0])
        XCTAssertNil(sparse.subscription, "a plan with no amount isn't a price")
        XCTAssertTrue(CostsOverview(json: [:]).isEmpty)
        XCTAssertNil(CostsTotals(json: ["previous_period": NSNull()]).previousPeriod)
        XCTAssertNil(CostsBudget(json: ["monthly_usd": NSNull()]).monthlyUSD)
    }

    func testDetailDecodesDaysModelsBillAndSnapshots() {
        let d = detail
        XCTAssertEqual(d.service.id, "anthropic")
        XCTAssertEqual(d.days, 3)
        XCTAssertEqual(d.daily.map(\.day), ["2026-10-30", "2026-10-31", "2026-11-01"])
        XCTAssertNil(d.daily[0].source)
        XCTAssertNil(d.daily[0].estimate)
        XCTAssertEqual(d.daily[2].billing, 10)
        XCTAssertEqual(d.daily[2].units.calls, 438)
        XCTAssertEqual(d.models.map(\.model), ["claude-sonnet-5-5", "claude-opus-4-5-20251101"])
        XCTAssertTrue(d.models[1].unpriced)
        XCTAssertEqual(d.billingItems.first?.costUSD, 9.5)
        XCTAssertEqual(d.snapshots.first?.limitUSD, 50)
    }

    // MARK: Detail days

    func testDetailUsesEveryDayRowsAsSent() {
        let days = CostsUI.detailDays(detail, period: ["ignored"])
        XCTAssertEqual(days.map(\.day), ["2026-10-30", "2026-10-31", "2026-11-01"])
        let bars = CostsUI.detailBars(days)
        XCTAssertEqual(bars.map(\.day), days.map(\.day), "a short window draws a bar per day")
        XCTAssertTrue(CostsUI.showsBillingVsEstimate(bars, kind: .usage))
        XCTAssertFalse(CostsUI.showsBillingVsEstimate(bars, kind: .subscription))
        XCTAssertTrue(bars[1].onlyEstimated)
        XCTAssertFalse(bars[2].onlyEstimated)
        XCTAssertTrue(CostsUI.detailReadout(bars[1]).contains("≈ $3.00"))
        XCTAssertTrue(CostsUI.detailReadout(bars[2]).contains("billed $10.00"))
    }

    func testLongServiceWindowsDrawWeeklyBars() {
        let period = CostsUI.days(endingAt: "2026-11-01", count: 90)
        let days = period.map {
            CostDetailDay(day: $0, effective: 1, estimate: 1, source: "estimate",
                          units: { var u = CostUnits(); u.calls = 2; return u }())
        }
        let bars = CostsUI.detailBars(days)
        XCTAssertEqual(bars.count, 13)
        XCTAssertEqual(bars.last?.lastDay, "2026-11-01")
        XCTAssertEqual(bars.last?.effective, 7)
        XCTAssertEqual(bars.last?.estimate, 7)
        XCTAssertNil(bars.last?.billing)
        XCTAssertEqual(bars.last?.units.calls, 14)
        XCTAssertEqual(bars.reduce(0) { $0 + $1.effective }, 90, "weekly bars keep the period total")
        XCTAssertEqual(CostsUI.bucketDays(for: 62), 1)
        XCTAssertEqual(CostsUI.bucketDays(for: 63), 7)
    }

    func testDetailFillsGapsFromAnOlderSparseServer() {
        var sparse = detail
        sparse.daily = sparse.daily.filter { $0.effective > 0 }
        let period = CostsUI.days(from: "2026-10-29", to: "2026-11-01")
        let days = CostsUI.detailDays(sparse, period: period)
        XCTAssertEqual(days.map(\.day), period)
        XCTAssertEqual(days.map(\.effective), [0, 0, 3, 10])
    }

    func testDetailPeriodFollowsTheOverviewWindow() {
        var o = CostsOverview()
        o.days = 3
        o.start = "2026-10-30"
        o.end = "2026-11-01"
        XCTAssertEqual(CostsUI.detailPeriod(detail, overview: o), ["2026-10-30", "2026-10-31", "2026-11-01"])
        // A window that doesn't match is counted back from the latest day.
        o.days = 30
        XCTAssertEqual(CostsUI.detailPeriod(detail, overview: o), ["2026-10-30", "2026-10-31", "2026-11-01"])
    }

    func testDayRangesCrossAMonthBoundary() {
        XCTAssertEqual(CostsUI.days(from: "2026-10-30", to: "2026-11-02"),
                       ["2026-10-30", "2026-10-31", "2026-11-01", "2026-11-02"])
        XCTAssertEqual(CostsUI.days(endingAt: "2026-11-01", count: 3), ["2026-10-30", "2026-10-31", "2026-11-01"])
        XCTAssertTrue(CostsUI.days(from: "2026-11-02", to: "2026-11-01").isEmpty)
    }

    // MARK: Stacked chart grouping

    func testStackKeepsTheTopFiveAndFoldsTheRestIntoOther() {
        let o = overview
        let names = Dictionary(uniqueKeysWithValues: (o.services + o.available).map { ($0.id, $0.name) })
        let stack = CostsUI.stack(daily: o.daily, names: names)

        XCTAssertEqual(stack.series.map(\.id),
                       ["claude-code", "anthropic", "ollama-cloud", "custom-hetzner-vps", "parallel", CostsUI.otherID])
        XCTAssertEqual(stack.series.map(\.slot), [0, 1, 2, 3, 4, CostsUI.otherSlot])
        XCTAssertEqual(stack.series[0].name, "Claude subscription")
        XCTAssertEqual(stack.series[2].name, "ollama-cloud", "a service with no card keeps its id")
        // celeris (0.2) and soniox (0.2) fold into Other.
        XCTAssertEqual(stack.series.last?.total ?? 0, 0.4, accuracy: 1e-9)
        XCTAssertEqual(stack.slot(for: "soniox"), CostsUI.otherSlot)
        XCTAssertEqual(stack.slot(for: "anthropic"), 1)
        XCTAssertNil(stack.slot(for: "openai-codex"), "no spend, no colour")
        XCTAssertEqual(stack.bucketDays, 1)
        XCTAssertEqual(stack.days.count, 7)
        XCTAssertEqual(stack.days[0].parts[CostsUI.otherID] ?? 0, 0.2, accuracy: 1e-9)
    }

    func testStackTotalsAgreeWithTheHeadline() {
        let o = overview
        let stack = CostsUI.stack(daily: o.daily, names: [:])
        let seriesSum = stack.series.reduce(0) { $0 + $1.total }
        let barSum = stack.days.reduce(0) { $0 + $1.total }
        let segmentSum = stack.segments.reduce(0) { $0 + $1.amount }
        XCTAssertEqual(seriesSum, o.totals.period, accuracy: 1e-6)
        XCTAssertEqual(barSum, o.totals.period, accuracy: 1e-6)
        XCTAssertEqual(segmentSum, o.totals.period, accuracy: 1e-6)
    }

    func testStackWithFewServicesHasNoOther() {
        let daily = [CostsDay(day: "2026-11-01", total: 3, byService: ["a": 1, "b": 2])]
        let stack = CostsUI.stack(daily: daily, names: ["a": "Alpha", "b": "Beta"])
        XCTAssertEqual(stack.series.map(\.name), ["Beta", "Alpha"])
        XCTAssertFalse(stack.series.contains(where: \.isOther))
        XCTAssertTrue(CostsUI.stack(daily: [], names: [:]).series.isEmpty)
    }

    func testAYearIsBucketedIntoWeeksEndingToday() {
        let days = CostsUI.days(endingAt: "2026-11-01", count: 365)
        let daily = days.map { CostsDay(day: $0, total: 1, byService: ["a": 1]) }
        let stack = CostsUI.stack(daily: daily, names: [:])
        XCTAssertEqual(stack.bucketDays, 7)
        XCTAssertEqual(stack.days.count, 53)
        XCTAssertEqual(stack.days.last?.lastDay, "2026-11-01")
        XCTAssertEqual(stack.days.last?.total, 7)
        XCTAssertEqual(stack.days.first?.total, 1, "the leftover day opens the year")
        XCTAssertEqual(stack.days.reduce(0) { $0 + $1.total }, 365)
    }

    func testWeeklyBarsSpanTheirOwnDaysWithoutOverlapping() {
        // Bars are drawn over their own dates (not snapped to calendar weeks),
        // so the 1-day bucket opening a year sits beside the first full week.
        let days = CostsUI.days(endingAt: "2026-11-01", count: 365)
        let stack = CostsUI.stack(daily: days.map { CostsDay(day: $0, total: 1, byService: ["a": 1]) }, names: [:])
        for (a, b) in zip(stack.days, stack.days.dropFirst()) {
            XCTAssertEqual(a.end, b.date, "\(a.day) ends where \(b.day) starts")
        }
        XCTAssertEqual(stack.days.last?.end, CostsUI.dayEnd("2026-11-01"))
        XCTAssertEqual(stack.days.first.map { $0.end.timeIntervalSince($0.date) } ?? 0, 86_400, accuracy: 3_600)

        let bars = CostsUI.detailBars(days.map { CostDetailDay(day: $0, effective: 1) })
        for (a, b) in zip(bars, bars.dropFirst()) { XCTAssertEqual(a.end, b.date) }
        XCTAssertTrue(bars.allSatisfy { $0.date < $0.center && $0.center < $0.end })
    }

    func testAverageBarIsTakenOverDaysNotBars() {
        let year = CostsUI.days(endingAt: "2026-11-01", count: 365)
        let stack = CostsUI.stack(daily: year.map { CostsDay(day: $0, total: 1, byService: ["a": 1]) }, names: [:])
        XCTAssertEqual(stack.dayCount, 365)
        // $1 a day is $7 a week, not $365 / 53 bars.
        XCTAssertEqual(stack.averagePerBar(total: 365), 7, accuracy: 1e-9)
        let month = CostsUI.stack(daily: overview.daily, names: [:])
        XCTAssertEqual(month.averagePerBar(total: 70), 10, accuracy: 1e-9)
        XCTAssertEqual(CostsStack().averagePerBar(total: 5), 0, "no days, no divide by zero")
    }

    func testSegmentsStackInSeriesOrder() {
        let daily = [CostsDay(day: "2026-11-01", total: 2.5, byService: ["a": 1, "b": 2, "c": -0.5])]
        let stack = CostsUI.stack(daily: daily, names: [:], top: 5)
        let segs = Dictionary(uniqueKeysWithValues: stack.segments.map { ($0.seriesID, $0) })
        XCTAssertEqual(segs["b"]?.low, 0)
        XCTAssertEqual(segs["b"]?.high, 2)
        XCTAssertEqual(segs["a"]?.low, 2)
        XCTAssertEqual(segs["a"]?.high, 3)
        // A credit (not ranked, so "Other") hangs below zero.
        XCTAssertEqual(segs[CostsUI.otherID]?.low, -0.5)
        XCTAssertEqual(segs[CostsUI.otherID]?.high, 0)
    }

    func testNonFiniteCountsDegradeInsteadOfTrapping() {
        let units = CostUnits(json: ["calls": "inf", "input_tokens": 1e300, "searches": 3])
        XCTAssertNil(units.calls)
        XCTAssertNil(units.inputTokens)
        XCTAssertEqual(units.searches, 3)
    }

    // MARK: Headline + budget

    func testDeltaPercent() {
        XCTAssertEqual(CostsUI.deltaPercent(current: 70, previous: 56) ?? 0, 25, accuracy: 1e-9)
        XCTAssertEqual(CostsUI.deltaPercent(current: 40, previous: 80) ?? 0, -50, accuracy: 1e-9)
        XCTAssertNil(CostsUI.deltaPercent(current: 10, previous: nil))
        XCTAssertNil(CostsUI.deltaPercent(current: 10, previous: 0))
        XCTAssertEqual(CostsUI.deltaText(25), "+25%")
        XCTAssertEqual(CostsUI.deltaText(-50), "−50%")
        XCTAssertEqual(CostsUI.deltaText(0.2), "0%")
        XCTAssertEqual(CostsUI.deltaTone(25), .amber)
        XCTAssertEqual(CostsUI.deltaTone(-5), .success)
    }

    func testSourceSplitSumsToThePeriodAndMarksEstimates() {
        let split = CostsUI.sourceSplit(overview.totals)
        XCTAssertEqual(split.map(\.label), ["Plans", "Estimated"])
        XCTAssertEqual(split.map(\.estimated), [false, true])
        XCTAssertEqual(split.reduce(0) { $0 + $1.amount }, overview.totals.period, accuracy: 1e-9)
        XCTAssertFalse(CostsUI.periodIsEstimate(overview.totals))
        var allEstimated = CostsTotals()
        allEstimated.bySource = ["estimate": 3]
        XCTAssertTrue(CostsUI.periodIsEstimate(allEstimated))
    }

    func testBudgetStateTonesAndProjection() throws {
        let o = overview
        let state = try XCTUnwrap(CostsUI.budgetState(totals: o.totals, budget: o.budget))
        XCTAssertEqual(state.percentUsed, 5.2)
        XCTAssertEqual(state.fraction, 7.8107 / 150, accuracy: 1e-9)
        XCTAssertTrue(state.projectedOver)
        XCTAssertEqual(state.tone, .amber)
        XCTAssertEqual(CostsUI.budgetProjection(state), "On track for $281.18 — $131.18 over")

        var totals = o.totals
        totals.projectedMonth = 100
        let fine = try XCTUnwrap(CostsUI.budgetState(totals: totals, budget: o.budget))
        XCTAssertEqual(fine.tone, .cyan)
        XCTAssertEqual(CostsUI.budgetProjection(fine), "On track for $100.00 — $50.00 to spare")

        totals.monthToDate = 160
        let over = try XCTUnwrap(CostsUI.budgetState(totals: totals, budget: o.budget))
        XCTAssertEqual(over.tone, .danger)
        XCTAssertEqual(CostsUI.budgetProjection(over), "$10.00 over budget")

        XCTAssertNil(CostsUI.budgetState(totals: totals, budget: CostsBudget()))
    }

    // MARK: Formatting

    func testMoney() {
        XCTAssertEqual(CostsUI.money(309.7117), "$309.71")
        XCTAssertEqual(CostsUI.money(84.0426, estimated: true), "≈ $84.04")
        XCTAssertEqual(CostsUI.money(0, estimated: true), "$0")
        XCTAssertEqual(CostsUI.money(0.0007), "<$0.01")
        XCTAssertEqual(CostsUI.money(1234.5), "$1,234.50")
        XCTAssertEqual(CostsUI.money(12_500), "$12,500")
        XCTAssertEqual(CostsUI.planPrice(200, interval: "month"), "$200/mo")
        XCTAssertEqual(CostsUI.planPrice(9.99, interval: "year"), "$9.99/yr")
        XCTAssertEqual(CostsUI.axisMoney(5), "$5")
        XCTAssertEqual(CostsUI.axisMoney(2.5), "$2.5")
    }

    func testParseAmount() {
        XCTAssertEqual(CostsUI.parseAmount("$20"), 20)
        XCTAssertEqual(CostsUI.parseAmount(" 1,200.50 "), 1200.5)
        XCTAssertNil(CostsUI.parseAmount("twenty"))
        XCTAssertNil(CostsUI.parseAmount("-3"))
        XCTAssertEqual(CostsUI.amountText(200), "200")
        XCTAssertEqual(CostsUI.amountText(9.99), "9.99")
    }

    func testUnitSummariesAndSubtitles() throws {
        let o = overview
        XCTAssertEqual(CostsUI.serviceSubtitle(try XCTUnwrap(o.service("claude-code"))), "Max 20× · $200/mo")
        XCTAssertEqual(CostsUI.serviceSubtitle(try XCTUnwrap(o.service("anthropic"))), "7,649 calls")
        XCTAssertEqual(CostsUI.serviceSubtitle(try XCTUnwrap(o.service("parallel"))), "229 searches")
        XCTAssertEqual(CostsUI.unitsSummary(try XCTUnwrap(o.service("anthropic")).units), "7,649 calls · 240.4M tokens")
        var units = CostUnits()
        units.audioSeconds = 1800
        XCTAssertEqual(CostsUI.unitsSummary(units), "30 min audio")
        XCTAssertEqual(CostsUI.audioDuration(5400), "1.5 h")
    }

    // MARK: API requests

    func testOverviewSendsDays() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: Self.object(Self.overviewJSON))
        let o = try await CostsAPI(api: api).overview(days: 90)
        XCTAssertEqual(transport.lastMethod, "GET")
        XCTAssertEqual(transport.lastPath, "/api/costs")
        XCTAssertEqual(transport.lastQuery, ["days": "90"])
        XCTAssertEqual(o.services.count, 4)
    }

    func testServiceDetailSendsIdAndDays() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: Self.object(Self.detailJSON))
        let d = try await CostsAPI(api: api).service("anthropic", days: 7)
        XCTAssertEqual(transport.lastPath, "/api/costs/service")
        XCTAssertEqual(transport.lastQuery, ["id": "anthropic", "days": "7"])
        XCTAssertEqual(d.models.count, 2)
    }

    func testConnectPostsFieldsAndReportsAFailedSync() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["ok": true, "pending": false, "sync": ["ok": false, "error": "401 invalid x-api-key"]])
        let result = try await CostsAPI(api: api).connect("anthropic", fields: ["admin_key": "sk-ant-admin01-abc"]).result
        XCTAssertEqual(transport.lastMethod, "POST")
        XCTAssertEqual(transport.lastPath, "/api/costs/connect")
        XCTAssertEqual(transport.lastBody()["service"] as? String, "anthropic")
        XCTAssertEqual((transport.lastBody()["fields"] as? [String: String])?["admin_key"], "sk-ant-admin01-abc")
        XCTAssertNil(transport.lastBody()["days"], "no window, no days")
        XCTAssertEqual(result, .syncFailed("401 invalid x-api-key"))
        XCTAssertTrue(result.failed)
        XCTAssertEqual(result.message, "Saved, but the sync failed: 401 invalid x-api-key")

        transport.enqueue(json: ["ok": true, "pending": true, "sync": NSNull()])
        let pending = try await CostsAPI(api: api).connect("anthropic", fields: ["admin_key": "k"]).result
        XCTAssertEqual(pending, .pending)
        XCTAssertEqual(pending.message, "Saved, syncing now")
        XCTAssertFalse(pending.failed)

        transport.enqueue(json: ["ok": true, "pending": false, "sync": ["ok": true]])
        let connected = try await CostsAPI(api: api).connect("anthropic", fields: ["admin_key": "k"]).result
        XCTAssertEqual(connected, .connected)
        XCTAssertEqual(connected.message, "Connected")

        // No sync result at all (the collector crashed, or no billing API): saved,
        // never "Connected".
        transport.enqueue(json: ["ok": true, "pending": false, "sync": NSNull()])
        let unknown = try await CostsAPI(api: api).connect("anthropic", fields: ["admin_key": "k"]).result
        XCTAssertEqual(unknown, .saved)
        XCTAssertEqual(unknown.message, "Saved")
        XCTAssertFalse(unknown.failed)

        // The new server reports incomplete keys as a failed sync.
        transport.enqueue(json: ["ok": true, "pending": false,
                                 "sync": ["ok": false, "error": "Not connected yet: a key or ID is still missing."]])
        let missing = try await CostsAPI(api: api).connect("anthropic", fields: ["admin_key": "k"]).result
        XCTAssertTrue(missing.failed)
    }

    func testConnectSendsTheWindowAndReturnsItsDetail() async throws {
        let (api, transport) = JarvisAPI.mocked()
        var body = ["ok": true, "pending": false, "sync": ["ok": true]] as JSONObject
        body["detail"] = Self.object(Self.detailJSON)
        transport.enqueue(json: body)
        let reply = try await CostsAPI(api: api).connect("anthropic", fields: ["admin_key": "k"], days: 7)
        XCTAssertEqual(transport.lastBody()["days"] as? Int, 7)
        XCTAssertEqual(reply.result, .connected)
        XCTAssertEqual(reply.detail?.service.id, "anthropic")
        XCTAssertEqual(reply.detail?.models.count, 2)

        transport.enqueue(json: ["ok": true, "pending": true, "sync": NSNull(), "detail": NSNull()])
        let bare = try await CostsAPI(api: api).connect("anthropic", fields: ["admin_key": "k"], days: 7)
        XCTAssertNil(bare.detail, "a null detail isn't an empty service")
    }

    @MainActor
    func testConnectUsesTheRepliedDetailInsteadOfRefetching() async throws {
        let (api, transport) = JarvisAPI.mocked()
        var reply = ["ok": true, "pending": false, "sync": ["ok": true]] as JSONObject
        var detail = Self.object(Self.detailJSON)
        detail["days"] = 30
        reply["detail"] = detail
        transport.route("/api/costs/connect", json: reply)
        transport.route("/api/costs", json: Self.object(Self.overviewJSON))
        let store = CostsStore(api: CostsAPI(api: api))
        let model = CostServiceModel(serviceID: "anthropic", store: store)

        let ok = await model.connect(["admin_key": "sk-ant-admin01-abc"])
        XCTAssertTrue(ok)
        XCTAssertEqual(model.actionNote, "Connected")
        XCTAssertNotNil(model.detail)
        let paths = transport.requests.compactMap { $0.url?.path }
        XCTAssertEqual(paths, ["/api/costs/connect", "/api/costs"], "the parent list reloads; the detail isn't fetched twice")
        XCTAssertEqual(store.overview.services.count, 4, "the parent list shows the change")
    }

    func testConnectSurfacesTheServersMessage() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["error": "That doesn't look like a valid Admin API key."], status: 400)
        do {
            _ = try await CostsAPI(api: api).connect("anthropic", fields: ["admin_key": "x"])
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(apiErrorLine(error), "That doesn't look like a valid Admin API key.")
        }
    }

    func testSubscriptionBudgetAndRefreshBodies() async throws {
        let (api, transport) = JarvisAPI.mocked()
        let costs = CostsAPI(api: api)

        transport.enqueue(json: ["ok": true])
        try await costs.setSubscription("claude-code", amount: 100, interval: "month", plan: "Max 5×")
        XCTAssertEqual(transport.lastPath, "/api/costs/subscription")
        XCTAssertEqual(transport.lastBody()["amount_usd"] as? Double, 100)
        XCTAssertEqual(transport.lastBody()["plan"] as? String, "Max 5×")

        transport.enqueue(json: ["ok": true, "cleared": true])
        try await costs.setSubscription("claude-code", amount: nil, interval: "month", plan: nil)
        XCTAssertTrue(transport.lastBody()["amount_usd"] is NSNull, "null clears the price")
        XCTAssertNil(transport.lastBody()["plan"])

        transport.enqueue(json: ["ok": true, "service": "custom-hetzner-vps"])
        let id = try await costs.addSubscription(name: "Hetzner VPS", amount: 12.5, interval: "month")
        XCTAssertEqual(id, "custom-hetzner-vps")
        XCTAssertNil(transport.lastBody()["service"], "a custom subscription has no service id")
        XCTAssertEqual(transport.lastBody()["name"] as? String, "Hetzner VPS")

        transport.enqueue(json: ["ok": true, "monthly_usd": NSNull()])
        try await costs.setBudget(nil)
        XCTAssertEqual(transport.lastPath, "/api/costs/budget")
        XCTAssertTrue(transport.lastBody()["monthly_usd"] is NSNull)

        transport.enqueue(json: ["ok": true])
        try await costs.refresh("anthropic")
        XCTAssertEqual(transport.lastPath, "/api/costs/refresh")
        XCTAssertEqual(transport.lastBody()["service"] as? String, "anthropic")
        XCTAssertEqual(transport.lastRequest?.timeoutInterval, CostsAPI.collectTimeout)

        transport.enqueue(json: ["ok": true, "removed_keys": 1])
        try await costs.disconnect("anthropic")
        XCTAssertEqual(transport.lastPath, "/api/costs/disconnect")
    }

    // MARK: Store

    @MainActor
    func testStoreLoadsAndGroupsTheChart() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/costs", json: Self.object(Self.overviewJSON))
        let store = CostsStore(api: CostsAPI(api: api))
        await store.reload()

        XCTAssertTrue(store.hasLoaded)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.overview.services.count, 4)
        XCTAssertEqual(store.stack.series.first?.id, "claude-code")
        XCTAssertEqual(store.slot(for: "anthropic"), 1)
        XCTAssertEqual(store.delta ?? 0, 25, accuracy: 1e-9)
        XCTAssertNotNil(store.budgetState)
    }

    @MainActor
    func testStoreSetDaysWaitsUntilTheTabIsOpened() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/costs", json: Self.object(Self.overviewJSON))
        let store = CostsStore(api: CostsAPI(api: api))
        store.setDays(90)
        XCTAssertEqual(store.days, 90)
        XCTAssertTrue(transport.requests.isEmpty, "a period change on Usage doesn't fetch costs")

        await store.reload()
        XCTAssertEqual(transport.lastQuery, ["days": "90"])
    }

    @MainActor
    func testPullToRefreshSyncsThenReloadsAndKeepsDataWhenTheSyncFails() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/costs/refresh", json: ["error": "collector busy"], status: 500)
        transport.route("/api/costs", json: Self.object(Self.overviewJSON))
        let store = CostsStore(api: CostsAPI(api: api))
        await store.refresh()

        let paths = transport.requests.compactMap { $0.url?.path }
        XCTAssertEqual(paths, ["/api/costs/refresh", "/api/costs"])
        XCTAssertTrue(store.hasContent)
        XCTAssertEqual(store.errorMessage, "Couldn't sync: collector busy")
        XCTAssertFalse(store.isSyncing)
    }

    @MainActor
    func testStoreSurfacesAnOverviewFailure() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/costs", json: ["error": "costs off"], status: 503)
        let store = CostsStore(api: CostsAPI(api: api))
        await store.reload()
        XCTAssertEqual(store.errorMessage, "costs off")
        XCTAssertFalse(store.hasContent)
    }
}

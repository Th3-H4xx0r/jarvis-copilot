import XCTest
@testable import Jarvis

/// The expanded island's tabs: Agents, Chat, Services, Music, Mail.
final class IslandTabsTests: XCTestCase {

    func testTabsAndTheirHeights() {
        XCTAssertEqual(IslandTab.allCases.first, .agents)
        XCTAssertEqual(IslandTab(rawValue: "chat"), .chat)
        XCTAssertGreaterThan(IslandTab.chat.height, IslandTab.music.height)
        for t in IslandTab.allCases where t != .agents {
            XCTAssertLessThanOrEqual(t.height, IslandController.panelSize.height)
        }
    }

    func testServiceCardDecodesTheSnapshot() {
        let c = MacServiceCard(json: ["id": "stripe", "display_name": "Stripe", "tone": "error",
                                      "headline": "$1,204 today", "reason": "2 failed payments",
                                      "sections": [["title": "Latest", "items": [
                                          ["title": "Ada", "subtitle": "$40 · failed", "url": "https://dashboard.stripe.com/x"]]]]])
        XCTAssertEqual(c.name, "Stripe")
        XCTAssertEqual(c.tone, .error)
        XCTAssertEqual(c.items.first?.title, "Ada")
        XCTAssertEqual(c.items.first?.url?.host, "dashboard.stripe.com")
        XCTAssertEqual(MacServiceCard(json: ["id": "x", "tone": "weird"]).tone, .idle)
        // Cards that need you come first.
        let sorted = MacServiceCard.sorted([MacServiceCard(json: ["id": "a", "tone": "ok"]), c])
        XCTAssertEqual(sorted.first?.id, "stripe")
    }

    func testOnlyWebLinksOpen() {
        let c = MacServiceCard(json: ["id": "x", "sections": [["items": [
            ["title": "a", "url": "javascript:alert(1)"], ["title": "b", "url": "file:///etc/passwd"],
            ["title": "c", "url": "https://ok.example"]]]]])
        XCTAssertEqual(c.items.map { $0.url?.absoluteString }, [nil, nil, "https://ok.example"])
    }

    func testPortfolioSummary() {
        let p = MacPortfolio(json: [
            "portfolio": ["total_usd": 12_345.6, "accounts": [["label": "Ledger", "total_usd": 12_000.0]]],
            "crypto": ["currency": "USD", "quotes": [["symbol": "BTC", "price": 61_000.5, "change_24h": -2.4]]],
        ])
        XCTAssertEqual(p.total, "$12,346")
        XCTAssertEqual(p.quotes.first?.symbol, "BTC")
        XCTAssertEqual(p.quotes.first?.change, "−2.4%")
        XCTAssertTrue(MacPortfolio(json: [:]).isEmpty)
    }
}

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

    @MainActor
    func testTheDemoShowsMadeUpServicesAndChatThenPutsTheRealOnesBack() {
        let model = AppModel()
        model.handle(["type": "topic", "topic": "services", "data": ["services": [["id": "stripe", "tone": "ok"]]]])
        let chat = MacChatStore.shared
        chat.newChat()
        model.demoActive = true
        model.setDemo(services: [["id": "github", "tone": "warning"], ["id": "vercel", "tone": "ok"]])
        chat.showDemo([("What failed in CI?", "The `api` tests: a missing env var.")])
        XCTAssertEqual(model.services.map { J.s($0["id"]) }, ["github", "vercel"])
        XCTAssertEqual(chat.lines.count, 2)
        model.endDemo()
        chat.endDemo()
        XCTAssertEqual(model.services.map { J.s($0["id"]) }, ["stripe"])
        XCTAssertTrue(chat.lines.isEmpty)
    }

    @MainActor
    func testJarvisCanOpenATab() {
        let model = AppModel()
        var got: [(String, String?)] = []
        model.onIsland = { tab, text in got.append((tab, text)) }
        model.handle(["type": "island", "tab": "music"])
        model.handle(["type": "island", "tab": "chat", "text": "hi"])
        XCTAssertEqual(got.map(\.0), ["music", "chat"])
        XCTAssertEqual(got.last?.1, "hi")
    }

    /// A restarted app shows the plan usage at once (jc-client only sends a
    /// change, so the hello carries what it has).
    @MainActor
    func testHelloCarriesThePlanUsage() {
        let model = AppModel()
        let later = Date().timeIntervalSince1970 + 3600
        model.handle(["type": "hello", "usage": [
            "five_hour": ["used_percentage": 21, "resets_at": later],
            "seven_day": ["used_percentage": 9, "resets_at": later]]])
        XCTAssertEqual(model.usage?.fiveHour, 21)
        XCTAssertEqual(model.usage?.sevenDay, 9)
    }
}

import XCTest
import AppKit
import SwiftUI
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

    /// An opened session (its steps, files, a diff) grows the island instead of
    /// being cut off at the bottom; past the panel's height the list scrolls.
    func testTheAgentsTabIsAsTallAsWhatItHolds() {
        let h = IslandLayout.agentsHeight(topInset: 40, top: 60, list: 120)
        XCTAssertEqual(h, 40 + IslandLayout.tabsHeight + 10 + 60 + 10 + 120 + 14)
        XCTAssertEqual(IslandLayout.agentsHeight(topInset: 40, top: 60, list: 2_000), IslandController.panelSize.height)
    }

    @MainActor
    func testTheIslandUsesWhatItMeasured() {
        let model = AppModel()
        let measured = IslandRootView.expandedHeight(model: model, tab: .agents, topInset: 40,
                                                     measured: IslandMeasure(top: 60, list: 300))
        XCTAssertEqual(measured, IslandLayout.agentsHeight(topInset: 40, top: 60, list: 300))
        // Nothing measured yet (the first frame): the row estimate.
        XCTAssertEqual(IslandRootView.expandedHeight(model: model, tab: .agents, topInset: 40, measured: nil),
                       IslandLayout.agentsHeight(topInset: 40, sessions: 0, pending: nil, flash: false))
    }

    /// The slim scroll bar: only when the list is taller than the island; its
    /// thumb is the visible share and moves with the scroll.
    func testTheScrollBarThumbFollowsTheList() {
        XCTAssertNil(IslandLayout.scrollThumb(content: 100, visible: 100, offset: 0))
        let top = IslandLayout.scrollThumb(content: 200, visible: 100, offset: 0)
        XCTAssertEqual(top?.start, 0)
        XCTAssertEqual(top?.length, 50)
        XCTAssertEqual(IslandLayout.scrollThumb(content: 200, visible: 100, offset: 100)?.start, 50)
        XCTAssertEqual(IslandLayout.scrollThumb(content: 10_000, visible: 100, offset: 0)?.length, 24)  // never a sliver
    }

    /// Opening a session (its steps and files) makes the island taller instead
    /// of cutting it off. Hosted offscreen; JC_ISLAND_SNAPSHOT=<path prefix>
    /// writes before/after PNGs to look at.
    @MainActor
    func testOpeningASessionGrowsTheIsland() throws {
        let model = AppModel()
        model.handle(["type": "sessions", "sessions": [
            ["key": "a", "agent": "claude", "project": "jarvis-copilot", "state": "working", "step": "Bash: npm test",
             "steps": (1...6).map { ["t": "Read Sources/File\($0).swift"] },
             "turn": ["prompt": "Fix the island so it fits what it shows",
                      "files": [["path": "/w/Sources/Island.swift", "added": 3, "removed": 1,
                                 "lines": [["k": "+", "t": "let fits = true"]]]]]],
            ["key": "b", "agent": "claude", "project": "usage-scratch", "state": "idle"],
        ]])
        let controller = IslandController(model: model)
        let ui = IslandUI()
        ui.state = .expanded
        // Offscreen there's no display link to run the spring, so the test turns
        // animation off and looks at where everything lands.
        let host = NSHostingView(rootView: IslandRootView(model: model, ui: ui, controller: controller)
            .transaction { $0.disablesAnimations = true })
        host.frame = CGRect(origin: .zero, size: IslandController.panelSize)
        func settle() {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            host.layoutSubtreeIfNeeded()
        }
        func height() -> CGFloat {
            IslandRootView.expandedHeight(model: model, tab: .agents, topInset: ui.geometry.height + 8,
                                          measured: ui.agentsMeasure)
        }
        func snapshot(_ name: String) throws {
            guard let out = ProcessInfo.processInfo.environment["JC_ISLAND_SNAPSHOT"],
                  let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: out + name))
        }
        settle()
        let closed = height()
        XCTAssertNotNil(ui.agentsMeasure, "the tab measured itself")
        try snapshot("-closed.png")
        model.selectedKey = "a"
        settle()
        XCTAssertGreaterThan(height(), closed + 60, "the opened session's steps and file add to the island")
        XCTAssertLessThanOrEqual(height(), IslandController.panelSize.height)
        try snapshot("-open.png")
    }

    /// The usage pills open each agent's limits above the sessions, and the
    /// island grows to fit them (JC_ISLAND_SNAPSHOT renders it).
    @MainActor
    func testTheLimitsCardOpensInTheAgentsTab() throws {
        let model = AppModel()
        let base = Date().timeIntervalSince1970
        model.handle(["type": "usage", "rate_limits": [
            "five_hour": ["used_percentage": 91, "resets_at": base + 2 * 3600 + 240],
            "seven_day": ["used_percentage": 18, "resets_at": base + 6 * 86_400 + 4 * 3600]]])
        model.handle(["type": "usage", "agent": "codex", "rate_limits": [
            "five_hour": ["used_percentage": 4, "resets_at": base + 3 * 3600],
            "seven_day": ["used_percentage": 30, "resets_at": base + 2 * 86_400]]])
        model.handle(["type": "sessions", "sessions": [
            ["key": "a", "agent": "claude", "project": "jarvis-copilot", "state": "working", "step": "Bash: npm test"]]])
        let ui = IslandUI()
        ui.state = .expanded
        let host = NSHostingView(rootView: IslandRootView(model: model, ui: ui, controller: IslandController(model: model))
            .transaction { $0.disablesAnimations = true })
        host.frame = CGRect(origin: .zero, size: IslandController.panelSize)
        func settle() {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            host.layoutSubtreeIfNeeded()
        }
        settle()
        let closed = ui.agentsTop ?? 0
        ui.showLimits = true
        settle()
        XCTAssertGreaterThan(ui.agentsTop ?? 0, closed + 80, "the limits card adds to the island")
        if let out = ProcessInfo.processInfo.environment["JC_ISLAND_SNAPSHOT"],
           let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: out + "-limits.png"))
        }
    }

    /// The chat tab, like the phone's: rendered empty and with a short
    /// conversation when JC_ISLAND_SNAPSHOT is set.
    @MainActor
    func testTheChatTabRendersLikeThePhones() throws {
        guard let out = ProcessInfo.processInfo.environment["JC_ISLAND_SNAPSHOT"] else {
            throw XCTSkip("set JC_ISLAND_SNAPSHOT to render the chat tab")
        }
        let model = AppModel()
        let chat = MacChatStore.shared
        chat.newChat()
        let ui = IslandUI()
        ui.state = .expanded
        ui.tab = .chat
        let host = NSHostingView(rootView: IslandRootView(model: model, ui: ui, controller: IslandController(model: model))
            .transaction { $0.disablesAnimations = true })
        host.frame = CGRect(origin: .zero, size: IslandController.panelSize)
        func shot(_ name: String) throws {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: out + name))
        }
        try shot("-chat-empty.png")
        chat.showDemo([("What failed in CI?", "The **api** tests: `DATABASE_URL` isn't set in the CI env, so the migration step exits early."),
                       ("Fix it and rerun", "")])
        try shot("-chat.png")
        chat.endDemo()
    }

    /// The chat's file picker opens over the island, not under it.
    @MainActor
    func testTheFilePickerOpensOverTheIsland() {
        let panel = ChatAttachPanel.make()
        panel.begin { _ in }
        defer { panel.cancel(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertGreaterThan(panel.level.rawValue, Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
    }
}

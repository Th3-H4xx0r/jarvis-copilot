import XCTest
import AppKit
import SwiftUI
@testable import Jarvis

/// The expanded island's tabs: Agents, Chat, Music (and Voice, the orb's).
final class IslandTabsTests: XCTestCase {

    func testTabsAndTheirHeights() {
        XCTAssertEqual(IslandTab.allCases.first, .agents)
        XCTAssertEqual(IslandTab(rawValue: "chat"), .chat)
        XCTAssertGreaterThan(IslandTab.chat.height, IslandTab.music.height)
        for t in IslandTab.allCases where t != .agents {
            XCTAssertLessThanOrEqual(t.height, IslandController.panelSize.height)
        }
    }

    @MainActor
    func testTheDemoShowsAMadeUpChatThenClearsIt() {
        let chat = MacChatStore.shared
        chat.newChat()
        let model = AppModel()
        model.demoActive = true
        chat.showDemo([("What failed in CI?", "The `api` tests: a missing env var.")])
        XCTAssertEqual(chat.lines.count, 2)
        model.endDemo()
        chat.endDemo()
        XCTAssertTrue(chat.lines.isEmpty)
    }

    /// Only Agents, Chat and Music are tabs now (Services, the portfolio and
    /// Mail are gone); Voice is the orb's.
    func testTheTabsAreAgentsChatAndMusic() {
        XCTAssertEqual(IslandTab.tabBar, [.agents, .chat, .music])
        XCTAssertNil(IslandTab(rawValue: "services"))
        XCTAssertNil(IslandTab(rawValue: "mail"))
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

    /// A reply with its tools in one box, a picture from a MEDIA: line, and a
    /// command waiting on your approval; then Jarvis's question. Rendered
    /// when JC_ISLAND_SNAPSHOT is set (-chat-tools.png, -chat-clarify.png).
    @MainActor
    func testTheChatTabShowsToolsAndAnApproval() throws {
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
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: out + name))
        }
        // A stand-in picture, inline so nothing is fetched.
        let picture = NSImage(size: NSSize(width: 480, height: 270), flipped: false) { r in
            NSColor(calibratedRed: 0.55, green: 0.42, blue: 0.25, alpha: 1).setFill(); r.fill()
            NSColor(calibratedRed: 0.85, green: 0.7, blue: 0.4, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 170, y: 65, width: 140, height: 140)).fill()
            return true
        }
        let png = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(picture.tiffRepresentation))?
            .representation(using: .png, properties: [:]))
        var search = ChatTool(name: "web_search", argsLine: "query: male lion photo")
        search.done = true; search.duration = 1.4; search.result = "5 results · commons.wikimedia.org"
        var open = ChatTool(name: "device_open_app", argsLine: "app: Preview")
        open.done = true; open.duration = 0.6
        let terminal = ChatTool(name: "terminal", argsLine: "command: rm -rf ~/Downloads/lions")
        chat.showDemo(lines: [
            MacChatStore.Line(role: .user, text: "show me img of lion", files: ["notes.md"]),
            .reply("Here's a **male lion**.\n![lion](data:image/png;base64,\(png.base64EncodedString()))\nWant more like it?",
                   tools: [search, open]),
            MacChatStore.Line(role: .user, text: "Clear the old ones from Downloads"),
            MacChatStore.Line(role: .assistant, text: "", turn: ChatTurn(tools: [terminal], streaming: true)),
        ], approval: ChatApproval(command: "rm -rf ~/Downloads/lions", description: "recursive delete"))
        try shot("-chat-tools.png")
        // The whole conversation at once (offscreen, the island's scroll offset isn't drawn).
        let tall = NSHostingView(rootView: ChatPane(ui: ui).padding(16).frame(width: IslandRootView.expandedWidth, height: 1180)
            .background(Color.black).transaction { $0.disablesAnimations = true })
        tall.frame = CGRect(x: 0, y: 0, width: IslandRootView.expandedWidth, height: 1180)
        tall.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        tall.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(tall.bitmapImageRepForCachingDisplay(in: tall.bounds))
        tall.cacheDisplay(in: tall.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: out + "-chat-tools-full.png"))
        chat.showDemo(lines: [
            MacChatStore.Line(role: .user, text: "Book a table for Friday"),
            MacChatStore.Line(role: .assistant, text: "", turn: ChatTurn(streaming: true)),
        ], clarify: ChatClarify(question: "Which restaurant should I book?", choices: ["Nopa", "Flour + Water", "State Bird"]))
        try shot("-chat-clarify.png")
        chat.showDemo(lines: [
            MacChatStore.Line(role: .user, text: "Deploy the api"),
            MacChatStore.Line(role: .assistant, text: "", turn: ChatTurn(tools: [open], stopped: true)),
            MacChatStore.Line(role: .user, text: "What's the weather?"),
            MacChatStore.Line(role: .assistant, text: "", turn: ChatTurn(error: "Jarvis isn't connected on this Mac (jc-client).")),
            MacChatStore.Line(role: .user, text: "hello?"),
            MacChatStore.Line(role: .assistant, text: "", turn: ChatTurn(note: "No reply")),
        ])
        try shot("-chat-ends.png")
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

    /// Clicks inside the file picker reach the island as clicks elsewhere (the
    /// picker's insides run in another process): while it's open they don't
    /// fold the island.
    @MainActor
    func testClicksInTheFilePickerDontFoldTheIsland() {
        XCTAssertTrue(IslandClicks.foldsOnClickElsewhere(expanded: true, filePanelOpen: false))
        XCTAssertFalse(IslandClicks.foldsOnClickElsewhere(expanded: true, filePanelOpen: true))
        XCTAssertFalse(IslandClicks.foldsOnClickElsewhere(expanded: false, filePanelOpen: false))
        XCTAssertFalse(IslandClicks.filePanelOpen())
        let panel = ChatAttachPanel.make()
        panel.begin { _ in }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(IslandClicks.filePanelOpen())
        panel.cancel(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(IslandClicks.filePanelOpen())
    }
}

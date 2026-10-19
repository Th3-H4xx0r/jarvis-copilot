import XCTest
import AppKit
import SwiftUI
@testable import Jarvis

/// Jarvis on the Mac lives in the notch: voice opens in the island, the old
/// menu-bar menu pops from a right-click, and the island stays light at idle.
final class NotchOnlyTests: XCTestCase {

    func testVoiceIsAnIslandViewButNotATab() {
        XCTAssertFalse(IslandTab.tabBar.contains(.voice))
        XCTAssertEqual(IslandTab.tabBar, IslandTab.allCases.filter { $0 != .voice })
        XCTAssertLessThanOrEqual(IslandTab.voice.height, IslandController.panelSize.height)
        XCTAssertEqual(IslandTab.voice.height, IslandLayout.voiceHeight(topInset: 40))   // the stage under the tabs
    }

    @MainActor
    func testTheIslandOpensVoiceAtItsHeight() {
        XCTAssertEqual(IslandRootView.expandedHeight(model: AppModel(), tab: .voice, topInset: 40), IslandTab.voice.height)
    }

    /// The menu the menu-bar icon used to show, now from a right-click on the notch.
    @MainActor
    func testTheMenuKeepsWhatTheMenuBarHad() {
        let model = AppModel()
        let menu = JarvisMenu(model: model, island: IslandController(model: model)).build()
        let titles = menu.items.map(\.title)
        for t in ["Show the island", "Talk to Jarvis", "Weekly recap", "Settings…", "Open dashboard",
                  "Voice Orb in a window", "Re-pair…", "View logs", "Restart", "Quit Jarvis"] {
            XCTAssertTrue(titles.contains(t), "\(t) missing from \(titles)")
        }
    }

    /// The orb only redraws while something happens; idle it's a still frame.
    func testTheOrbIsStillWhenNothingHappens() {
        XCTAssertNil(OrbMotion.interval(mood: .idle, beat: 0))
        XCTAssertNotNil(OrbMotion.interval(mood: .idle, beat: 0.4))          // music
        XCTAssertEqual(OrbMotion.interval(mood: .listening, beat: 0), 1.0 / 30)
        XCTAssertEqual(OrbMotion.interval(mood: .working, beat: 0), 1.0 / 12)
        XCTAssertEqual(OrbMotion.interval(mood: .waiting, beat: 0), 1.0 / 12)
    }

    /// The pulse is a function of the orb's clock (no repeatForever animation,
    /// which redrew every display frame and never stopped): rest, full, rest
    /// again each cycle, quicker while waiting on you.
    func testThePulseBreathesOnTheOrbsOwnClock() {
        XCTAssertEqual(OrbMotion.pulse(at: 0, mood: .working), 0, accuracy: 1e-9)
        XCTAssertEqual(OrbMotion.pulse(at: 1.1, mood: .working), 1, accuracy: 1e-9)
        XCTAssertEqual(OrbMotion.pulse(at: 2.2, mood: .working), 0, accuracy: 1e-9)
        XCTAssertEqual(OrbMotion.pulse(at: 0.7, mood: .waiting), 1, accuracy: 1e-9)
        for t in stride(from: 0.0, to: 5, by: 0.05) {
            XCTAssert((0...1).contains(OrbMotion.pulse(at: t, mood: .working)))
        }
    }

    /// The pointer is polled quickly only near the island; far away, once a
    /// second (a mouse-moved monitor wakes it as the pointer comes close).
    func testTheIslandPollsSlowlyWhenThePointerIsFarAway() {
        XCTAssertEqual(IslandTick.interval(expanded: false, nearIsland: false, inBand: false), 1.0)
        XCTAssertEqual(IslandTick.interval(expanded: false, nearIsland: false, inBand: true), 1.0 / 20)
        XCTAssertEqual(IslandTick.interval(expanded: true, nearIsland: false, inBand: false), 1.0 / 20)
        XCTAssertEqual(IslandTick.interval(expanded: true, nearIsland: true, inBand: true), 1.0 / 60)
    }

    /// The Voice view with the real voice panel (jc-client's dylib), rendered
    /// offscreen. Runs only with JC_VOICE_DYLIB=<path> (and JC_ISLAND_SNAPSHOT
    /// to write the PNG); the voice panel needs jc-client's loopback origin.
    @MainActor
    func testTheVoiceViewHostsTheVoicePanel() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dylib = env["JC_VOICE_DYLIB"], let api = env["JC_API_ORIGIN"] else {
            throw XCTSkip("set JC_VOICE_DYLIB and JC_API_ORIGIN to render the voice panel")
        }
        // The panel's mode (Voice / Live) is remembered in defaults; JC_VOICE_MODE picks it.
        UserDefaults.standard.set(env["JC_VOICE_MODE"] ?? "voice", forKey: "jc.mac.panelMode")
        let model = AppModel()
        model.handle(["type": "hello", "api": api, "voice_dylib": dylib])
        let controller = IslandController(model: model)
        let menu = JarvisMenu(model: model, island: controller)
        XCTAssertNotNil(menu.makeVoicePanel(island: true), "the dylib gives the island's voice panel")
        controller.voicePanel = { menu.makeVoicePanel(island: true) }
        controller.voiceMiniPanel = { menu.makeVoiceMiniPanel() }
        let ui = IslandUI()
        ui.state = .expanded
        ui.tab = .voice
        // JC_VOICE_MINI: the small push-to-talk island instead of the stage.
        let mini = env["JC_VOICE_MINI"] != nil
        ui.voiceMini = mini
        if mini { XCTAssertNotNil(menu.makeVoiceMiniPanel(), "the dylib gives the small voice island") }
        let host = NSHostingView(rootView: IslandRootView(model: model, ui: ui, controller: controller)
            .transaction { $0.disablesAnimations = true })
        host.frame = CGRect(origin: .zero, size: IslandController.panelSize)
        // A real window, so the views appear as they do in the app — on screen but
        // below the desktop picture, so nobody sees it.
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: IslandController.panelSize),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.contentView = host
        window.backgroundColor = .clear
        window.isOpaque = false
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(IslandPin.holds(pinned: ui.pinned, tab: ui.tab, pending: false), "the island stays open while you talk")
        // The stage told the island where its orb sits (across the dylib), so the
        // notch's orb can fly onto it: centred on the stage, at its full size.
        let home = try XCTUnwrap(ui.orbHomes[.voice], "the stage reported its orb")
        if mini {
            // The small island's orb sits at its left, under the notch.
            XCTAssertEqual(home.width, 32, accuracy: 1)
            XCTAssertLessThan(home.midX, IslandController.panelSize.width / 2 - 100)
            XCTAssertGreaterThan(home.minY, ui.geometry.height)
        } else {
            XCTAssertEqual(home.midX, IslandController.panelSize.width / 2, accuracy: 2)
            XCTAssertEqual(home.width, 72, accuracy: 1)
            XCTAssertGreaterThan(home.minY, ui.geometry.height + 8 + IslandLayout.tabsHeight)
        }
        // The window server's own picture of the window (materials and all, which
        // a view snapshot can't draw): say which window, hold it for a capture.
        if let out = env["JC_ISLAND_SNAPSHOT"] {
            try "\(window.windowNumber)".write(toFile: out + "-voice.winid", atomically: true, encoding: .utf8)
            RunLoop.main.run(until: Date().addingTimeInterval(6))
        }
    }

    /// Only the orb opens Voice: a click on the rest of the notch (or the
    /// island shortcut) opens the last other tab — Agents at first.
    @MainActor
    func testOnlyTheOrbOpensVoice() {
        let ui = IslandUI()
        XCTAssertEqual(ui.lastTab, .agents)
        ui.tab = .music
        ui.tab = .voice
        XCTAssertEqual(ui.lastTab, .music)
        XCTAssertEqual(IslandTab.forIslandClick(current: .voice, last: ui.lastTab), .music)
        XCTAssertEqual(IslandTab.forIslandClick(current: .voice, last: .agents), .agents)
        XCTAssertEqual(IslandTab.forIslandClick(current: .chat, last: .agents), .chat)
    }

    /// Folding leaves Voice (it's the orb's): whatever reopens the island next
    /// — an agent finishing, Show the island, hover — opens Agents, not a
    /// voice panel that pins it open (sweep finding).
    @MainActor
    func testFoldingLeavesVoiceSoTheIslandReopensOnAgents() {
        let c = IslandController(model: AppModel())
        c.openVoice()
        XCTAssertEqual(c.ui.tab, .voice)
        c.close()
        XCTAssertEqual(c.ui.tab, .agents)
        c.attention()
        XCTAssertEqual(c.ui.tab, .agents)
    }

    /// Voice holds the island open by rule, not by a flag the panes set and
    /// clear (Chat's disappear ran after Voice's appear and unpinned it).
    func testVoiceHoldsTheIslandOpenWhateverThePanesDid() {
        XCTAssertTrue(IslandPin.holds(pinned: false, tab: .voice, pending: false))
        XCTAssertFalse(IslandPin.holds(pinned: false, tab: .agents, pending: false))
        XCTAssertTrue(IslandPin.holds(pinned: true, tab: .chat, pending: false))
        XCTAssertTrue(IslandPin.holds(pinned: false, tab: .agents, pending: true))
    }
}


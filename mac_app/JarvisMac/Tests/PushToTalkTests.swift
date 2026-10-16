import XCTest
import AppKit
import SwiftUI
@testable import Jarvis

/// Push to talk (Settings → Voice): hold one key — Right ⌥ — and Jarvis
/// listens; let go and it answers in a small island under the notch.
final class PushToTalkTests: XCTestCase {
    /// Held past a beat, it talks; let go, it sends.
    func testHoldingTheKeyTalksAndLettingGoSends() {
        var k = TalkKeyLogic()
        XCTAssertEqual(k.keyDown(at: 10), .none)
        XCTAssertEqual(k.tick(at: 10.05), .none, "not yet: it may be ⌥ for typing")
        XCTAssertEqual(k.tick(at: 10 + TalkKeyLogic.startDelay), .start)
        XCTAssertEqual(k.tick(at: 11), .none, "starts once")
        XCTAssertEqual(k.keyUp(at: 12), .send)
        XCTAssertEqual(k.phase, .idle)
    }

    /// ⌥ used to type a character (⌥E) never talks.
    func testAnotherKeyWhileWaitingMeansItWasTyping() {
        var k = TalkKeyLogic()
        _ = k.keyDown(at: 1)
        XCTAssertEqual(k.otherKey(), .none)
        XCTAssertEqual(k.tick(at: 2), .none)
        XCTAssertEqual(k.keyUp(at: 2.1), .none)
    }

    /// A quick tap is not a talk.
    func testATapDoesNothing() {
        var k = TalkKeyLogic()
        _ = k.keyDown(at: 1)
        XCTAssertEqual(k.keyUp(at: 1.05), .none)
        XCTAssertEqual(k.tick(at: 2), .none)
    }

    /// Once talking, typing doesn't stop it — only letting go does.
    func testTypingWhileTalkingKeepsTalking() {
        var k = TalkKeyLogic()
        _ = k.keyDown(at: 1)
        _ = k.tick(at: 2)
        XCTAssertEqual(k.otherKey(), .none)
        XCTAssertEqual(k.phase, .talking)
    }

    /// The same key can't do two things: Flow dictation's key clashes when Flow is on.
    func testTheTalkKeyClashesWithFlowsKey() {
        XCTAssertTrue(TalkKeyChoice.clashes(talk: .rightOption, flow: .rightOption, flowOn: true))
        XCTAssertFalse(TalkKeyChoice.clashes(talk: .rightOption, flow: .rightOption, flowOn: false))
        XCTAssertFalse(TalkKeyChoice.clashes(talk: .rightOption, flow: .fn, flowOn: true))
        XCTAssertFalse(TalkKeyChoice.clashes(talk: nil, flow: .rightOption, flowOn: true))
        XCTAssertNotEqual(TalkKeyChoice.otherKey(than: .rightOption), .rightOption)
    }

    func testTheTalkKeyIsRemembered() {
        let saved = UserDefaults.standard.object(forKey: "voice.talkKey")
        defer { UserDefaults.standard.set(saved, forKey: "voice.talkKey") }
        UserDefaults.standard.removeObject(forKey: "voice.talkKey")
        XCTAssertNil(Prefs.talkKey, "off until you pick one")
        Prefs.talkKey = .rightOption
        XCTAssertEqual(Prefs.talkKey, .rightOption)
        Prefs.talkKey = nil
        XCTAssertNil(Prefs.talkKey)
    }

    /// Talk to Jarvis lives in Settings → Voice now, not in the Shortcuts list.
    func testTalkToJarvisIsNotInTheShortcutsList() {
        XCTAssertFalse(ShortcutAction.shortcutsTab.contains(.talk))
        XCTAssertEqual(ShortcutAction.shortcutsTab.count, ShortcutAction.allCases.count - 1)
    }

    /// The small voice island: narrower than the open island and just a band
    /// under the notch.
    func testTheSmallVoiceIslandIsABandUnderTheNotch() {
        XCTAssertLessThan(IslandLayout.voiceMiniWidth, IslandRootView.expandedWidth)
        XCTAssertEqual(IslandLayout.voiceMiniHeight(topInset: 40), 40 + IslandLayout.voiceMiniBand)
        XCTAssertLessThan(IslandLayout.voiceMiniHeight(topInset: 40), IslandLayout.voiceHeight(topInset: 40) / 2)
    }

    /// Push to talk opens on the display you're pointing at — including its
    /// very top edge, where the notch is — else the nearest one.
    func testTheTalkScreenIsTheOneUnderThePointer() {
        let frames = [CGRect(x: 0, y: 0, width: 2560, height: 1440),        // main monitor
                      CGRect(x: -1512, y: -982, width: 1512, height: 982),   // the laptop, below left
                      CGRect(x: 2560, y: 0, width: 2560, height: 1440)]      // monitor on the right
        XCTAssertEqual(TalkScreen.index(of: CGPoint(x: 880, y: 700), in: frames), 0)
        XCTAssertEqual(TalkScreen.index(of: CGPoint(x: -756, y: 0), in: frames), 1, "the notch's top edge")
        XCTAssertEqual(TalkScreen.index(of: CGPoint(x: 4000, y: 1440), in: frames), 2)
        XCTAssertEqual(TalkScreen.index(of: CGPoint(x: -700, y: 500), in: frames), 1, "off every screen: the nearest")
        XCTAssertNil(TalkScreen.index(of: .zero, in: []))
    }

    /// The glow's two halves run from the top centre, one by each side, to
    /// the bottom centre — where they meet.
    func testTheGlowRunsDownBothSidesAndMeetsAtTheBottom() {
        let rect = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let right = EdgeGlowPath.half(in: rect, corner: 12, right: true)
        let left = EdgeGlowPath.half(in: rect, corner: 12, right: false)
        XCTAssertEqual(right.boundingRect.maxX, rect.maxX, accuracy: 0.5)
        XCTAssertEqual(right.boundingRect.minX, rect.midX, accuracy: 0.5)
        XCTAssertEqual(left.boundingRect.minX, rect.minX, accuracy: 0.5)
        XCTAssertEqual(left.boundingRect.maxX, rect.midX, accuracy: 0.5)
        for half in [right, left] {
            XCTAssertEqual(half.boundingRect.minY, rect.minY, accuracy: 0.5)
            XCTAssertEqual(half.boundingRect.maxY, rect.maxY, accuracy: 0.5)
            // Halfway along, it's on the side, not yet at the bottom.
            let mid = half.trimmedPath(from: 0, to: 0.5).boundingRect
            XCTAssertLessThan(mid.maxY, rect.maxY - 100)
        }
    }

    func testTheGlowIsOnUntilTurnedOff() {
        let saved = UserDefaults.standard.object(forKey: "voice.edgeGlow")
        defer { UserDefaults.standard.set(saved, forKey: "voice.edgeGlow") }
        UserDefaults.standard.removeObject(forKey: "voice.edgeGlow")
        XCTAssertTrue(Prefs.edgeGlow)
        Prefs.edgeGlow = false
        XCTAssertFalse(Prefs.edgeGlow)
    }

    /// On every display in turn: push to talk "pointed" at its centre brings the
    /// island and the glow there, and the fold sends the island home.
    /// JC_TALK_SCREENS=<dir>: each step writes <dir>/step-N.ready (the display's
    /// bounds) and waits for step-N.done, so a screenshot can be taken.
    @MainActor
    func testLiveTheIslandGoesToTheScreenYouTalkOn() throws {
        guard let dir = ProcessInfo.processInfo.environment["JC_TALK_SCREENS"] else {
            throw XCTSkip("set JC_TALK_SCREENS to walk the island across the displays")
        }
        let model = AppModel()
        let c = IslandController(model: model)
        func wait(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        wait(1)
        let home = c.currentScreen
        var log = ["home: \(home?.localizedName ?? "none")"]
        for (n, screen) in NSScreen.screens.enumerated() {
            let s = c.comeToPointer(at: CGPoint(x: screen.frame.midX, y: screen.frame.midY))
            c.openVoice(mini: true)
            ScreenGlow.shared.show(on: c.currentScreen)
            wait(1.2)
            let num = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value
            let b = CGDisplayBounds(num)
            try "\(Int(b.minX)),\(Int(b.minY)),\(Int(b.width)),\(Int(b.height))"
                .write(toFile: "\(dir)/step-\(n).ready", atomically: true, encoding: .utf8)
            for _ in 0..<60 where !FileManager.default.fileExists(atPath: "\(dir)/step-\(n).done") { wait(0.1) }
            log.append("\(screen.localizedName): came=\(s?.localizedName ?? "none") on=\(c.currentScreen?.localizedName ?? "none")")
            c.close()
            ScreenGlow.shared.hide()
            wait(1.2)
            log.append("  folded → on \(c.currentScreen?.localizedName ?? "none")")
            XCTAssertEqual(s, screen)
            XCTAssertEqual(c.currentScreen, home, "home again after the fold")
        }
        try log.joined(separator: "\n").write(toFile: "\(dir)/log.txt", atomically: true, encoding: .utf8)
    }

    /// The glow at points along its way, rendered offscreen when JC_ISLAND_SNAPSHOT is set.
    @MainActor
    func testRenderTheGlow() throws {
        guard let out = ProcessInfo.processInfo.environment["JC_ISLAND_SNAPSHOT"] else {
            throw XCTSkip("set JC_ISLAND_SNAPSHOT to render the glow")
        }
        for (name, progress) in [("half", CGFloat(0.45)), ("full", CGFloat(1))] {
            let model = ScreenGlowModel()
            model.progress = progress
            let host = NSHostingView(rootView: ScreenGlowView(model: model).background(Color(white: 0.12)))
            host.frame = CGRect(x: 0, y: 0, width: 756, height: 491)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: out + "-glow-\(name).png"))
        }
    }
}

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

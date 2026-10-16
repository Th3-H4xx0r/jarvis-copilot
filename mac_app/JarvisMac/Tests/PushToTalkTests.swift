import XCTest
import AppKit
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
}

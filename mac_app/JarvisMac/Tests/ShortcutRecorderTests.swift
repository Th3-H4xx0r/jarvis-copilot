import XCTest
import AppKit
import SwiftUI
import Carbon.HIToolbox
@testable import Jarvis

/// Settings → Shortcuts records a shortcut from the keys you press (a button
/// per action; Esc when you're done), and Talk to Jarvis / Show the island can
/// be held: Jarvis listens while the key is down.
final class ShortcutRecorderTests: XCTestCase {
    private let opt: NSEvent.ModifierFlags = [.option]
    private let ctrlOpt: NSEvent.ModifierFlags = [.control, .option]

    /// The test app shares the real app's defaults: put back whatever was there.
    private func keepingDefaults(_ keys: [String], _ body: () -> Void) {
        let saved = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer { for (k, v) in saved { UserDefaults.standard.set(v, forKey: k) } }
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        body()
    }

    /// Each combo pressed replaces the last; Esc finishes with the last one.
    func testRecordingKeepsTheLastComboUntilEsc() {
        var r = ShortcutRecording()
        XCTAssertEqual(r.key(code: UInt32(kVK_ANSI_J), modifiers: ctrlOpt), .keepGoing)
        XCTAssertEqual(r.captured?.display, "⌃⌥J")
        XCTAssertEqual(r.key(code: UInt32(kVK_Space), modifiers: opt), .keepGoing)
        XCTAssertEqual(r.captured?.display, "⌥Space")
        XCTAssertEqual(r.key(code: UInt32(kVK_Escape), modifiers: []), .finished(Shortcut(string: "opt+space")))
    }

    /// Esc straight away changes nothing.
    func testEscWithNothingPressedKeepsTheOldShortcut() {
        var r = ShortcutRecording()
        XCTAssertEqual(r.key(code: UInt32(kVK_Escape), modifiers: []), .finished(nil))
    }

    /// A plain letter would steal your typing: it needs a modifier (the hint
    /// says so) — but a lone function key is fine.
    func testAPlainKeyNeedsAModifierButAFunctionKeyDoesNot() {
        var r = ShortcutRecording()
        XCTAssertEqual(r.key(code: UInt32(kVK_ANSI_K), modifiers: []), .keepGoing)
        XCTAssertNil(r.captured)
        XCTAssertNotNil(r.hint)
        XCTAssertEqual(r.key(code: UInt32(kVK_F13), modifiers: []), .keepGoing)
        XCTAssertEqual(r.captured?.display, "F13")
        XCTAssertNil(r.hint)
        XCTAssertEqual(Shortcut(string: "f13"), r.captured, "a lone F-key is stored and read back")
    }

    /// More of the keyboard can be recorded than the old typed-in list.
    func testDigitsArrowsAndPunctuationRoundTrip() {
        for (code, display) in [(kVK_ANSI_7, "⌃⌥7"), (kVK_LeftArrow, "⌃⌥←"), (kVK_ANSI_Slash, "⌃⌥/"),
                                (kVK_F5, "⌃⌥F5"), (kVK_ANSI_Period, "⌃⌥.")] {
            let s = Shortcut(keyCode: UInt32(code), modifiers: ctrlOpt)
            XCTAssertEqual(s.display, display)
            XCTAssertEqual(Shortcut(string: s.string), s, display)
        }
    }

    func testOnlyTalkAndTheIslandCanBeHeld() {
        XCTAssertEqual(Set(ShortcutAction.allCases.filter(\.supportsHold)), [.talk, .toggleIsland])
    }

    func testHoldIsRememberedPerAction() {
        keepingDefaults(["shortcut.talk.hold", "shortcut.mute.hold"]) {
            let action = ShortcutAction.talk
            XCTAssertFalse(action.holds)
            action.holds = true
            XCTAssertTrue(action.holds)
            UserDefaults.standard.set(true, forKey: "shortcut.mute.hold")
            XCTAssertFalse(ShortcutAction.mute.holds, "an action that can't be held never is")
        }
    }

    /// Settings → Shortcuts, rendered offscreen when JC_ISLAND_SNAPSHOT is set.
    @MainActor
    func testRenderTheShortcutsTab() throws {
        guard let out = ProcessInfo.processInfo.environment["JC_ISLAND_SNAPSHOT"] else {
            throw XCTSkip("set JC_ISLAND_SNAPSHOT to render the Shortcuts tab")
        }
        let host = NSHostingView(rootView: ShortcutsSettings().frame(width: 640, height: 760))
        host.frame = CGRect(x: 0, y: 0, width: 640, height: 760)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: out + "-shortcuts.png"))
    }

    /// A combo already used elsewhere moves to the new action; the old one is off.
    func testAComboTakenElsewhereMovesOver() {
        keepingDefaults(ShortcutAction.allCases.map { "shortcut.\($0.rawValue)" }) {
            ShortcutAction.mute.shortcut = Shortcut(string: "ctrl+opt+m")
            let moved = ShortcutAction.talk.assign(Shortcut(string: "ctrl+opt+m"))
            XCTAssertEqual(moved, [.mute])
            XCTAssertEqual(ShortcutAction.talk.shortcut?.display, "⌃⌥M")
            XCTAssertNil(ShortcutAction.mute.shortcut)
        }
    }
}

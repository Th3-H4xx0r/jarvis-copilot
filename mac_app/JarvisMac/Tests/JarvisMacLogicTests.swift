import XCTest
@testable import Jarvis

/// The Mac app's pure rules: where the island sits, when it opens and closes,
/// how shortcuts parse, which orb skin a date gets, how the hook sessions decode
/// and which terminal "Jump to terminal" brings forward.
final class JarvisMacLogicTests: XCTestCase {

    // MARK: geometry

    func testANotchedScreenUsesTheMeasuredNotch() {
        let g = IslandGeometry(screenWidth: 1512, safeAreaTop: 32, auxiliaryLeftWidth: 664,
                               auxiliaryRightWidth: 664, menuBarHeight: 37)
        XCTAssertTrue(g.hasNotch)
        XCTAssertEqual(g.width, 184)
        XCTAssertEqual(g.height, 32)
    }

    func testAMissingAuxiliaryAreaFallsBack() {
        let g = IslandGeometry(screenWidth: 1512, safeAreaTop: 32, auxiliaryLeftWidth: nil,
                               auxiliaryRightWidth: nil, menuBarHeight: 37)
        XCTAssertEqual(g.width, IslandGeometry.fallbackNotchWidth)
    }

    func testNoNotchIsASmallBarNoTallerThanTheMenuBar() {
        let g = IslandGeometry(screenWidth: 2560, safeAreaTop: 0, auxiliaryLeftWidth: nil,
                               auxiliaryRightWidth: nil, menuBarHeight: 22)
        XCTAssertFalse(g.hasNotch)
        XCTAssertEqual(g.width, 80)
        XCTAssertEqual(g.height, 22)
    }

    // MARK: display choice

    func testDisplayChoiceRoundTrips() {
        for c in [IslandDisplayChoice.notch, .menuBar, .followMouse, .display("ABC-123")] {
            XCTAssertEqual(IslandDisplayChoice(rawValue: c.rawValue), c)
        }
        XCTAssertEqual(IslandDisplayChoice(rawValue: "nonsense"), .notch)
    }

    // MARK: state machine

    func testExpandedFoldsToCompactThenHides() {
        var m = IslandStateMachine()
        m.attention(at: 0)
        XCTAssertEqual(m.state, .expanded)
        m.tick(now: IslandStateMachine.expandedHold - 1, hovering: false, pinned: false, hasSessions: true)
        XCTAssertEqual(m.state, .expanded)
        m.tick(now: IslandStateMachine.expandedHold + 1, hovering: false, pinned: false, hasSessions: true)
        XCTAssertEqual(m.state, .compact)
        let t = IslandStateMachine.expandedHold + 1 + IslandStateMachine.compactHold + 1
        m.tick(now: t, hovering: false, pinned: false, hasSessions: false)
        XCTAssertEqual(m.state, .hidden)
    }

    func testCompactStaysWhileSessionsRun() {
        var m = IslandStateMachine()
        m.attention(at: 0)
        m.tick(now: 100, hovering: false, pinned: false, hasSessions: true)
        m.tick(now: 1000, hovering: false, pinned: false, hasSessions: true)
        XCTAssertEqual(m.state, .compact)
    }

    func testHoverAndPinKeepItOpen() {
        var m = IslandStateMachine()
        m.attention(at: 0)
        m.tick(now: 500, hovering: true, pinned: false, hasSessions: true)
        XCTAssertEqual(m.state, .expanded)
        m.tick(now: 1000, hovering: false, pinned: true, hasSessions: true)
        XCTAssertEqual(m.state, .expanded)
    }

    /// A click anywhere outside the island folds it, even while something is
    /// pending (the pill keeps the amber count) or the chat holds a draft.
    func testAClickOutsideFoldsIt() {
        var m = IslandStateMachine()
        m.attention(at: 0)
        m.clickedOutside(at: 1)
        XCTAssertEqual(m.state, .compact)
        m.tick(now: 2, hovering: false, pinned: true, hasSessions: true)
        XCTAssertEqual(m.state, .compact)          // pinned doesn't pop it back open
        var hidden = IslandStateMachine()
        hidden.clickedOutside(at: 0)
        XCTAssertEqual(hidden.state, .hidden)      // nothing to fold
    }

    func testClickOpensAndToggleCloses() {
        var m = IslandStateMachine()
        m.toggle(at: 0)
        XCTAssertEqual(m.state, .expanded)
        m.toggle(at: 1)
        XCTAssertEqual(m.state, .compact)
    }

    // MARK: shortcuts

    func testShortcutParsesAndPrints() {
        let s = Shortcut(string: "ctrl+opt+space")
        XCTAssertEqual(s?.display, "⌃⌥Space")
        XCTAssertEqual(Shortcut(string: "cmd+shift+j")?.display, "⇧⌘J")  // Apple's order: ⌃⌥⇧⌘
        XCTAssertNil(Shortcut(string: "j"))           // needs a modifier
        XCTAssertNil(Shortcut(string: "ctrl+nope"))
        XCTAssertEqual(Shortcut(string: s!.string), s)
    }

    func testDefaultShortcutsDoNotCollide() {
        let all = ShortcutAction.allCases.compactMap { $0.defaultShortcut }
        XCTAssertEqual(Set(all.map(\.string)).count, all.count)
        XCTAssertEqual(ShortcutAction.openChat.defaultShortcut?.display, "⌃⌥Space")
        XCTAssertNil(ShortcutAction.toggleIsland.defaultShortcut)  // off until set
    }

    // MARK: skins

    func testSeasonalSkins() {
        func day(_ m: Int, _ d: Int) -> Date {
            Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: m, day: d))!
        }
        XCTAssertEqual(OrbSkin.auto(for: day(12, 15)), .winter)
        XCTAssertEqual(OrbSkin.auto(for: day(1, 1)), .newYear)
        XCTAssertEqual(OrbSkin.auto(for: day(10, 20)), .autumn)
        XCTAssertEqual(OrbSkin.auto(for: day(7, 4)), .summer)
        XCTAssertEqual(OrbSkin.auto(for: day(3, 10)), .standard)
    }

    // MARK: sessions

    func testSessionDecodesFromTheEngine() {
        let s = MacSession(json: [
            "key": "local|claude|s1", "agent": "claude", "session_id": "s1", "cwd": "/w/app",
            "project": "app", "state": "approval", "step": "Bash: rm -rf build",
            "steps": [["t": "go", "at": 1.0]], "started_at": 1.0, "last_event_at": 2.0,
            "terminal": ["bundle_id": "com.googlecode.iterm2", "iterm": "w0t1p0:ABC"],
            "pending": ["kind": "approval", "fingerprint": "fp", "summary": "Bash: rm -rf build"],
            "turn": ["prompt": "clean", "files": [["path": "/w/a.py", "added": 2, "removed": 1,
                                                   "lines": [["k": "+", "t": "x"]]]]],
        ])
        XCTAssertEqual(s.state, .approval)
        XCTAssertEqual(s.terminalBundleId, "com.googlecode.iterm2")
        XCTAssertEqual(s.itermSession, "w0t1p0:ABC")
        XCTAssertEqual(s.pendingFingerprint, "fp")
        XCTAssertEqual(s.files.first?.added, 2)
        XCTAssertEqual(MacSession.sorted([s, MacSession(json: ["key": "b", "state": "working"])]).first?.key,
                       "local|claude|s1")
    }

    func testPendingDecodesQuestions() {
        let p = MacPending(json: ["fingerprint": "f", "kind": "ask", "summary": "", "project": "app",
                                  "questions": [["question": "Which?", "multiSelect": true,
                                                 "options": [["label": "A"], ["label": "B"]]]]])
        XCTAssertEqual(p?.isQuestion, true)
        XCTAssertEqual(p?.questions.first?.options, ["A", "B"])
        XCTAssertNil(MacPending(json: ["kind": "permission"]))
    }

    // MARK: recap

    func testRecapDecodesAndFormats() {
        let r = MacRecap(json: ["minutes": 135, "sessions": 4, "files": 12, "added": 340, "removed": 51,
                                "commands": 30, "approved": 6, "denied": 1, "answered": 2,
                                "top_agent": ["agent": "codex", "minutes": 90],
                                "top_project": ["project": "storefront", "minutes": 80],
                                "busiest_day": ["weekday": "Tuesday", "minutes": 70],
                                "longest_session": ["project": "api", "minutes": 50]])
        XCTAssertEqual(r.time, "2h 15m")
        XCTAssertEqual(r.highlights.map(\.value), ["Codex", "storefront", "Tuesday · 1h 10m", "api · 50m"])
        XCTAssertFalse(r.isEmpty)
        XCTAssertTrue(MacRecap(json: [:]).isEmpty)
        XCTAssertEqual(MacRecap.recapURL(origin: "http://127.0.0.1:5", tzMinutes: -300)?.absoluteString,
                       "http://127.0.0.1:5/api/coding/agents/recap?days=7&tz=-300")
    }

    // MARK: terminal

    func testTerminalPickPrefersTheSessionsOwnApp() {
        XCTAssertEqual(TerminalTarget.pick(sessionBundleId: "com.googlecode.iterm2",
                                           running: ["com.apple.Terminal", "com.googlecode.iterm2"]),
                       "com.googlecode.iterm2")
        XCTAssertEqual(TerminalTarget.pick(sessionBundleId: "", running: ["com.apple.Terminal"]),
                       "com.apple.Terminal")
        XCTAssertNil(TerminalTarget.pick(sessionBundleId: nil, running: []))
    }
}

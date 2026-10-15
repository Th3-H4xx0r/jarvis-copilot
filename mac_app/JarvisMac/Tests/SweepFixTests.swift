import XCTest
@testable import Jarvis

/// Fixes from the Swift bug sweep that have a pure rule behind them.
final class SweepFixTests: XCTestCase {

    /// An agent asking for you must never take the keyboard from the app you're
    /// typing in (a stray "y" would approve a command).
    func testOnlyAnExplicitOpenForTypingTakesTheKeyboard() {
        XCTAssertFalse(IslandFocus.takesKeyboard(.attention))
        XCTAssertFalse(IslandFocus.takesKeyboard(.activity))
        XCTAssertFalse(IslandFocus.takesKeyboard(.toggle))
        XCTAssertTrue(IslandFocus.takesKeyboard(.typing))
    }

    /// A card that just took the place of the one you clicked can't be
    /// answered by the same (double) click.
    func testAFreshCardIgnoresClicksForHalfASecond() {
        let gate = ArmGate(shownAt: Date(timeIntervalSince1970: 100))
        XCTAssertFalse(gate.isArmed(at: Date(timeIntervalSince1970: 100.2)))
        XCTAssertTrue(gate.isArmed(at: Date(timeIntervalSince1970: 100.6)))
    }

    /// Flow pastes only into the app you dictated for.
    func testFlowPastesOnlyIntoTheAppItListenedFor() {
        XCTAssertTrue(FlowPaste.sameTarget(started: 42, frontNow: 42))
        XCTAssertFalse(FlowPaste.sameTarget(started: 42, frontNow: 77))
        XCTAssertFalse(FlowPaste.sameTarget(started: 42, frontNow: nil))
        XCTAssertTrue(FlowPaste.sameTarget(started: nil, frontNow: 77))   // nothing known: as before
    }

    /// A dropped file is checked by its size before a byte is read.
    func testUploadsAreSizedBeforeTheyAreRead() {
        XCTAssertTrue(ChatContext.canUpload(size: 10 * 1024 * 1024))
        XCTAssertFalse(ChatContext.canUpload(size: 3_000_000_000))
        XCTAssertFalse(ChatContext.canUpload(size: nil))
    }

    /// The pill over the notch stays only while something needs you (or you
    /// asked for it while agents work): a session that is merely working
    /// leaves the menu bar clear.
    func testThePillStaysOnlyWhenItHasSomethingToSay() {
        XCTAssertTrue(IslandVisibility.keepsPill(needsYou: true, working: false, showWhileWorking: false, alwaysShow: false))
        XCTAssertFalse(IslandVisibility.keepsPill(needsYou: false, working: true, showWhileWorking: false, alwaysShow: false))
        XCTAssertTrue(IslandVisibility.keepsPill(needsYou: false, working: true, showWhileWorking: true, alwaysShow: false))
        XCTAssertTrue(IslandVisibility.keepsPill(needsYou: false, working: false, showWhileWorking: false, alwaysShow: true))
        XCTAssertFalse(IslandVisibility.keepsPill(needsYou: false, working: false, showWhileWorking: true, alwaysShow: false))
    }

    /// Once nothing waits, an opened island folds and the pill leaves quickly.
    func testTheIslandSettlesQuicklyWhenNothingWaits() {
        XCTAssertLessThanOrEqual(IslandStateMachine.expandedHold, 8)
        XCTAssertLessThanOrEqual(IslandStateMachine.compactHold, 6)
        XCTAssertLessThanOrEqual(IslandController.earWidth, 40)
    }

    /// The open Agents island fits its tabs, the header and every row: one
    /// session with a step line must not be cut off at the bottom.
    func testTheOpenIslandFitsItsRows() {
        let one = IslandLayout.agentsHeight(topInset: 40, sessions: 1, pending: nil, flash: false)
        XCTAssertGreaterThanOrEqual(one, 40 + 34 + 10 + 40 + 10 + 58 + 14)
        let four = IslandLayout.agentsHeight(topInset: 40, sessions: 4, pending: nil, flash: false)
        XCTAssertEqual(four - one, 3 * IslandLayout.rowHeight)
        let asking = IslandLayout.agentsHeight(topInset: 40, sessions: 1, pending: .question, flash: true)
        XCTAssertGreaterThan(asking, one + 200)
        XCTAssertLessThanOrEqual(IslandLayout.agentsHeight(topInset: 40, sessions: 9, pending: .question, flash: true),
                                 IslandController.panelSize.height)
    }

    /// The island stays over the notch by default (Pranav: "it should always be there").
    func testTheIslandIsAlwaysThereByDefault() {
        UserDefaults.standard.removeObject(forKey: "island.hideWhenIdle")
        XCTAssertFalse(Prefs.hideWhenIdle)
        XCTAssertTrue(IslandVisibility.keepsPill(needsYou: false, working: false, showWhileWorking: false,
                                                 alwaysShow: !Prefs.hideWhenIdle))
    }
}

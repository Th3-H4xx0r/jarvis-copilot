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
}

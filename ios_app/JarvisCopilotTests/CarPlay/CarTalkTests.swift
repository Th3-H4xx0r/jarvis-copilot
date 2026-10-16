import XCTest
@testable import JarvisCopilot

/// The CarPlay Talk widget: one tap talks, a second stops, and what it shows.
final class CarTalkTests: XCTestCase {

    func testToggleStartsWhenIdleAndStopsWhenActive() {
        XCTAssertEqual(CarTalkBridge.action(sessionActive: false), .start)
        XCTAssertEqual(CarTalkBridge.action(sessionActive: true), .stop,
                       "a second tap stops — connecting, listening, thinking or speaking")
    }

    func testStaleSnapshotShowsIdle() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let stuck = CarTalkSnapshot(state: "listening", line: "how hot",
                                    updatedAt: now.addingTimeInterval(-(CarTalkSnapshot.staleAfter + 1)))
        let shown = stuck.shown(now: now)
        XCTAssertEqual(shown.state, "idle", "a killed app must not leave the widget saying Listening")
        XCTAssertEqual(shown.line, "")
    }

    func testFreshSnapshotKept() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let live = CarTalkSnapshot(state: "speaking", line: "It's 72 degrees.",
                                   updatedAt: now.addingTimeInterval(-5))
        XCTAssertEqual(live.shown(now: now), live)
    }

    func testAnOldIdleReplyStillClears() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let old = CarTalkSnapshot(state: "idle", line: "It's 72 degrees.",
                                  updatedAt: now.addingTimeInterval(-(CarTalkSnapshot.staleAfter + 1)))
        XCTAssertEqual(old.shown(now: now).line, "", "the reply leaves with its 2 minutes")
    }

    func testSnapshotRoundTrips() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "CarTalkTests-\(UUID().uuidString)"))
        XCTAssertEqual(CarTalkSnapshot.load(defaults).state, "idle", "nothing saved reads as idle")
        let snap = CarTalkSnapshot(state: "thinking", line: "how hot is it",
                                   updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        snap.save(defaults)
        XCTAssertEqual(CarTalkSnapshot.load(defaults), snap)
    }

    func testSnapshotFromTheVoiceTurn() {
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        let snap = CarTalkSnapshot(VoiceLiveActivitySnapshot(
            state: "speaking", transcript: "how hot is it", activity: "It's 72 degrees.",
            connected: true, devices: []), at: at)
        XCTAssertEqual(snap, CarTalkSnapshot(state: "speaking", line: "It's 72 degrees.", updatedAt: at))
    }
}

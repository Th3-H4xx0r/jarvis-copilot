import XCTest
@testable import Jarvis

/// Jarvis on the Mac lives in the notch: voice opens in the island, the old
/// menu-bar menu pops from a right-click, and the island stays light at idle.
final class NotchOnlyTests: XCTestCase {

    func testVoiceIsAnIslandViewButNotATab() {
        XCTAssertFalse(IslandTab.tabBar.contains(.voice))
        XCTAssertEqual(IslandTab.tabBar, IslandTab.allCases.filter { $0 != .voice })
        XCTAssertLessThanOrEqual(IslandTab.voice.height, IslandController.panelSize.height)
        XCTAssertGreaterThanOrEqual(IslandTab.voice.height, 400)   // the voice panel's own size fits
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

    /// The pointer is polled quickly only near the island; far away, once a
    /// second (a mouse-moved monitor wakes it as the pointer comes close).
    func testTheIslandPollsSlowlyWhenThePointerIsFarAway() {
        XCTAssertEqual(IslandTick.interval(expanded: false, nearIsland: false, inBand: false), 1.0)
        XCTAssertEqual(IslandTick.interval(expanded: false, nearIsland: false, inBand: true), 1.0 / 20)
        XCTAssertEqual(IslandTick.interval(expanded: true, nearIsland: false, inBand: false), 1.0 / 20)
        XCTAssertEqual(IslandTick.interval(expanded: true, nearIsland: true, inBand: true), 1.0 / 60)
    }
}

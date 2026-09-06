import XCTest
@testable import JarvisCopilot

@MainActor
final class AppRouterTests: XCTestCase {

    func testStartsOnChat() {
        let router = AppRouter()
        XCTAssertEqual(router.selectedTab, .chat)
        XCTAssertFalse(router.voiceLaunchRequested)
        XCTAssertEqual(router.voiceLaunchGeneration, 0)
    }

    func testSixTabsInFlutterOrder() {
        XCTAssertEqual(AppTab.allCases, [.chat, .voice, .skills, .devices, .coding, .more])
        for tab in AppTab.allCases {
            XCTAssertFalse(tab.title.isEmpty, "\(tab) has no title")
            XCTAssertFalse(tab.symbol.isEmpty, "\(tab) has no symbol")
            XCTAssertFalse(tab.filledSymbol.isEmpty, "\(tab) has no filled symbol")
        }
    }

    /// The latch is what makes a cold launch via Siri land on Voice: the request
    /// can arrive before any view has mounted to hear it.
    func testRequestLatchesAndSelectsVoice() {
        let router = AppRouter()
        router.requestVoiceLaunch()
        XCTAssertTrue(router.voiceLaunchRequested)
        XCTAssertEqual(router.selectedTab, .voice)
        XCTAssertEqual(router.voiceLaunchGeneration, 1)
    }

    func testConsumeClearsTheLatchExactlyOnce() {
        let router = AppRouter()
        router.requestVoiceLaunch()
        XCTAssertTrue(router.consumeVoiceLaunch())
        XCTAssertFalse(router.voiceLaunchRequested)
        XCTAssertFalse(router.consumeVoiceLaunch(), "a second consume must not re-fire")
    }

    func testConsumeLeavesTheSelectedTabAlone() {
        let router = AppRouter()
        router.requestVoiceLaunch()
        _ = router.consumeVoiceLaunch()
        XCTAssertEqual(router.selectedTab, .voice)
    }

    func testConsumeOnAnUnlatchedRouterIsFalse() {
        XCTAssertFalse(AppRouter().consumeVoiceLaunch())
    }

    /// `main.dart` re-arms by writing false-then-true so listeners fire even when a
    /// stale `true` is sitting there. Observation only notifies on change, so the
    /// generation counter is what a view watches to restart a turn.
    func testRepeatedRequestsRearmWhileStillLatched() {
        let router = AppRouter()
        router.requestVoiceLaunch()
        router.requestVoiceLaunch()
        XCTAssertTrue(router.voiceLaunchRequested)
        XCTAssertEqual(router.voiceLaunchGeneration, 2)
    }

    func testRequestFromAnotherTabSwitchesBackToVoice() {
        let router = AppRouter()
        router.selectedTab = .more
        router.requestVoiceLaunch()
        XCTAssertEqual(router.selectedTab, .voice)
    }
}

final class GlassNavBarLayoutTests: XCTestCase {
    /// Pages reserve exactly the bar's footprint; if the bar grows, the inset must too.
    func testReservedHeightMatchesTheBarFootprint() {
        XCTAssertEqual(GlassNavBar.reservedHeight, GlassNavBar.barHeight + GlassNavBar.bottomClearance)
        XCTAssertEqual(GlassNavBar.reservedHeight, 74)
    }
}

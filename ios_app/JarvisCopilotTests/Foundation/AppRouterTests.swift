import UIKit
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

    func testFiveTabsInFlutterOrder() {
        XCTAssertEqual(AppTab.allCases, [.chat, .voice, .integrations, .devices, .more])
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

    // MARK: Opening a screen in another tab

    func testOpenDevicesSelectsTheTabAndHandsItTheSection() {
        let router = AppRouter()
        router.openDevices(.server)
        XCTAssertEqual(router.selectedTab, .devices)
        XCTAssertEqual(router.consumeDevicesSection(), .server)
        XCTAssertNil(router.consumeDevicesSection(), "taken once")
    }

    func testOpenMoreSelectsTheTabAndHandsItTheScreen() {
        let router = AppRouter()
        router.openMore(.insights)
        XCTAssertEqual(router.selectedTab, .more)
        XCTAssertEqual(router.consumeMoreDestination(), .insights)
        XCTAssertNil(router.consumeMoreDestination())
    }

    func testAskingForTheSameScreenAgainStillNotifies() {
        let router = AppRouter()
        router.openDevices(.wearables)
        let first = router.screenRequestGeneration
        _ = router.consumeDevicesSection()
        router.openDevices(.wearables)
        XCTAssertGreaterThan(router.screenRequestGeneration, first)
    }
}

final class GlassNavBarLayoutTests: XCTestCase {
    /// Pages reserve exactly the bar's footprint; if the bar grows, the inset must too.
    func testReservedHeightMatchesTheBarFootprint() {
        XCTAssertEqual(GlassNavBar.reservedHeight, GlassNavBar.barHeight + GlassNavBar.bottomClearance)
        XCTAssertEqual(GlassNavBar.reservedHeight, 74)
    }

    /// "Integrations" is intrinsically wider than one sixth of the bar at 10pt,
    /// so it kept its width and drew straight out of the selected capsule and
    /// across its neighbours. It shrinks to fit now — but only down to
    /// `labelMinimumScale`, so a longer tab title would leak all over again.
    ///
    /// The narrowest phone the app supports is the 4.7" family at 375pt.
    func testEveryTabLabelFitsItsSlotOnTheNarrowestPhone() {
        for width in [375.0, 393.0, 430.0] as [CGFloat] {
            let room = GlassNavBar.labelWidth(screenWidth: width)
            for tab in AppTab.allCases {
                // Semibold is the selected weight, which is the wider one.
                let font = UIFont.systemFont(ofSize: GlassNavBar.labelSize, weight: .semibold)
                let natural = (tab.title as NSString).size(withAttributes: [.font: font]).width
                let smallest = natural * GlassNavBar.labelMinimumScale
                XCTAssertLessThanOrEqual(
                    smallest, room,
                    "\"\(tab.title)\" cannot shrink into its \(room)pt slot at \(width)pt wide "
                    + "— it needs \(smallest)pt. Shorten the title or the bar has to change.")
            }
        }
    }

    /// The slot arithmetic above divides by this, so a tab arriving or leaving
    /// has to come past the label-fit test.
    func testTheBarStillHasFiveTabs() {
        XCTAssertEqual(AppTab.allCases.count, 5)
    }

    /// Coding lives in the More grid now, not the bar.
    func testCodingIsAMoreDestinationAndNotATab() {
        XCTAssertFalse(AppTab.allCases.contains { $0.rawValue == "coding" })
        XCTAssertTrue(MoreDestination.allCases.contains(.coding))
    }

}

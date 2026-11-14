import XCTest
@testable import JarvisCopilot

@MainActor
final class PowerGatingTests: XCTestCase {
    override func tearDown() {
        PowerState.shared.apply(list: [])          // back to "everything on"
        super.tearDown()
    }

    private func off(_ ids: [String]) {
        PowerState.shared.apply(list: ids.map { ["id": $0, "name": $0, "enabled": false] })
    }

    func testMoreHidesOffDestinations() {
        off(["kanban", "photon"])
        let visible = MoreDestination.visible
        XCTAssertFalse(visible.contains(.kanban))
        XCTAssertFalse(visible.contains(.photon))
        XCTAssertTrue(visible.contains(.security))
        XCTAssertTrue(visible.contains(.integrations))
    }

    func testHealthTabHiddenWhileOff() {
        XCTAssertTrue(AppTab.visible.contains(.health))
        off(["jarvis-health"])
        XCTAssertFalse(AppTab.visible.contains(.health))
        XCTAssertEqual(AppTab.visibleCount, AppTab.allCases.count - 1)
    }

    func testPushCategoryDroppedWhileOff() {
        XCTAssertFalse(PowerPush.suppressed(category: "SECURITY_ALERT", offIDs: []))
        XCTAssertTrue(PowerPush.suppressed(category: "SECURITY_ALERT", offIDs: ["security-advisor"]))
        XCTAssertTrue(PowerPush.suppressed(category: "IMESSAGE_FACTS", offIDs: ["imessage-memory"]))
        XCTAssertFalse(PowerPush.suppressed(category: "SOMETHING_ELSE", offIDs: ["imessage-memory"]))
    }

    func testDashcamOffDropsItsCarPlayScreen() {
        off(["dashcam"])
        XCTAssertNil(DashcamLinkable.shared.carPlayScreen)
    }

    func testStarterRunsOnceWhenSwitchedOn() {
        off(["widgets-test"])
        var runs = 0
        PowerGates.whenOn("widgets-test") { runs += 1 }
        XCTAssertEqual(runs, 0)
        PowerState.shared.apply(list: [["id": "widgets-test", "name": "W", "enabled": true]])
        XCTAssertEqual(runs, 1)
        off(["widgets-test"])
        PowerState.shared.apply(list: [["id": "widgets-test", "name": "W", "enabled": true]])
        XCTAssertEqual(runs, 1)
    }
}

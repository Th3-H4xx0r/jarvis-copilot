import XCTest
@testable import JarvisCopilot

/// Case-for-case port of `mobile_client/test/voice/orb_ticker_policy_test.dart`.
final class OrbTickerPolicyTests: XCTestCase {

    func testAnimatesOnlyWhenTheOwningTabIsTheActiveTab() {
        // Voice-tab orb (owner = 1)
        XCTAssertTrue(orbTickerEnabled(activeTab: 1, ownerTab: 1))
        XCTAssertFalse(orbTickerEnabled(activeTab: 0, ownerTab: 1))
        XCTAssertFalse(orbTickerEnabled(activeTab: 4, ownerTab: 1))
        // Chat empty-state orb (owner = 0) animates on the Chat tab, not elsewhere
        XCTAssertTrue(orbTickerEnabled(activeTab: 0, ownerTab: 0))
        XCTAssertFalse(orbTickerEnabled(activeTab: 1, ownerTab: 0))
    }

    func testNullOwnerAlwaysAnimates() {
        XCTAssertTrue(orbTickerEnabled(activeTab: 3, ownerTab: nil))
    }
}

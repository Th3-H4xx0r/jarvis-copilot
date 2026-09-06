import XCTest
@testable import JarvisCopilot

/// Ported case-for-case from `test/live_activity/la_poll_policy_test.dart`.
final class LivePollPolicyTests: XCTestCase {

    // MARK: laPollInterval

    func testFastWhenVoiceIsActive() {
        XCTAssertEqual(
            LivePollPolicy.pollInterval(voiceActive: true, codingVisible: false, sessionTotal: 0),
            5)
    }

    func testFastWhenTheCodingTabIsVisible() {
        XCTAssertEqual(
            LivePollPolicy.pollInterval(voiceActive: false, codingVisible: true, sessionTotal: 0),
            5)
    }

    func testFastWhenThereAreLiveSessions() {
        XCTAssertEqual(
            LivePollPolicy.pollInterval(voiceActive: false, codingVisible: false, sessionTotal: 2),
            5)
    }

    func testSlowDiscoveryWhenNothingIsLiveAndNobodyIsLooking() {
        XCTAssertEqual(
            LivePollPolicy.pollInterval(voiceActive: false, codingVisible: false, sessionTotal: 0),
            60)
    }

    // MARK: shouldFetchUsage

    /// 2026-06-12 12:00:00 — the Dart test's `base`.
    private let base = Date(timeIntervalSince1970: 1_781_006_400)

    func testFetchesWhenNeverFetchedOrStale() {
        XCTAssertTrue(LivePollPolicy.shouldFetchUsage(now: base, lastUsageFetch: base.addingTimeInterval(-60)))
        XCTAssertTrue(LivePollPolicy.shouldFetchUsage(now: base, lastUsageFetch: Date(timeIntervalSince1970: 0)))
    }

    func testSkipsWhenFetchedWithin60s() {
        XCTAssertFalse(LivePollPolicy.shouldFetchUsage(now: base, lastUsageFetch: base.addingTimeInterval(-30)))
    }

    func testExactlyAtTheBoundaryFetches() {
        // Dart's `>=` boundary: 60s stale is a fetch, 59.9s is not.
        XCTAssertTrue(LivePollPolicy.shouldFetchUsage(now: base, lastUsageFetch: base.addingTimeInterval(-60)))
        XCTAssertFalse(LivePollPolicy.shouldFetchUsage(now: base, lastUsageFetch: base.addingTimeInterval(-59.9)))
    }
}

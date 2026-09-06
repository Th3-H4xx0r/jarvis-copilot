import XCTest
@testable import JarvisCopilot

/// Port of `mobile_client/test/services/poll_body_test.dart`.
final class PollBodyTests: XCTestCase {
    func testForegroundPollBodySetsForegroundTrue() {
        XCTAssertEqual(pollBody(foreground: true) as NSDictionary, ["foreground": true] as NSDictionary)
    }

    func testBackgroundPollBodySetsForegroundFalse() {
        XCTAssertEqual(pollBody(foreground: false) as NSDictionary, ["foreground": false] as NSDictionary)
    }
}

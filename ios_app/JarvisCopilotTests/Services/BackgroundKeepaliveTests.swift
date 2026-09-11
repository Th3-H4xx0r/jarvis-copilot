import Foundation
import XCTest
@testable import JarvisCopilot

/// `BackgroundKeepalive`\'s lifecycle. The arming rule itself is
/// `BridgeClient.syncKeepalive`.
final class BackgroundKeepaliveTests: XCTestCase {

    // MARK: The pure arming decision (Dart group 1, 6 cases)

    // MARK: Coalescing (Dart group 2)

    /// The transition guard's baseline: nothing has armed it in this process, so
    /// `stop()` is a no-op and `start()` is the first real transition.
    @MainActor
    func testTheSharedKeepaliveStartsIdle() {
        XCTAssertFalse(BackgroundKeepalive.shared.isRunning)
    }

}

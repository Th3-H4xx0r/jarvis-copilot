import XCTest
@testable import JarvisCopilot

/// Proves the XCTest harness is wired: the test bundle loads, the app module is
/// importable with @testable, and an existing pure function is reachable.
final class HarnessSmokeTests: XCTestCase {
    func testAppModuleIsReachable() {
        XCTAssertEqual(Esp32Protocol.crc8(Array("123456789".utf8)), 0xF4)
    }
}

import XCTest
@testable import JarvisCopilot

/// `MorePage` routes every tile through one `switch` over `MoreDestination`, so
/// the compiler catches a missing case. These tests guard the parts it can't:
/// that every tile is presentable and no two read the same.
final class MoreDestinationTests: XCTestCase {

    func testEveryDestinationHasATitleAndASymbol() {
        for destination in MoreDestination.allCases {
            XCTAssertFalse(destination.title.isEmpty, "\(destination) has no title")
            XCTAssertFalse(destination.symbol.isEmpty, "\(destination) has no SF Symbol")
        }
    }

    func testTitlesAreUnique() {
        let titles = MoreDestination.allCases.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count, "two tiles read the same")
    }
}

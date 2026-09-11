import XCTest
@testable import JarvisCopilot

/// `MorePage` routes every tile through one `switch` over `MoreDestination`, so
/// the compiler catches a missing case. These tests guard the parts it can't:
/// that the table is complete, unambiguous and presentable.
final class MoreDestinationTests: XCTestCase {

    func testEveryTileFromTheFlutterGridIsPresent() {
        XCTAssertEqual(MoreDestination.allCases, [
            .tasks, .kanban, .memory, .codeMemory, .longTermMemory, .workspaces,
            .profiles, .todos, .insights, .selfImprovement, .serverLogs,
            .islandDesigns, .photon, .appleWatch, .settings,
        ])
    }

    func testEveryDestinationHasATitleAndASymbol() {
        for destination in MoreDestination.allCases {
            XCTAssertFalse(destination.title.isEmpty, "\(destination) has no title")
            XCTAssertFalse(destination.symbol.isEmpty, "\(destination) has no SF Symbol")
        }
    }

    func testTitlesAndIdentifiersAreUnique() {
        let titles = MoreDestination.allCases.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count, "two tiles read the same")
        let ids = MoreDestination.allCases.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }
}

import XCTest
@testable import JarvisCopilot

final class DashcamTombstoneTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUp() {
        suite = "dashcam-tombstones-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    func testADeletedClipIsRememberedAndOthersAreNot() {
        DashcamTombstones.add("c_1", defaults: defaults, now: t0)
        XCTAssertTrue(DashcamTombstones.contains("c_1", defaults: defaults, now: t0))
        XCTAssertFalse(DashcamTombstones.contains("c_2", defaults: defaults, now: t0))
        XCTAssertEqual(DashcamTombstones.ids(defaults: defaults, now: t0), ["c_1"])
    }

    func testATombstoneLastsTwoWeeks() {
        DashcamTombstones.add("c_1", defaults: defaults, now: t0)
        XCTAssertTrue(DashcamTombstones.contains("c_1", defaults: defaults, now: t0.addingTimeInterval(13 * 86400)))
        XCTAssertFalse(DashcamTombstones.contains("c_1", defaults: defaults, now: t0.addingTimeInterval(14 * 86400 + 1)))
        XCTAssertTrue(DashcamTombstones.ids(defaults: defaults, now: t0.addingTimeInterval(15 * 86400)).isEmpty)
    }

    /// The list never grows past two weeks of deletes: expired ones go on the next write.
    func testExpiredTombstonesArePrunedOnWrite() {
        DashcamTombstones.add("old", defaults: defaults, now: t0)
        DashcamTombstones.add("new", defaults: defaults, now: t0.addingTimeInterval(15 * 86400))
        XCTAssertEqual(defaults.dictionary(forKey: DashcamTombstones.key).map { Set($0.keys) }, ["new"])
    }

    /// "Download again" brings a clip back.
    func testRemoveForgetsTheDelete() {
        DashcamTombstones.add("c_1", defaults: defaults, now: t0)
        DashcamTombstones.remove("c_1", defaults: defaults, now: t0)
        XCTAssertFalse(DashcamTombstones.contains("c_1", defaults: defaults, now: t0))
    }

    /// Only the server's own "clip not found" means deleted — never a 404 from anything else, and never
    /// "upload not found" (the server dropped an upload's chunks; it just starts over).
    func testOnlyTheServersClipNotFoundCountsAsDeleted() {
        XCTAssertTrue(DashcamAPI.isClipGone(APIError.http(status: 404, message: "clip not found")))
        XCTAssertTrue(DashcamAPI.isClipGone(APIError.http(status: 404, message: "clip_not_found")))
        XCTAssertFalse(DashcamAPI.isClipGone(APIError.http(status: 404, message: "upload not found")))
        XCTAssertFalse(DashcamAPI.isClipGone(APIError.http(status: 404, message: "unknown dashcam endpoint")))
        XCTAssertFalse(DashcamAPI.isClipGone(APIError.http(status: 404, message: "Request failed (404)")))
        XCTAssertFalse(DashcamAPI.isClipGone(APIError.http(status: 500, message: "clip not found")))
        XCTAssertFalse(DashcamAPI.isClipGone(URLError(.notConnectedToInternet)))
    }
}

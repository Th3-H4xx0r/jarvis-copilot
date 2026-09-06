import Foundation
import XCTest
@testable import JarvisCopilot

/// Ported from `mobile_client/test/memory_test.dart`, case for case.
final class MemoryTests: XCTestCase {

    // MARK: formatMemoryMtime

    func testNumericEpochSecondsGivesANonEmptyHumanString() {
        // 2021-06-20T17:33:20Z — the rendering is local-time dependent, so only
        // assert it produced something non-empty and year-bearing.
        let out = MemoryMtime.format(1_624_210_400)
        XCTAssertFalse(out.isEmpty)
        XCTAssertTrue(out.contains("2021"), out)
    }

    func testNumericEpochAsDoubleWorksToo() {
        XCTAssertFalse(MemoryMtime.format(1_624_210_400.123).isEmpty)
    }

    func testNumericEpochAsNumericStringIsParsed() {
        let out = MemoryMtime.format("1624210400")
        XCTAssertFalse(out.isEmpty)
        XCTAssertTrue(out.contains("2021"), out)
    }

    func testNilGivesEmptyString() {
        XCTAssertEqual(MemoryMtime.format(nil), "")
    }

    func testEmptyOrWhitespaceStringGivesEmptyString() {
        XCTAssertEqual(MemoryMtime.format(""), "")
        XCTAssertEqual(MemoryMtime.format("   "), "")
    }

    func testZeroOrNegativeEpochGivesEmptyString() {
        XCTAssertEqual(MemoryMtime.format(0), "")
        XCTAssertEqual(MemoryMtime.format(-5), "")
    }

    func testAlreadyFormattedNonNumericStringIsReturnedAsIs() {
        let pretty = "Jun 21, 2026, 3:07 PM"
        XCTAssertEqual(MemoryMtime.format(pretty), pretty)
    }

    func testUnexpectedTypeGivesEmptyString() {
        XCTAssertEqual(MemoryMtime.format(JSONObject()), "")
        XCTAssertEqual(MemoryMtime.format([1, 2, 3]), "")
    }

    /// `RelativeTime.absolute` is hand-rolled against `Calendar.current` so the
    /// string never shifts with the device LOCALE; the device TIME ZONE is the
    /// only variable, so pin a calendar and assert the exact string.
    func testFormattedOutputIsTheExactLocalTimestamp() {
        let date = Date(timeIntervalSince1970: 1_624_210_400)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Calendar.current.timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let hour24 = c.hour!
        let expected = String(format: "%@ %d, %d, %d:%02d %@",
                              RelativeTime.months[c.month! - 1], c.day!, c.year!,
                              hour24 % 12 == 0 ? 12 : hour24 % 12, c.minute!,
                              hour24 < 12 ? "AM" : "PM")
        XCTAssertEqual(MemoryMtime.format(1_624_210_400), expected)
    }

    /// A 12-hour clock and an English month, whatever locale the device is in —
    /// this is why it is not a `DateFormatter`.
    func testTheTimestampIsLocaleIndependentByConstruction() {
        let out = MemoryMtime.format(1_624_210_400)
        XCTAssertTrue(out.hasSuffix(" AM") || out.hasSuffix(" PM"), out)
        XCTAssertTrue(RelativeTime.months.contains { out.hasPrefix($0 + " ") }, out)
    }

    // MARK: Section metadata (memory_page logic)

    func testSectionWireKeysAndLabels() {
        XCTAssertEqual(MemorySection.memory.wireKey, "memory")
        XCTAssertEqual(MemorySection.user.wireKey, "user")
        XCTAssertEqual(MemorySection.memory.label, "My Notes")
        XCTAssertEqual(MemorySection.user.label, "User Profile")
        XCTAssertEqual(MemorySection.memory.contentKey, "memory")
        XCTAssertEqual(MemorySection.user.contentKey, "user")
        XCTAssertEqual(MemorySection.memory.mtimeKey, "memory_mtime")
        XCTAssertEqual(MemorySection.user.mtimeKey, "user_mtime")
        XCTAssertEqual(MemorySection.memory.emptyText, "No notes yet.")
        XCTAssertEqual(MemorySection.user.emptyText, "No profile yet.")
    }

    // MARK: Payload parsing

    func testDocumentsToleratePartialBodies() {
        let docs = MemoryDocuments(json: ["memory": "notes"])
        XCTAssertEqual(docs.memory, "notes")
        XCTAssertEqual(docs.user, "")
        XCTAssertNil(docs.memoryPath)
        XCTAssertNil(docs.userMtime)
        XCTAssertEqual(docs.mtimeLabel(for: .user), "")
    }

    func testDocumentsIsEmptyOnlyBeforeAnythingLoads() {
        XCTAssertTrue(MemoryDocuments().isEmpty)
        XCTAssertFalse(MemoryDocuments(json: ["memory": "x"]).isEmpty)
        XCTAssertFalse(MemoryDocuments(json: ["memory_path": "/tmp/MEMORY.md"]).isEmpty)
    }

    // MARK: API requests

    func testReadHitsApiMemory() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: [
            "memory": "notes", "user": "profile",
            "memory_path": "/m.md", "user_path": "/u.md",
            "memory_mtime": 1_624_210_400, "user_mtime": 1_624_210_500,
        ])
        let docs = try await MemoryAPI(api: api).read()

        XCTAssertEqual(transport.lastMethod, "GET")
        XCTAssertEqual(transport.lastPath, "/api/memory")
        XCTAssertEqual(transport.lastQuery, [:])
        XCTAssertEqual(docs.memory, "notes")
        XCTAssertEqual(docs.user, "profile")
        XCTAssertEqual(docs.memoryPath, "/m.md")
        XCTAssertFalse(docs.mtimeLabel(for: .memory).isEmpty)
    }

    func testWritePostsSectionAndContent() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["ok": true])
        try await MemoryAPI(api: api).write(.user, content: "hello")

        XCTAssertEqual(transport.lastMethod, "POST")
        XCTAssertEqual(transport.lastPath, "/api/memory/write")
        XCTAssertEqual(transport.lastQuery, [:])
        assertJSONEqual(transport.lastBody(), ["section": "user", "content": "hello"])
    }

    // MARK: Store

    @MainActor
    func testStoreSwitchesSectionAndSavesThenReloads() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["memory": "old notes", "user": "me"])
        let store = MemoryStore(api: MemoryAPI(api: api))
        await store.refresh()

        XCTAssertEqual(store.content, "old notes")
        store.section = .user
        XCTAssertEqual(store.content, "me")
        XCTAssertTrue(store.canEdit)

        transport.enqueue(json: ["ok": true])                        // the write
        transport.enqueue(json: ["memory": "old notes", "user": "new me"]) // the re-read
        let saved = await store.save("new me")

        XCTAssertTrue(saved)
        XCTAssertEqual(transport.path(1), "/api/memory/write")
        assertJSONEqual(transport.body(1), ["section": "user", "content": "new me"])
        XCTAssertEqual(transport.path(2), "/api/memory")
        XCTAssertEqual(store.content, "new me")
    }

    @MainActor
    func testStoreSaveFailureKeepsTheErrorAndDoesNotReRead() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["memory": "notes"])
        let store = MemoryStore(api: MemoryAPI(api: api))
        await store.refresh()

        transport.enqueue(json: ["error": "read-only file system"], status: 500)
        let saved = await store.save("nope")

        XCTAssertFalse(saved)
        XCTAssertEqual(store.errorMessage, "read-only file system")
        XCTAssertEqual(transport.requests.count, 2)
    }

    @MainActor
    func testStoreCannotEditBeforeLoading() {
        let (api, _) = JarvisAPI.mocked()
        let store = MemoryStore(api: MemoryAPI(api: api))
        XCTAssertFalse(store.canEdit)
    }
}

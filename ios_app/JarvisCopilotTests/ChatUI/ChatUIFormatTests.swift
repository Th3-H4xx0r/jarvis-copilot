import XCTest
@testable import JarvisCopilot

/// The pure formatting the chat views do: the app-bar/model capsule labels, the
/// attachment chip's size line, and the sessions-sheet grouping.
final class ChatUIFormatTests: XCTestCase {

    // MARK: Model labels

    func testShortModelNameKeepsTheLastPathSegment() {
        XCTAssertEqual(ChatUIFormat.shortModelName("anthropic/claude-sonnet-4"), "claude-sonnet-4")
    }

    func testShortModelNameDropsAProviderColonPrefix() {
        XCTAssertEqual(ChatUIFormat.shortModelName("ollama:llama3"), "llama3")
    }

    func testShortModelNameTruncatesWithAnEllipsis() {
        let short = ChatUIFormat.shortModelName("openai/gpt-4o-mini-realtime-preview", limit: 18)
        XCTAssertEqual(short, "gpt-4o-mini-realt…")
        XCTAssertEqual(short.count, 18)
    }

    func testShortModelNameOfNothingIsAuto() {
        XCTAssertEqual(ChatUIFormat.shortModelName(""), "Auto")
        XCTAssertEqual(ChatUIFormat.shortModelName("   "), "Auto")
    }

    func testShortModelNameLeavesAShortIdAlone() {
        XCTAssertEqual(ChatUIFormat.shortModelName("gpt-4o"), "gpt-4o")
    }

    // MARK: Titles

    func testTruncateLeavesShortTitles() {
        XCTAssertEqual(ChatUIFormat.truncate("Groceries", limit: 20), "Groceries")
    }

    func testTruncateClipsAndCollapsesWhitespace() {
        XCTAssertEqual(ChatUIFormat.truncate("A very long chat title indeed", limit: 12),
                       "A very long…")
        XCTAssertEqual(ChatUIFormat.truncate("  spaced   out  ", limit: 20), "spaced out")
    }

    // MARK: Attachment size labels

    func testFileSizeLabels() {
        XCTAssertEqual(ChatUIFormat.fileSize(0), "0 B")
        XCTAssertEqual(ChatUIFormat.fileSize(940), "940 B")
        XCTAssertEqual(ChatUIFormat.fileSize(2_048), "2 KB")
        XCTAssertEqual(ChatUIFormat.fileSize(1_572_864), "1.5 MB")
        XCTAssertEqual(ChatUIFormat.fileSize(104_857_600), "100.0 MB")
    }

    // MARK: Session grouping

    private func session(_ id: String, _ title: String, daysAgo: Double? = nil,
                         pinned: Bool = false) -> ChatSessionSummary {
        let now = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11-14 22:13 UTC
        let stamp = daysAgo.map { Int(now.addingTimeInterval(-$0 * 86_400).timeIntervalSince1970) }
        return ChatSessionSummary(id: id, title: title, updatedAt: stamp, pinned: pinned)
    }

    private var now: Date { Date(timeIntervalSince1970: 1_700_000_000) }

    /// A fixed-offset calendar so the buckets don't move with the runner's zone.
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }

    func testGroupsArePinnedThenTodayYesterdayEarlier() {
        let rows = [
            session("a", "Pinned one", daysAgo: 9, pinned: true),
            session("b", "Fresh", daysAgo: 0.1),
            session("c", "Yesterday's", daysAgo: 1),
            session("d", "Old", daysAgo: 30),
        ]
        let groups = ChatSessionGroup.group(rows, now: now, calendar: calendar)
        XCTAssertEqual(groups.map(\.title), ["Pinned", "Today", "Yesterday", "Earlier"])
        XCTAssertEqual(groups.map { $0.sessions.map(\.id) }, [["a"], ["b"], ["c"], ["d"]])
    }

    func testPinnedWinsOverItsDateBucket() {
        let rows = [session("a", "Today but pinned", daysAgo: 0.1, pinned: true)]
        let groups = ChatSessionGroup.group(rows, now: now, calendar: calendar)
        XCTAssertEqual(groups.map(\.title), ["Pinned"])
    }

    func testEmptyGroupsAreOmitted() {
        let groups = ChatSessionGroup.group([session("b", "Fresh", daysAgo: 0.1)],
                                            now: now, calendar: calendar)
        XCTAssertEqual(groups.map(\.title), ["Today"])
    }

    func testUndatedSessionsFallToEarlier() {
        let groups = ChatSessionGroup.group([session("x", "No stamp")], now: now, calendar: calendar)
        XCTAssertEqual(groups.map(\.title), ["Earlier"])
    }

    func testSearchFiltersCaseInsensitivelyOnTheDisplayTitle() {
        let rows = [
            session("a", "Grocery list", daysAgo: 0.1),
            session("b", "Deploy notes", daysAgo: 0.1),
            session("c", "", daysAgo: 0.1),   // displays as "New chat"
        ]
        XCTAssertEqual(ChatSessionGroup.group(rows, query: "GROCE", now: now, calendar: calendar)
                        .flatMap { $0.sessions.map(\.id) }, ["a"])
        XCTAssertEqual(ChatSessionGroup.group(rows, query: "new ch", now: now, calendar: calendar)
                        .flatMap { $0.sessions.map(\.id) }, ["c"])
        XCTAssertTrue(ChatSessionGroup.group(rows, query: "zzz", now: now, calendar: calendar).isEmpty)
    }

    func testSearchIgnoresSurroundingWhitespace() {
        let rows = [session("a", "Grocery list", daysAgo: 0.1)]
        XCTAssertEqual(ChatSessionGroup.group(rows, query: "  grocery ", now: now, calendar: calendar)
                        .flatMap { $0.sessions.map(\.id) }, ["a"])
    }

    func testGroupingPreservesTheIncomingOrderWithinEachBucket() {
        let rows = [
            session("new", "Newer", daysAgo: 0.1),
            session("old", "Older", daysAgo: 0.4),
        ]
        let groups = ChatSessionGroup.group(rows, now: now, calendar: calendar)
        XCTAssertEqual(groups.first?.sessions.map(\.id), ["new", "old"])
    }
}

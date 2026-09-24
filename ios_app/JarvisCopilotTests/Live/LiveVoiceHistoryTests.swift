import XCTest
@testable import JarvisCopilot

/// A voice's whole history on the Voices screen, a page at a time: the next
/// page is asked for with the last one's cursor, and never after the end.
@MainActor
final class LiveVoiceHistoryTests: XCTestCase {
    private func line(_ text: String, seq: Int, translation: String? = nil) -> [String: Any] {
        ["live_session_id": "L1", "seq": seq, "ts_start_ms": seq * 1000, "ts_end_ms": seq * 1000 + 900,
         "at": 1_790_000_000.0 + Double(seq), "text": text, "lang": "te",
         "translation": translation as Any? ?? NSNull(), "session_title": "Standup"]
    }

    func testPagesLoadInOrderAndStopAtTheEnd() async throws {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["speaker_id": "s1", "total": 3,
                                 "lines": [line("c", seq: 3), line("b", seq: 2)], "next": "cur1"])
        transport.enqueue(json: ["speaker_id": "s1", "total": 3,
                                 "lines": [line("a", seq: 1)], "next": NSNull()])
        let history = LiveVoiceHistory(speakerID: "s1", api: LiveAPI(api: api))

        await history.loadMore()
        XCTAssertEqual(history.lines.map(\.text), ["c", "b"])
        XCTAssertEqual(history.total, 3)
        XCTAssertFalse(history.done)

        await history.loadMore()
        XCTAssertEqual(history.lines.map(\.text), ["c", "b", "a"])
        XCTAssertTrue(history.done)
        let query = try XCTUnwrap(transport.requests.last?.url?.query)
        XCTAssertTrue(query.contains("before=cur1"), query)

        await history.loadMore()
        XCTAssertEqual(transport.requests.count, 2, "nothing more is asked for after the end")
    }

    func testALineKnowsWhenItWasSaidAndItsTranslation() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["total": 1, "lines": [line("అమ్మా", seq: 2, translation: "Mom")], "next": NSNull()])
        let history = LiveVoiceHistory(speakerID: "s1", api: LiveAPI(api: api))
        await history.loadMore()
        let first = history.lines.first
        XCTAssertEqual(first?.translation, "Mom")
        XCTAssertEqual(first?.sessionTitle, "Standup")
        XCTAssertEqual(first?.at.timeIntervalSince1970 ?? 0, 1_790_000_002, accuracy: 0.01)
    }

    func testAFailedPageSaysSoAndCanBeRetried() async {
        let (api, transport) = JarvisAPI.mocked()
        transport.enqueue(json: ["error": "busy"], status: 500)
        transport.enqueue(json: ["total": 1, "lines": [line("a", seq: 1)], "next": NSNull()])
        let history = LiveVoiceHistory(speakerID: "s1", api: LiveAPI(api: api))
        await history.loadMore()
        XCTAssertFalse(history.error.isEmpty)
        XCTAssertFalse(history.done)
        await history.loadMore()
        XCTAssertEqual(history.lines.map(\.text), ["a"])
        XCTAssertEqual(history.error, "")
    }
}

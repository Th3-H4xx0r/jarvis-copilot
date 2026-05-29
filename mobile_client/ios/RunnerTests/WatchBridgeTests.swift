import XCTest
@testable import Runner

final class WatchBridgeTests: XCTestCase {
    // The real server emits assistant text as `token` events and terminates
    // with `stream_end` (see webui/api/streaming.py) — NOT delta/done.
    func testAccumulateTokens() {
        let sse = """
        event: token
        data: {"text": "It's "}

        event: token
        data: {"text": "72\u{00B0}."}

        event: stream_end
        data: {"session": {}, "usage": {}}
        """
        let r = WatchRelay.accumulateSSE(sse)
        XCTAssertEqual(r.text, "It's 72\u{00B0}.")
        XCTAssertTrue(r.done)
        XCTAssertFalse(r.errored)
    }

    func testHeartbeatsAndBlankLinesIgnored() {
        let sse = ": heartbeat\n\nevent: token\ndata: {\"text\": \"hi\"}\n\n: heartbeat\n"
        let r = WatchRelay.accumulateSSE(sse)
        XCTAssertEqual(r.text, "hi")
        XCTAssertFalse(r.errored)
    }

    func testApperrorEventMarksErrored() {
        let r = WatchRelay.accumulateSSE("event: apperror\ndata: {\"error\": \"boom\"}")
        XCTAssertTrue(r.errored)
    }

    func testDoneAndCancelStillHandled() {
        XCTAssertTrue(WatchRelay.accumulateSSE("event: done\ndata: {}").done)
        XCTAssertTrue(WatchRelay.accumulateSSE("event: cancel\ndata: {}").errored)
    }

    func testSessionIdTopLevelAndNested() {
        XCTAssertEqual(WatchRelay.extractSessionId(["session_id": "abc"]), "abc")
        XCTAssertEqual(WatchRelay.extractSessionId(["session": ["session_id": "def"]]), "def")
        XCTAssertNil(WatchRelay.extractSessionId(["nope": 1]))
        XCTAssertNil(WatchRelay.extractSessionId(["session_id": ""]))
    }
}

import XCTest
@testable import JarvisCopilot

/// What the phone asks the server to push instead of polling (battery drain, 2026-10-13).
@MainActor
final class BridgeTopicsTests: XCTestCase {
    private func topics() -> (BridgeTopics, () -> [[String: TimeInterval]]) {
        let t = BridgeTopics()
        var frames: [[String: TimeInterval]] = []
        t.send = { frame in frames.append(frame["topics"] as? [String: TimeInterval] ?? [:]) }
        return (t, { frames })
    }

    func testTheMostEagerOwnerSetsTheInterval() {
        let (t, frames) = topics()
        t.want("widgets", owner: "a", every: 1800)
        t.want("widgets", owner: "b", every: 60)
        XCTAssertEqual(t.topics, ["widgets": 60])
        t.drop("widgets", owner: "b")
        XCTAssertEqual(t.topics, ["widgets": 1800])
        XCTAssertEqual(frames(), [["widgets": 1800], ["widgets": 60], ["widgets": 1800]])
    }

    func testAnUnchangedSetIsNotSentAgain() {
        let (t, frames) = topics()
        t.want("pods", owner: "devices")
        t.want("pods", owner: "devices")
        t.drop("dashcam", owner: "nobody")
        XCTAssertEqual(frames().count, 1)
    }

    func testDroppingTheLastOwnerUnsubscribes() {
        let (t, frames) = topics()
        t.want("pods", owner: "devices")
        t.drop("pods", owner: "devices")
        XCTAssertFalse(t.isWanted("pods"))
        XCTAssertEqual(frames().last, [:])
    }

    func testAReconnectSendsTheSetAgainAndCatchesUp() {
        let (t, frames) = topics()
        var caughtUp = 0
        t.onResync { caughtUp += 1 }
        t.want("dashcam", owner: "uploads")
        t.forget()
        t.resubscribe()
        XCTAssertEqual(frames(), [["dashcam": 0], ["dashcam": 0]])
        XCTAssertEqual(caughtUp, 1)
    }

    func testPushesReachTheirTopicOnly() {
        let (t, _) = topics()
        var pods: [[String: Any]] = []
        var dashcam = 0
        t.on("pods") { pods.append($0) }
        t.on("dashcam") { _ in dashcam += 1 }
        t.deliver(["type": "topic", "topic": "pods", "data": ["what": ["list"]]])
        t.deliver(["type": "topic", "data": [:]])
        XCTAssertEqual(pods.count, 1)
        XCTAssertEqual(pods.first?["what"] as? [String], ["list"])
        XCTAssertEqual(dashcam, 0)
    }

    func testTheFrameIsASubscribe() {
        let (t, _) = topics()
        t.want("pods", owner: "devices")
        XCTAssertEqual(t.frame["type"] as? String, "subscribe")
    }
}

import XCTest
@testable import JarvisCopilot

/// Game Streaming models decode the `/status` payload, and the card view-model
/// derives the live label and the one main button.
final class GameStreamingModelTests: XCTestCase {

    private func status(_ json: [String: Any]) throws -> GameStreamingStatus {
        let data = try JSONSerialization.data(withJSONObject: json)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return GameStreamingStatus(json: obj)
    }

    private let sample: [String: Any] = [
        "ok": true,
        "reachable": true,
        "live": ["active": true, "client": "Living Room TV", "app": "Cyberpunk 2077"],
        "paired": [["name": "Mac", "uuid": "abc-123"], ["name": "Shield", "uuid": "def-456"]],
        "apps": [["name": "Cyberpunk 2077"], ["name": "Hades"], ["name": "Desktop"]],
        "targets": [["name": "Mac", "kind": "mac", "host": "gpc"],
                    ["name": "Living Room", "kind": "androidtv", "host": "10.0.0.5"]],
    ]

    func testDecodeStatusPayload() throws {
        let s = try status(sample)
        XCTAssertTrue(s.ok)
        XCTAssertTrue(s.reachable)
        XCTAssertTrue(s.live.active)
        XCTAssertEqual(s.live.app, "Cyberpunk 2077")
        XCTAssertEqual(s.live.client, "Living Room TV")
        XCTAssertEqual(s.paired.map(\.name), ["Mac", "Shield"])
        XCTAssertEqual(s.paired.first?.uuid, "abc-123")
        XCTAssertEqual(s.apps.map(\.name), ["Cyberpunk 2077", "Hades", "Desktop"])
        XCTAssertEqual(s.targets.map(\.name), ["Mac", "Living Room"])
        XCTAssertEqual(s.targets.first?.kind, "mac")
        XCTAssertEqual(s.targets.last?.kindLabel, "Android TV")
    }

    func testStatusToleratesMissingAndEmptyFields() throws {
        let s = try status(["ok": true])
        XCTAssertTrue(s.ok)
        XCTAssertFalse(s.reachable)
        XCTAssertFalse(s.live.active)
        XCTAssertNil(s.live.app)
        XCTAssertTrue(s.paired.isEmpty)
        XCTAssertTrue(s.apps.isEmpty)
        XCTAssertTrue(s.targets.isEmpty)
        // A paired entry with neither name nor uuid is dropped, not kept blank.
        let messy = try status(["paired": [["name": "", "uuid": ""], ["name": "Mac", "uuid": "x"]]])
        XCTAssertEqual(messy.paired.map(\.name), ["Mac"])
    }

    func testLiveLabelOnlyWhenActive() throws {
        XCTAssertEqual(GameStreamingCardModel.liveLabel(try status(sample)), "Streaming Cyberpunk 2077")
        let idle = try status(["live": ["active": false]])
        XCTAssertNil(GameStreamingCardModel.liveLabel(idle))
        // Active with no app name still reads as a stream.
        let noApp = try status(["live": ["active": true]])
        XCTAssertEqual(GameStreamingCardModel.liveLabel(noApp), "Streaming a game")
        XCTAssertNil(GameStreamingCardModel.liveLabel(nil))
    }

    func testPrimaryPrefersLastStreamThenFirstTarget() throws {
        let s = try status(sample)
        // No history: first game + first target the host offers.
        let first = GameStreamingCardModel.primary(s, recent: nil)
        XCTAssertEqual(first, GamePrimary(game: "Cyberpunk 2077", target: "Mac"))
        XCTAssertEqual(GameStreamingCardModel.primaryTitle(first), "Stream Cyberpunk 2077 -> Mac")

        // A recent whose target still exists wins.
        let recent = GameRecent(game: "Hades", target: "Living Room", at: Date())
        XCTAssertEqual(GameStreamingCardModel.primary(s, recent: recent),
                       GamePrimary(game: "Hades", target: "Living Room"))

        // A recent whose target is gone falls back to the first target.
        let stale = GameRecent(game: "Hades", target: "Old TV", at: Date())
        XCTAssertEqual(GameStreamingCardModel.primary(s, recent: stale)?.target, "Mac")
    }

    func testPrimaryNilWithoutTargets() throws {
        let noTargets = try status(["apps": [["name": "Hades"]]])
        XCTAssertNil(GameStreamingCardModel.primary(noTargets, recent: nil))
        XCTAssertEqual(GameStreamingCardModel.primaryTitle(nil), "Open Game Streaming")
    }

    func testDecodesNeedsLogin() throws {
        let s = try status(["ok": true, "reachable": false, "needs_login": true])
        XCTAssertFalse(s.reachable)
        XCTAssertTrue(s.needsLogin)
        // default false when the key is absent
        XCTAssertFalse(try status(["reachable": true]).needsLogin)
    }

    func testStatusTitleTellsNeedsLoginFromUnreachable() throws {
        // genuinely offline: "Host unreachable", and the queue-a-stream hint
        let offline = try status(["reachable": false])
        XCTAssertEqual(GameStreamingCardModel.statusTitle(offline), "Host unreachable")
        XCTAssertEqual(GameStreamingCardModel.statusDetail(offline),
                       "Waking or offline — start still queues a stream")
        // running but the login is wrong: a sign-in prompt, not "unreachable"
        let needsLogin = try status(["reachable": false, "needs_login": true])
        XCTAssertEqual(GameStreamingCardModel.statusTitle(needsLogin),
                       "Sunshine needs sign-in — check your password")
        XCTAssertEqual(GameStreamingCardModel.statusDetail(needsLogin),
                       "Open Set up and re-enter your Sunshine password")
        // idle
        XCTAssertEqual(GameStreamingCardModel.statusTitle(try status(["reachable": true])), "Idle")
        // a live stream wins over everything
        let live = try status(["reachable": true,
                               "live": ["active": true, "app": "Hades", "client": "Mac"]])
        XCTAssertEqual(GameStreamingCardModel.statusTitle(live), "Streaming Hades")
        XCTAssertEqual(GameStreamingCardModel.statusDetail(live), "On Mac")
    }
}

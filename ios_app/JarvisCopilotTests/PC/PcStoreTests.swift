import XCTest
@testable import JarvisCopilot

@MainActor
final class PcStoreTests: XCTestCase {
    static let body: [String: Any] = [
        "device_id": "pc-1", "online": true, "address": "127.0.0.1:6742",
        "state": ["on": true, "brightness": 65, "t0": 1000.0, "frozen_at": NSNull(), "still_in_games": false, "rev": 3,
                  "parts": ["top": ["effect": "rainbow", "color": "#22d3ee", "speed": 5],
                            "rear": ["effect": "static", "color": "#ffffff", "speed": 5],
                            "bottom": ["effect": "static", "color": "#ffffff", "speed": 5],
                            "cooler": ["effect": "static", "color": "#ffffff", "speed": 5],
                            "strip": ["effect": "comet", "color": "#ff0000", "speed": 7]]],
        "map": ["version": 1, "rev": 2, "zones": [["controller": 0, "zone": 0, "leds": 32]],
                "segments": [["part": "top", "index": 0, "controller": 0, "zone": 0, "start": 0, "count": 16,
                              "ring_start_deg": 90, "clockwise": true]]],
        "looks": [["name": "Gaming", "brightness": 80, "parts": [:]]],
        "setup": ["detect": ["id": "detect", "state": "done", "detail": "ASRock Polychrome USB (4 zones)"]],
        "coverage": ["top": NSNull(), "rear": "top", "bottom": "missing", "cooler": "missing", "strip": "missing"],
        "live": ["engine": "running", "error": NSNull(), "paused_for_game": false,
                 "controllers": [["index": 0, "name": "ASRock Polychrome USB", "location": "HID", "zones": []]]],
    ]

    func testApplyDecodesEverythingTheServerSends() {
        let store = PcStore(api: JarvisAPI(credentials: TestCredentials(), transport: MockTransport()))
        store.apply(Self.body)
        XCTAssertEqual(store.deviceId, "pc-1")
        XCTAssertTrue(store.online)
        XCTAssertEqual(store.state?.brightness, 65)
        XCTAssertEqual(store.state?.light(.strip).effect, "comet")
        XCTAssertEqual(store.map?.segments.first?.ringStartDeg, 90)
        XCTAssertEqual(store.looks.map(\.name), ["Gaming"])
        XCTAssertEqual(store.setup["detect"]?.state, "done")
        XCTAssertEqual(store.sharesWith(.rear), .top)
        XCTAssertTrue(store.isMissing(.bottom))
        XCTAssertNil(store.sharesWith(.top))
        XCTAssertEqual(store.engine, "running")
        XCTAssertEqual(store.controllers.first?.name, "ASRock Polychrome USB")
    }

    func testOfflinePCReturnsTheServersReasonAndKeepsState() async {
        let t = MockTransport()
        t.route("/api/pc-lighting/state", json: ["ok": false, "error": "The PC is asleep or offline", "offline": true], status: 409)
        let store = PcStore(api: JarvisAPI(credentials: TestCredentials(), transport: t))
        store.apply(Self.body)
        let err = await store.set(part: nil, color: "#00ff00")
        XCTAssertEqual(err, "The PC is asleep or offline")
        XCTAssertEqual(store.state?.light(.top).color, "#22d3ee")
    }

    func testSetPostsThePartialAndTakesTheNewState() async {
        let t = MockTransport()
        var newState = Self.body["state"] as! [String: Any]
        var parts = newState["parts"] as! [String: Any]
        parts["top"] = ["effect": "static", "color": "#00ff00", "speed": 5]
        newState["parts"] = parts
        t.route("/api/pc-lighting/state", json: ["ok": true, "state": newState])
        let store = PcStore(api: JarvisAPI(credentials: TestCredentials(), transport: t))
        store.apply(Self.body)
        let err = await store.set(part: .top, effect: .still, color: "#00ff00")
        XCTAssertNil(err)
        XCTAssertEqual(t.lastBody()["part"] as? String, "top")
        XCTAssertEqual(t.lastBody()["effect"] as? String, "static")
        XCTAssertEqual(store.state?.light(.top).color, "#00ff00")
    }
}

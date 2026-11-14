import CoreGraphics
import XCTest
@testable import JarvisCopilot

final class HoloDropCoreTests: XCTestCase {
    private func device(_ id: String, kind: String = "mac", bearing: Double? = nil, action: String = "open") -> HoloDevice {
        var o: [String: Any] = ["id": id, "name": id, "kind": kind, "online": true, "default_action": action,
                                "accepts": ["link", "text", "image", "video", "file"]]
        if let bearing { o["bearing"] = ["deg": bearing, "confidence": 0.9] }
        return HoloDevice(json: o)!
    }

    func testBubblesSitAtRealBearingsRelativeToHeading() {
        let size = CGSize(width: 300, height: 600)
        let p = HoloOrbitLayout.positions(devices: [device("mac", bearing: 90)], heading: 90, size: size)
        let center = CGPoint(x: 150, y: 288)
        XCTAssertEqual(p["mac"]!.x, center.x, accuracy: 0.5)       // facing it: straight up
        XCTAssertLessThan(p["mac"]!.y, center.y)
        let turned = HoloOrbitLayout.positions(devices: [device("mac", bearing: 90)], heading: 0, size: size)
        XCTAssertGreaterThan(turned["mac"]!.x, center.x + 50)     // it's to the right now
    }

    func testDevicesWithoutBearingShareTheRing() {
        let p = HoloOrbitLayout.positions(devices: [device("a"), device("b"), device("c")], heading: nil,
                                          size: CGSize(width: 300, height: 600))
        XCTAssertEqual(Set(p.keys), ["a", "b", "c"])
        XCTAssertEqual(Set(p.values.map { "\(Int($0.x)),\(Int($0.y))" }).count, 3)
    }

    func testFlingPicksTheBubbleItPointsAt() {
        let origin = CGPoint(x: 150, y: 300)
        let positions = ["up": CGPoint(x: 150, y: 100), "right": CGPoint(x: 350, y: 300)]
        XCTAssertEqual(HoloOrbitLayout.target(forVelocity: CGVector(dx: 0, dy: -900), from: origin, positions: positions), "up")
        XCTAssertEqual(HoloOrbitLayout.target(forVelocity: CGVector(dx: 900, dy: 40), from: origin, positions: positions), "right")
        XCTAssertNil(HoloOrbitLayout.target(forVelocity: CGVector(dx: -900, dy: 900), from: origin, positions: positions))
        XCTAssertNil(HoloOrbitLayout.target(forVelocity: CGVector(dx: 0, dy: -100), from: origin, positions: positions))
    }

    @MainActor
    func testActionDefaultsAndOverride() {
        let model = HoloOrbitModel(item: .text("hi"), client: HoloDropClient(baseURL: URL(string: "https://x")!, headers: [:]))
        let mac = device("mac", action: "open"), phone = device("phone", kind: "iphone", action: "save")
        XCTAssertEqual(model.action(for: mac), .open)
        XCTAssertEqual(model.action(for: phone), .save)
        model.override = .copy
        XCTAssertEqual(model.action(for: mac), .copy)
    }

    func testAimCombinesTiltAndClamps() {
        let spot = HoloScreenMapView.combined(HoloPosition(x: 0.9, y: 0.1), tilt: CGSize(width: 0.3, height: -0.3))
        XCTAssertEqual(spot, HoloPosition(x: 1, y: 0))
    }

    func testDropMetaForEachKind() {
        let client = HoloDropClient(baseURL: URL(string: "https://x")!, headers: [:])
        let mac = device("mac")
        let link = client.meta(.link(URL(string: "https://a.b")!, title: "A"), device: mac, action: .open,
                               position: HoloPosition(x: 0.2, y: 0.3))
        XCTAssertEqual(link["kind"] as? String, "link")
        XCTAssertEqual((link["position"] as? [String: Double])?["x"], 0.2)
        let text = client.meta(.text("hi"), device: mac, action: .copy, position: nil)
        XCTAssertEqual(text["text"] as? String, "hi")
        XCTAssertEqual(text["action"] as? String, "copy")
    }

    func testDeviceDecodesBearingAndLan() {
        let d = HoloDevice(json: ["id": "m", "kind": "mac", "lan": ["url": "http://10.0.0.2:5000", "token": "t"],
                                  "bearing": ["deg": 45, "confidence": 0.7], "distance_m": 2.5])!
        XCTAssertEqual(d.lanURL?.absoluteString, "http://10.0.0.2:5000")
        XCTAssertEqual(d.bearingDeg, 45)
        XCTAssertEqual(d.distance, 2.5)
    }
}

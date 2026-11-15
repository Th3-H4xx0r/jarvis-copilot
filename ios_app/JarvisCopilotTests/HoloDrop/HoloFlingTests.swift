import CoreGraphics
import XCTest
@testable import JarvisCopilot

/// The physical fling: a throw with the phone sends the item toward a device.
private extension SIMD3 where Scalar == Double {
    var normalizedish: SIMD3<Double> { let m = (x * x + y * y + z * z).squareRoot(); return m > 0 ? self / m : self }
}

final class HoloFlingTests: XCTestCase {
    /// A throw: still, a push along `dir` (device frame, g), then the stop (opposite and harder).
    private func throwSamples(_ dir: SIMD3<Double>, start: Double = 2.0, peak: Double = 2.4) -> [HoloMotionSample] {
        var out: [HoloMotionSample] = []
        var t = start
        for _ in 0..<6 { out.append(.init(t: t, a: .zero)); t += 1 / 60 }
        for i in 0..<8 { out.append(.init(t: t, a: dir * (peak * Double(i + 1) / 8))); t += 1 / 60 }
        for i in 0..<6 { out.append(.init(t: t, a: dir * (-peak * 1.3 * Double(6 - i) / 6))); t += 1 / 60 }
        for _ in 0..<8 { out.append(.init(t: t, a: .zero)); t += 1 / 60 }
        return out
    }

    private func run(_ samples: [HoloMotionSample], armedAt: Double = 0) -> HoloFlick? {
        var d = HoloFlingDetector(armedAt: armedAt)
        var flick: HoloFlick?
        for s in samples { if let f = d.add(s) { flick = f } }
        return flick
    }

    func testAThrowToTheRightIsARightFlick() {
        let f = run(throwSamples(SIMD3(1, 0, 0)))
        XCTAssertNotNil(f)
        XCTAssertFalse(f!.forward)
        XCTAssertGreaterThan(f!.screen.dx, 0.8)
    }

    func testAThrowAwayFromHimIsForward() {
        // Holding the phone up facing him, throwing it forward moves it out of its back (−z).
        let f = run(throwSamples(SIMD3(0, 0, -1)))
        XCTAssertEqual(f?.forward, true)
    }

    func testAnUpwardFlickPointsUpTheScreen() {
        let f = run(throwSamples(SIMD3(0, 1, 0)))
        XCTAssertNotNil(f)
        XCTAssertLessThan(f!.screen.dy, -0.8)
    }

    func testGentleMovementAndTheOpeningLiftAreNotFlings() {
        XCTAssertNil(run(throwSamples(SIMD3(1, 0, 0), peak: 0.6)), "a gentle move")
        XCTAssertNil(run(throwSamples(SIMD3(1, 0, 0), start: 0.2), armedAt: 0), "lifting the phone as the popup opens")
    }

    func testOneThrowIsOneFlick() {
        var d = HoloFlingDetector(armedAt: 0)
        let n = (throwSamples(SIMD3(1, 0, 0)) + throwSamples(SIMD3(1, 0, 0), start: 2.6)).compactMap { d.add($0) }.count
        XCTAssertEqual(n, 1)
    }

    private func device(_ id: String, bearing: Double?) -> HoloDevice {
        var o: [String: Any] = ["id": id, "kind": "mac", "name": id, "online": true]
        if let bearing { o["bearing"] = ["deg": bearing, "confidence": 0.9] }
        return HoloDevice(json: o)!
    }

    func testForwardThrowGoesToTheDeviceThePhonePointsAt() {
        let devices = [device("mac", bearing: 80), device("ipad", bearing: 200)]
        let pos = HoloOrbitLayout.positions(devices: devices, heading: 75, size: CGSize(width: 300, height: 600))
        let flick = HoloFlick(screen: CGVector(dx: 0, dy: -1), forward: true, strength: 2)
        XCTAssertEqual(HoloFling.target(flick, heading: 75, devices: devices, positions: pos,
                                        center: CGPoint(x: 150, y: 288)), "mac")
        XCTAssertEqual(HoloFling.target(flick, heading: 195, devices: devices, positions: pos,
                                        center: CGPoint(x: 150, y: 288)), "ipad")
    }

    func testSidewaysFlickGoesToTheBubbleOnThatSide() {
        let devices = [device("a", bearing: nil), device("b", bearing: nil), device("c", bearing: nil), device("d", bearing: nil)]
        let size = CGSize(width: 300, height: 600)
        let pos = HoloOrbitLayout.positions(devices: devices, heading: nil, size: size)
        let center = CGPoint(x: 150, y: 288)
        let right = HoloFling.target(HoloFlick(screen: CGVector(dx: 1, dy: 0), forward: false, strength: 2),
                                     heading: nil, devices: devices, positions: pos, center: center)
        XCTAssertNotNil(right)
        XCTAssertGreaterThan(pos[right!]!.x, center.x)
    }

    // MARK: real-world throws (on-device: no fling at 1.5 g)

    func testACarefulThrowAtAboutOneGFires() {
        // Holding the phone you don't want to drop: ~1 g push, ~1.2 g stop.
        let f = run(throwSamples(SIMD3(0, 0.3, -1).normalizedish, peak: 1.0))
        XCTAssertNotNil(f, "a careful throw must count")
        XCTAssertEqual(f?.forward, true)
    }

    func testAWristFlickIsMostlyRotationAndFires() {
        // A flick of the wrist: little linear push, fast pitch (top tipping away = negative x rotation).
        var samples: [HoloMotionSample] = []
        var t = 2.0
        for _ in 0..<6 { samples.append(.init(t: t, a: .zero)); t += 1 / 60 }
        for i in 0..<8 { samples.append(.init(t: t, a: SIMD3(0, 0, -0.4), r: SIMD3(-7 * Double(i + 1) / 8, 0, 0))); t += 1 / 60 }
        for i in 0..<6 { samples.append(.init(t: t, a: SIMD3(0, 0, 0.5), r: SIMD3(3 * Double(6 - i) / 6, 0, 0))); t += 1 / 60 }
        for _ in 0..<8 { samples.append(.init(t: t, a: .zero)); t += 1 / 60 }
        let f = run(samples)
        XCTAssertNotNil(f, "a wrist flick must count")
        XCTAssertEqual(f?.forward, true)
    }

    func testJustHoldingAndTurningIsNotAFling() {
        // Turning around to face another device: slow rotation, tiny acceleration.
        var samples: [HoloMotionSample] = []
        var t = 2.0
        for _ in 0..<90 { samples.append(.init(t: t, a: SIMD3(0.05, 0, 0.05), r: SIMD3(0, 1.2, 0))); t += 1 / 60 }
        XCTAssertNil(run(samples))
    }

    // MARK: where a throw lands on the Mac (no aiming screen)

    func testPointingRightOfTheMacLandsOnItsRightSide() {
        let p = HoloAim.position(heading: 100, bearing: 90, roll: 0, pitch: 1, refRoll: 0, refPitch: 1)
        XCTAssertGreaterThan(p.x, 0.6)
        XCTAssertEqual(p.y, 0.5, accuracy: 0.01)
    }

    func testTiltingUpLandsHigherAndItStaysOnScreen() {
        XCTAssertLessThan(HoloAim.position(heading: nil, bearing: nil, roll: 0, pitch: 1.3, refRoll: 0, refPitch: 1).y, 0.4)
        let far = HoloAim.position(heading: 0, bearing: 180, roll: 3, pitch: -3, refRoll: 0, refPitch: 0)
        XCTAssertTrue((0.05...0.95).contains(far.x) && (0.05...0.95).contains(far.y))
    }

    // MARK: one tap in

    func testOneTapEntriesOpenHoloDrop() {
        XCTAssertEqual(AppDeepLink.parse(URL(string: "jarviscopilot://holo-drop/send")!), .holoDropSend)
        XCTAssertEqual(AppDeepLink.parse(URL(string: "jarviscopilot://holo-drop?drop=x")!), .holoDrop(drop: "x"))
        XCTAssertEqual(QuickAction.parse(type: QuickAction.holoDrop.rawValue)?.link, .holoDropSend)
    }

    func testTheGeneratedShortcutIsSigned() {
        let data = HoloShortcutFile.data
        XCTAssertGreaterThan(data.count, 1000)
        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "AEA1")   // signed container
    }
}

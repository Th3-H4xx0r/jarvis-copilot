import XCTest
@testable import JarvisCopilot

/// The 3D model's glow uses the same maths as the PC (golden.json, shared with the Python tests).
final class PcEffectsTests: XCTestCase {
    struct Case: Decodable { let effect: String; let color: String; let speed: Int; let seg_ord: Int; let i: Int; let n: Int; let t: Double; let rgb: [Int] }

    private func golden() throws -> [Case] {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = repo.appendingPathComponent("desktop_client/jc_client/pc_lighting/golden.json")
        return try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
    }

    func testGoldenCasesMatchThePCWithinOne() throws {
        let cases = try golden()
        XCTAssertGreaterThanOrEqual(cases.count, 40)
        for c in cases {
            let (r, g, b) = PcEffects.colour(effect: c.effect, color: c.color, speed: c.speed, segOrd: c.seg_ord,
                                             i: c.i, n: c.n, t: c.t)
            XCTAssertLessThanOrEqual(abs(Int(r) - c.rgb[0]), 1, "\(c)")
            XCTAssertLessThanOrEqual(abs(Int(g) - c.rgb[1]), 1, "\(c)")
            XCTAssertLessThanOrEqual(abs(Int(b) - c.rgb[2]), 1, "\(c)")
        }
    }

    private func state(_ effect: String = "static", on: Bool = true, brightness: Int = 100, frozen: Double? = nil) -> PcLightingState {
        PcLightingState(on: on, brightness: brightness, t0: 1000, frozenAt: frozen, stillInGames: false, rev: 1,
                        parts: Dictionary(uniqueKeysWithValues: PcPart.allCases.map {
                            ($0.rawValue, PcPartLight(effect: effect, color: "#ffffff", speed: 5)) }))
    }

    private let map = PcLedMap(version: 1, rev: 1, zones: [PcZone(controller: 0, zone: 0, leds: 16)],
                               segments: [PcSegment(part: "top", index: 0, controller: 0, zone: 0, start: 0, count: 16)])

    func testOffIsBlack() {
        let leds = PcEffects.ledColours(state: state(on: false), map: map, now: Date(timeIntervalSince1970: 1005))
        XCTAssertEqual(leds[0], Array(repeating: SIMD3<Float>(0, 0, 0), count: 16))
    }

    func testBrightnessScales() {
        let leds = PcEffects.ledColours(state: state(brightness: 50), map: map, now: Date(timeIntervalSince1970: 1005))
        XCTAssertEqual(leds[0][3].x, 0.5, accuracy: 0.01)
    }

    func testFrozenFrameDoesNotMove() {
        let s = state("rainbow", frozen: 1003.5)
        XCTAssertEqual(PcEffects.ledColours(state: s, map: map, now: Date(timeIntervalSince1970: 1010)),
                       PcEffects.ledColours(state: s, map: map, now: Date(timeIntervalSince1970: 1011)))
    }

    func testRainbowMovesWhenNotFrozen() {
        let s = state("rainbow")
        XCTAssertNotEqual(PcEffects.ledColours(state: s, map: map, now: Date(timeIntervalSince1970: 1010)),
                          PcEffects.ledColours(state: s, map: map, now: Date(timeIntervalSince1970: 1011)))
    }
}

import Metal
import SceneKit
import XCTest
@testable import JarvisCopilot

/// The PC model: every lit part exists with its LED sockets, the LED map lands on the right sockets,
/// and it renders. With JC_RENDER_DIR set the frames are written out to judge against his photos.
@MainActor
final class PcModelRenderTests: XCTestCase {
    private func state(_ effect: String, color: String = "#22d3ee") -> PcLightingState {
        PcLightingState(on: true, brightness: 100, t0: 0, frozenAt: 2.5, stillInGames: false, rev: 1,
                        parts: Dictionary(uniqueKeysWithValues: PcPart.allCases.map {
                            ($0.rawValue, PcPartLight(effect: effect, color: color, speed: 5)) }))
    }

    static let fullMap: PcLedMap = {
        var segs: [PcSegment] = []
        var start = 0
        for part in PcPart.allCases {
            for i in 0..<part.count {
                let n = part == .strip ? 40 : (part == .cooler ? 12 : 16)
                segs.append(PcSegment(part: part.rawValue, index: i, controller: 0, zone: 0, start: start, count: n,
                                      ringStartDeg: 90, clockwise: true, from: part == .strip ? "back" : nil, also: nil))
                start += n
            }
        }
        return PcLedMap(version: 1, rev: 1, zones: [PcZone(controller: 0, zone: 0, leds: start)], segments: segs)
    }()

    func testEveryLitPartHasItsSockets() {
        let live = PcModel.build()
        XCTAssertEqual(live.leds.keys.filter { $0.part == .top }.count, 2 * PcModel.ringSockets)
        XCTAssertEqual(live.leds.keys.filter { $0.part == .rear }.count, 2 * PcModel.ringSockets)
        XCTAssertEqual(live.leds.keys.filter { $0.part == .bottom }.count, 3 * PcModel.ringSockets)
        XCTAssertEqual(live.leds.keys.filter { $0.part == .cooler }.count, PcModel.logoSockets)
        XCTAssertEqual(live.leds.keys.filter { $0.part == .strip }.count, PcModel.stripSockets)
        for part in PcPart.allCases { XCTAssertNotNil(PcModel.partNode(part, in: live.scene), part.rawValue) }
    }

    func testMapColoursLandOnTheirSockets() {
        let live = PcModel.build()
        var s = state("static", color: "#ff0000")
        s.parts["strip"] = PcPartLight(effect: "static", color: "#0000ff", speed: 5)
        let colours = PcEffects.ledColours(state: s, map: Self.fullMap, now: Date())
        PcModel.apply(colours: colours, map: Self.fullMap, to: live)
        let top = live.leds[PcLedKey(part: .top, index: 1, led: 3)]!.emission.contents as! UIColor
        let strip = live.leds[PcLedKey(part: .strip, index: 0, led: 10)]!.emission.contents as! UIColor
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        top.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertGreaterThan(r, 0.9); XCTAssertLessThan(b, 0.1)
        strip.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertGreaterThan(b, 0.9); XCTAssertLessThan(r, 0.1)
    }

    func testAPartWithoutLEDsStaysDark() {
        let live = PcModel.build()
        let onlyTop = PcLedMap(version: 1, rev: 1, zones: [PcZone(controller: 0, zone: 0, leds: 16)],
                               segments: [PcSegment(part: "top", index: 0, controller: 0, zone: 0, start: 0, count: 16)])
        PcModel.apply(colours: PcEffects.ledColours(state: state("static", color: "#ffffff"), map: onlyTop, now: Date()),
                      map: onlyTop, to: live)
        let rear = live.leds[PcLedKey(part: .rear, index: 0, led: 0)]!.emission.contents as! UIColor
        var w: CGFloat = 0, a: CGFloat = 0
        rear.getWhite(&w, alpha: &a)
        XCTAssertLessThan(w, 0.05)
    }

    func testRingStartAndDirectionPickTheLED() {
        // 16 LEDs, LED 0 at 90°, clockwise: the socket at 90° shows LED 0 and the one at 67.5° LED 1.
        XCTAssertEqual(PcModel.ringLED(socket: 4, sockets: 16, leds: 16, startDeg: 90, clockwise: true), 0)
        XCTAssertEqual(PcModel.ringLED(socket: 3, sockets: 16, leds: 16, startDeg: 90, clockwise: true), 1)
        XCTAssertEqual(PcModel.ringLED(socket: 5, sockets: 16, leds: 16, startDeg: 90, clockwise: false), 1)
        XCTAssertEqual(PcModel.ringLED(socket: 0, sockets: 16, leds: 8, startDeg: 0, clockwise: false), 0)
    }

    /// A tap goes through the case's glass to the fan behind it and picks its nearest LED.
    func testTapThroughTheGlassFindsTheFanAndItsNearestLED() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let live = PcModel.build()
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = live.scene
        renderer.pointOfView = live.camera
        _ = renderer.snapshot(atTime: 0, with: CGSize(width: 900, height: 900), antialiasingMode: .none)
        for key in [PcLedKey(part: .bottom, index: 1, led: 4), PcLedKey(part: .rear, index: 0, led: 12),
                    PcLedKey(part: .cooler, index: 0, led: 3)] {
            let world = try XCTUnwrap(PcModel.socketPoint(key, in: live))
            let p = renderer.projectPoint(world)
            let hits = renderer.hitTest(CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)),
                                        options: [.searchMode: SCNHitTestSearchMode.all.rawValue])
            XCTAssertTrue(hits.contains { $0.node.name == "glass" } || key.part == .cooler, "the glass is in front")
            let tap = PcModel.resolve(hits, in: live)
            XCTAssertEqual(tap.key?.part, key.part, "\(key)")
            XCTAssertEqual(tap.key?.index, key.index, "\(key)")
            let sockets = key.part == .cooler ? PcModel.logoSockets : PcModel.ringSockets
            let off = abs((tap.key?.led ?? -99) - key.led)
            XCTAssertLessThanOrEqual(min(off, sockets - off), 1, "\(key) → \(String(describing: tap.key))")
        }
    }

    func testMakingTheViewDoesNotBuildTheScene() {
        let before = PcModel.buildCount
        _ = PcModelView(state: nil, map: nil)
        _ = PcModelView(state: nil, map: nil)
        XCTAssertEqual(PcModel.buildCount, before)      // built lazily, once, when it's drawn
    }

    func testTappingAFanFindsItsPart() {
        let live = PcModel.build()
        let fan = live.scene.rootNode.childNode(withName: "fan.bottom.1", recursively: true)
        XCTAssertNotNil(fan)
        XCTAssertEqual(PcModel.part(of: fan!.childNodes.first ?? fan!), .bottom)
    }

    private func render(_ live: PcModel.Live, size: CGFloat = 900) throws -> UIImage {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = live.scene
        renderer.pointOfView = live.camera
        renderer.scene?.background.contents = UIColor.black
        return renderer.snapshot(atTime: 0, with: CGSize(width: size, height: size), antialiasingMode: .multisampling4X)
    }

    private func write(_ image: UIImage, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["JC_RENDER_DIR"], let png = image.pngData() else { return }
        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
    }

    func testRendersLitAndUnlit() throws {
        for (name, effect, color) in [("pc-blue", "static", "#1e6bff"), ("pc-pink", "static", "#ff2bd6"),
                                      ("pc-rainbow", "rainbow", "#ffffff")] {
            let live = PcModel.build()
            PcModel.apply(colours: PcEffects.ledColours(state: state(effect, color: color), map: Self.fullMap, now: Date()),
                          map: Self.fullMap, to: live)
            let image = try render(live)
            XCTAssertEqual(image.size.width, 900)
            write(image, name + ".png")
        }
        var white = state("static", color: "#ffffff")
        white.brightness = 45
        let web = PcModel.build()
        PcModel.apply(colours: PcEffects.ledColours(state: white, map: Self.fullMap, now: Date()), map: Self.fullMap, to: web)
        write(try render(web, size: 1200), "pc-web.png")
        let dark = PcModel.build()
        write(try render(dark), "pc-unlit.png")
        let side = PcModel.build(view: .side)
        PcModel.apply(colours: PcEffects.ledColours(state: state("static", color: "#1e6bff"), map: Self.fullMap, now: Date()),
                      map: Self.fullMap, to: side)
        write(try render(side), "pc-side.png")
        let front = PcModel.build(view: .front)
        PcModel.apply(colours: PcEffects.ledColours(state: state("static", color: "#ff2bd6"), map: Self.fullMap, now: Date()),
                      map: Self.fullMap, to: front)
        write(try render(front), "pc-front.png")
    }
}
